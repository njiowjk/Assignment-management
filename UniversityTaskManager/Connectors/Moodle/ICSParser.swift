import Foundation

/// Moodleの単発VEVENTを読み取る。未対応・破損したフィードは部分保存せず全体をエラーにする。
struct ICSParser: Sendable {
    var defaultTimeZone: TimeZone = .autoupdatingCurrent

    func parse(_ data: Data) throws -> [RemoteTask] {
        guard data.count <= 8 * 1_024 * 1_024 else { throw AppFailure.tooLarge }
        // RFC 5545の行折り返しをUTF-8デコードより前に解除する。
        let bytes = Array(data)
        var unfolded: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 13, index + 2 < bytes.count, bytes[index + 1] == 10,
               bytes[index + 2] == 32 || bytes[index + 2] == 9 {
                index += 3
            } else if bytes[index] == 10, index + 1 < bytes.count,
                      bytes[index + 1] == 32 || bytes[index + 1] == 9 {
                index += 2
            } else {
                unfolded.append(bytes[index])
                index += 1
            }
        }
        guard let text = String(bytes: unfolded, encoding: .utf8) else { throw AppFailure.invalidCalendar }
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.first == "BEGIN:VCALENDAR", lines.last == "END:VCALENDAR" else {
            throw AppFailure.invalidCalendar
        }

        var stack: [String] = []
        var fields: [String: [Property]] = [:]
        var events: [[String: [Property]]] = []
        var zone = defaultTimeZone
        for line in lines {
            let property = try Property(line)
            if property.name == "BEGIN" {
                if stack.isEmpty && property.value != "VCALENDAR" { throw AppFailure.invalidCalendar }
                if property.value == "VEVENT" {
                    guard stack == ["VCALENDAR"] else { throw AppFailure.invalidCalendar }
                    fields = [:]
                }
                stack.append(property.value)
            } else if property.name == "END" {
                guard stack.last == property.value else { throw AppFailure.invalidCalendar }
                if property.value == "VEVENT" { events.append(fields) }
                stack.removeLast()
            } else if stack == ["VCALENDAR", "VEVENT"] {
                fields[property.name, default: []].append(property)
            } else if stack == ["VCALENDAR"], property.name == "X-WR-TIMEZONE" {
                guard let foundZone = TimeZone(identifier: property.value) else { throw AppFailure.unsupportedCalendar }
                zone = foundZone
            }
        }
        guard stack.isEmpty else { throw AppFailure.invalidCalendar }
        var seen: Set<String> = []
        return try events.compactMap { fields in
            if try single("STATUS", in: fields)?.value.uppercased() == "CANCELLED" { return nil }
            guard fields["RRULE"] == nil, fields["RDATE"] == nil, fields["EXDATE"] == nil,
                  fields["RECURRENCE-ID"] == nil else { throw AppFailure.unsupportedCalendar }
            guard let uid = try single("UID", in: fields)?.value, !uid.isEmpty,
                  let title = try single("SUMMARY", in: fields)?.value, !title.isEmpty else {
                throw AppFailure.invalidCalendar
            }
            guard seen.insert(uid).inserted else { throw AppFailure.invalidCalendar }
            let start = try single("DTSTART", in: fields)
            let end = try single("DTEND", in: fields)
            guard let deadlineField = end ?? start else { throw AppFailure.invalidCalendar }
            if end == nil && fields["DURATION"] != nil { throw AppFailure.unsupportedCalendar }
            var deadline = try date(deadlineField, timeZone: zone)
            // 終日予定はDATEのDTENDが排他的。開始日だけなら当日末を期限として保持する。
            if deadlineField.isDateOnly {
                if end != nil {
                    deadline = deadline.addingTimeInterval(-1)
                } else {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = zone
                    guard let next = calendar.date(byAdding: .day, value: 1, to: deadline) else {
                        throw AppFailure.invalidCalendar
                    }
                    deadline = next.addingTimeInterval(-1)
                }
            }
            if let start, let end, try date(end, timeZone: zone) < date(start, timeZone: zone) {
                throw AppFailure.invalidCalendar
            }
            let courseField = try single("X-MOODLE-COURSE", in: fields)?.value
                ?? fields["CATEGORIES"]?.first?.value
            let course = courseField.map { unescape(split($0, separator: ",").first ?? $0) }
            let url = try single("URL", in: fields).flatMap { safePageURL($0.value) }
            return RemoteTask(externalID: uid, source: .moodle,
                              courseName: course?.isEmpty == false ? course! : "授業名未取得",
                              title: unescape(title),
                              detail: try single("DESCRIPTION", in: fields).map { unescape($0.value) },
                              deadline: deadline, sourceURL: url)
        }
    }

    private func single(_ name: String, in fields: [String: [Property]]) throws -> Property? {
        guard (fields[name]?.count ?? 0) <= 1 else { throw AppFailure.invalidCalendar }
        return fields[name]?.first
    }

    private func date(_ property: Property, timeZone: TimeZone) throws -> Date {
        let utc = property.value.hasSuffix("Z")
        let value = utc ? String(property.value.dropLast()) : property.value
        let format = property.isDateOnly ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
        guard value.count == (property.isDateOnly ? 8 : 15) else { throw AppFailure.unsupportedCalendar }
        var zone = utc ? TimeZone(secondsFromGMT: 0)! : timeZone
        if let identifier = property.parameters["TZID"] {
            guard !utc, let specified = TimeZone(identifier: identifier) else { throw AppFailure.unsupportedCalendar }
            zone = specified
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = format
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw AppFailure.invalidCalendar
        }
        return date
    }

    private func safePageURL(_ value: String) -> URL? {
        guard let url = try? KeychainService.validatedURL(value),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let secretNames = ["authtoken", "token", "password", "session", "sesskey", "key"]
        guard !(parts.queryItems ?? []).contains(where: { secretNames.contains($0.name.lowercased()) }) else {
            return nil
        }
        return url
    }

    private func unescape(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                result.append(character == "n" || character == "N" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    /// 引用符・エスケープ内の区切り文字は分割しない（TZIDやCATEGORIES等）。
    private func split(_ value: String, separator: Character) -> [String] {
        Self.split(value, separator: separator)
    }

    private static func split(_ value: String, separator: Character) -> [String] {
        var pieces = [""]
        var quoted = false
        var escaped = false
        for character in value {
            if character == separator && !quoted && !escaped {
                pieces.append("")
            } else {
                pieces[pieces.count - 1].append(character)
            }
            if character == "\"" && !escaped { quoted.toggle() }
            if character == "\\" && !escaped { escaped = true } else { escaped = false }
        }
        return pieces
    }

    private struct Property {
        let name: String
        let value: String
        var parameters: [String: String] = [:]
        var isDateOnly: Bool { parameters["VALUE"] == "DATE" || value.count == 8 }

        init(_ line: String) throws {
            let parts = ICSParser.split(line, separator: ":")
            guard parts.count >= 2 else { throw AppFailure.invalidCalendar }
            let header = ICSParser.split(parts[0], separator: ";")
            name = header[0].uppercased()
            value = parts.dropFirst().joined(separator: ":")
            for parameter in header.dropFirst() {
                let pair = parameter.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { throw AppFailure.invalidCalendar }
                parameters[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
    }
}
