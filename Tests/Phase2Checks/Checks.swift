import Foundation

/// 外部通信・実際のKeychain・ユーザーのDBに触れずに、実コードを検証する。
@main
@MainActor
struct Phase2Checks {
    static var count = 0
    static let now = iso("2026-10-21T12:00:00Z")

    static func main() async throws {
        try parserChecks()
        try credentialChecks()
        try classificationChecks()
        try await persistenceChecks()
        try await connectorChecks()
        print("PASS: \(count) checks (ICS / persistence / sync / HTTP / security)")
    }

    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw CheckFailure(label: label) }
        count += 1
    }

    static func rejects(_ expected: AppFailure, _ action: () throws -> Void) throws {
        do {
            try action()
        } catch let failure as AppFailure {
            try check(failure == expected, "expected safe error")
            return
        }
        throw CheckFailure(label: "expected rejection")
    }

    static func iso(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    static func calendar(_ event: String, zone: String = "") -> Data {
        Data("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n\(zone)BEGIN:VEVENT\r\n\(event)\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)
    }

    static func parserChecks() throws {
        let parser = ICSParser(defaultTimeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let data = calendar("UID:one\r\nSUMMARY:SQL\\, 演習\r\nCATEGORIES:データベース\\,基礎,大学\r\nDTSTART:20261021T140000Z\r\nDESCRIPTION:行1\\n行2\r\nURL:https://example.test/mod/assign/view.php?id=10")
        let tasks = try parser.parse(data)
        try check(tasks.count == 1 && tasks[0].externalID == "one", "ICS identity")
        try check(tasks[0].deadline == iso("2026-10-21T14:00:00Z"), "UTC deadline")
        try check(tasks[0].title == "SQL, 演習" && tasks[0].detail == "行1\n行2", "escaped text")
        try check(tasks[0].courseName == "データベース,基礎", "escaped categories")
        try check(tasks[0].isCompleted == nil && tasks[0].sourceURL != nil, "unknown submission and page link")

        let timed = try parser.parse(calendar("UID:two\r\nSUMMARY:時刻\r\nDTSTART;TZID=\"Asia/Tokyo\":20261022T100000\r\nDTEND;TZID=Asia/Tokyo:20261022T170000"))
        try check(timed[0].deadline == iso("2026-10-22T08:00:00Z"), "TZID and DTEND")
        let floating = try parser.parse(calendar("UID:float\r\nSUMMARY:時刻\r\nDTSTART:20261022T170000",
                                                 zone: "X-WR-TIMEZONE:Europe/London\r\n"))
        try check(floating[0].deadline == iso("2026-10-22T16:00:00Z"), "calendar floating timezone")
        let allDay = try parser.parse(calendar("UID:day\r\nSUMMARY:終日\r\nDTSTART;VALUE=DATE:20261022\r\nDTEND;VALUE=DATE:20261023"))
        try check(allDay[0].deadline == iso("2026-10-22T14:59:59Z"), "exclusive all-day end")
        let singleDay = try parser.parse(calendar("UID:day\r\nSUMMARY:終日\r\nDTSTART;VALUE=DATE:20261022"))
        try check(singleDay[0].deadline == allDay[0].deadline, "single all-day end")

        let folded = try parser.parse(calendar("UID:fold\r\nSUMMARY:課題の長い\r\n タイトル\r\nDTSTART:20261022T170000Z"))
        try check(folded[0].title == "課題の長いタイトル", "folded Japanese title")
        // UTF-8の一文字の途中で折り返された場合も、先にアンフォールドする。
        var brokenUTF8 = Array(calendar("UID:utf8\r\nSUMMARY:課題\r\nDTSTART:20261022T170000Z"))
        let position = brokenUTF8.firstIndex(of: 0xE8)!
        brokenUTF8.insert(contentsOf: [13, 10, 32], at: position + 1)
        try check(try parser.parse(Data(brokenUTF8))[0].title == "課題", "byte unfolding before UTF8 decode")

        try rejects(.invalidCalendar) { _ = try parser.parse(Data("<html>login</html>".utf8)) }
        try rejects(.invalidCalendar) { _ = try parser.parse(calendar("UID:bad\r\nSUMMARY:無効\r\nDTSTART:20260230T120000Z")) }
        try rejects(.invalidCalendar) { _ = try parser.parse(calendar("UID:bad\r\nSUMMARY:無効")) }
        try rejects(.invalidCalendar) { _ = try parser.parse(calendar("UID:bad\r\nUID:duplicate\r\nSUMMARY:無効\r\nDTSTART:20261022T170000Z")) }
        try rejects(.unsupportedCalendar) { _ = try parser.parse(calendar("UID:bad\r\nSUMMARY:繰返し\r\nDTSTART:20261022T170000Z\r\nRRULE:FREQ=WEEKLY")) }
        try rejects(.unsupportedCalendar) { _ = try parser.parse(calendar("UID:bad\r\nSUMMARY:時差\r\nDTSTART;TZID=Unknown/Zone:20261022T170000")) }
        try check(try parser.parse(calendar("UID:cancel\r\nSTATUS:CANCELLED")).isEmpty, "cancelled event skipped, not completed")
        let tokenLink = try parser.parse(calendar("UID:secret\r\nSUMMARY:課題\r\nDTSTART:20261022T170000Z\r\nURL:https://example.test/calendar?authtoken=synthetic"))
        try check(tokenLink[0].sourceURL == nil, "credential URL not persisted as page link")
    }

    static func credentialChecks() throws {
        _ = try KeychainService.validatedURL(" https://example.test/calendar?authtoken=synthetic \n")
        count += 1
        for url in ["http://example.test/", "https://user:password@example.test/", "not-a-url", "https://example.test/a b", "https:///", "file:///tmp/feed"] {
            try rejects(.invalidURL) { _ = try KeychainService.validatedURL(url) }
        }
        let original = URL(string: "https://example.test/calendar")!
        try check(CalendarRedirectPolicy.allows(from: original, to: URL(string: "https://example.test/new")), "same origin redirect")
        try check(!CalendarRedirectPolicy.allows(from: original, to: URL(string: "https://other.test/new")), "cross origin blocked")
        try check(!CalendarRedirectPolicy.allows(from: original, to: URL(string: "http://example.test/new")), "HTTPS downgrade blocked")
        try check(!CalendarRedirectPolicy.allows(from: original, to: URL(string: "https://example.test:8443/new")), "different port blocked")
        let sensitiveError = NSError(domain: "synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "authtoken=synthetic"])
        try check(!AppFailure.message(for: sensitiveError).contains("synthetic"), "raw errors redacted")
    }

    static func classificationChecks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let classifier = DeadlineClassifier(calendar: calendar)
        let cases: [(String, DeadlineBucket)] = [
            ("2026-10-21T11:00:00Z", .overdue), ("2026-10-21T18:00:00Z", .today),
            ("2026-10-22T09:00:00Z", .tomorrow), ("2026-10-25T23:00:00Z", .thisWeek),
            ("2026-10-26T09:00:00Z", .later)]
        for (date, bucket) in cases { try check(classifier.bucket(for: iso(date), relativeTo: now) == bucket, "deadline bucket") }
        let tasks = [local("late", at: "2026-10-21T18:00:00Z"), local("early", at: "2026-10-21T13:00:00Z"),
                     local("done", at: "2026-10-21T14:00:00Z", status: .completed)]
        let sections = TaskSectionBuilder(classifier: classifier).sections(from: tasks, now: now)
        try check(sections.count == 1 && sections[0].tasks.map(\.externalID) == ["early", "late"], "completed filter and sort")
    }

    static func local(_ id: String, at date: String, status: TaskStatus = .active) -> TaskItem {
        TaskItem(externalID: id, source: .moodle, courseName: "授業", title: id, deadline: iso(date), status: status)
    }

    static func remote(_ id: String = "one", title: String = "課題", due: Date = now,
                       source: TaskSource = .moodle, completed: Bool? = nil) -> RemoteTask {
        RemoteTask(externalID: id, source: source, courseName: "授業", title: title,
                   deadline: due, isCompleted: completed)
    }

    static func persistenceChecks() async throws {
        let repository = try CoreDataTaskRepository(inMemory: true)
        try check(try repository.fetchTasks().isEmpty, "empty database has no demo tasks")
        let inserted = try repository.merge([remote()], source: .moodle, at: now)
        let first = try repository.fetchTasks()[0]
        try check(inserted.inserted == 1 && !first.completionIsKnown, "insert and unknown submission")
        _ = try repository.merge([remote()], source: .moodle, at: now)
        try check(try repository.fetchTasks().count == 1, "idempotent merge")
        let changed = try repository.merge([remote(title: "変更課題", due: now.addingTimeInterval(100))], source: .moodle, at: now)
        let updated = try repository.fetchTasks()[0]
        try check(changed.updated == 1 && changed.deadlineChanges == 1 && updated.id == first.id &&
                  updated.firstDetectedAt == first.firstDetectedAt, "deadline and title update preserve identity")
        _ = try repository.merge([remote(source: .webClass)], source: .webClass, at: now)
        _ = try repository.merge([], source: .moodle, at: now)
        let missing = try repository.fetchTasks()
        try check(missing.count == 2 && missing.first(where: { $0.source == .moodle })!.isRemovedFromSource &&
                  !missing.first(where: { $0.source == .webClass })!.isRemovedFromSource, "missing retained and source isolated")
        _ = try repository.merge([remote(completed: true)], source: .moodle, at: now)
        _ = try repository.merge([remote()], source: .moodle, at: now)
        let completed = try repository.fetchTasks().first { $0.source == .moodle }!
        try check(completed.status == .completed && completed.completionIsKnown && !completed.isRemovedFromSource,
                  "unknown completion never reopens confirmed submission")
        try rejects(.invalidCalendar) { _ = try repository.merge([remote(), remote()], source: .moodle, at: now) }
        try rejects(.invalidCalendar) { _ = try repository.merge([remote(source: .webClass)], source: .moodle, at: now) }
        let before = try repository.fetchTasks()
        let previousSync = try repository.lastSyncedAt(for: .moodle)
        do { _ = try await SyncService(repository: repository).sync(FailingConnector()); throw CheckFailure(label: "failed connector") }
        catch let failure as AppFailure { try check(failure == .network, "failure surfaced safely") }
        try check(try repository.fetchTasks() == before && repository.lastSyncedAt(for: .moodle) == previousSync,
                  "failed sync leaves cache and last-success timestamp intact")
        let cancelled = Task {
            try await SyncService(repository: repository).sync(FixtureConnector())
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw CheckFailure(label: "cancelled sync") }
        catch is CancellationError { count += 1 }
        try check(try repository.fetchTasks() == before && repository.lastSyncedAt(for: .moodle) == previousSync,
                  "cancelled sync does not save")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("assignment-check-" + UUID().uuidString)
        let url = directory.appendingPathComponent("tasks.sqlite")
        do {
            let disk = try CoreDataTaskRepository(storeURL: url)
            _ = try disk.merge([remote(due: now.addingTimeInterval(-100))], source: .moodle, at: now)
        }
        let reopened = try CoreDataTaskRepository(storeURL: url)
        let cached = try reopened.fetchTasks()
        try check(cached.count == 1 && cached[0].status == .overdue, "disk reopen retains overdue task")
        try check(try reopened.lastSyncedAt(for: .moodle) == now, "last sync survives restart")
    }

    static func connectorChecks() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for (path, expected) in [("auth", AppFailure.authentication), ("html", .authentication),
                                 ("server", .server), ("invalid", .invalidCalendar), ("large", .tooLarge), ("offline", .network)] {
            let connector = MoodleConnector(credentials: FixtureCredentials(path: path), session: session)
            do { _ = try await connector.fetchTasks(); throw CheckFailure(label: "HTTP rejection") }
            catch let failure as AppFailure { try check(failure == expected, "HTTP error mapped") }
        }
        let fetched = try await MoodleConnector(credentials: FixtureCredentials(path: "valid"), session: session).fetchTasks()
        try check(fetched.count == 1 && fetched[0].externalID == "network", "HTTP calendar parsed")
        let repository = try CoreDataTaskRepository(inMemory: true)
        let result = try await SyncService(repository: repository).sync(
            MoodleConnector(credentials: FixtureCredentials(path: "valid"), session: session))
        try check(result.inserted == 1 && (try repository.lastSyncedAt(for: .moodle)) != nil, "end-to-end mock sync saved")
        let before = try repository.fetchTasks()
        let lastSync = try repository.lastSyncedAt(for: .moodle)
        do {
            _ = try await SyncService(repository: repository).sync(
                MoodleConnector(credentials: FixtureCredentials(path: "invalid"), session: session))
            throw CheckFailure(label: "invalid sync must fail")
        } catch let failure as AppFailure {
            try check(failure == .invalidCalendar, "invalid response fails whole sync")
        }
        try check(try repository.fetchTasks() == before && repository.lastSyncedAt(for: .moodle) == lastSync,
                  "parse failure preserves saved data and timestamp")
    }
}

struct CheckFailure: Error { let label: String }

struct FixtureCredentials: CalendarCredentialStore {
    let path: String
    func calendarURL() -> URL? { URL(string: "https://example.test/" + path) }
    func saveCalendarURL(_ text: String) throws { throw AppFailure.keychain }
}

struct FailingConnector: TaskSourceConnector {
    let source: TaskSource = .moodle
    func fetchTasks() async throws -> [RemoteTask] { throw AppFailure.network }
}

struct FixtureConnector: TaskSourceConnector {
    let source: TaskSource = .moodle
    func fetchTasks() async throws -> [RemoteTask] { [] }
}

final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        if path == "offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let status = path == "auth" ? 403 : (path == "server" ? 503 : 200)
        var headers = ["Content-Type": path == "html" ? "text/html" : "text/calendar"]
        if path == "large" { headers["Content-Length"] = "9000000" }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = path == "invalid" ? Data("not a calendar".utf8) :
            Data("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:network\r\nSUMMARY:Fixture\r\nDTSTART:20261022T120000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
