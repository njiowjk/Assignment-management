import Foundation
import Security

protocol CalendarCredentialStore: Sendable {
    func calendarURL() throws -> URL?
    func saveCalendarURL(_ text: String) throws
    func moodleSession(for calendarURL: URL) throws -> MoodleSession?
    func saveMoodleSession(_ session: MoodleSession, for calendarURL: URL) throws
    func webClassSession() throws -> WebClassSession?
    func saveWebClassSession(_ session: WebClassSession) throws
}

extension CalendarCredentialStore {
    func moodleSession(for calendarURL: URL) throws -> MoodleSession? { nil }
    func saveMoodleSession(_ session: MoodleSession, for calendarURL: URL) throws { throw AppFailure.keychain }
    func webClassSession() throws -> WebClassSession? { nil }
    func saveWebClassSession(_ session: WebClassSession) throws { throw AppFailure.keychain }
}

struct WebClassSession: Codable, Sendable {
    static let baseURL = URL(string: "https://lms2025.hosei.ac.jp/webclass/")!
    static let portalURL = URL(string: "https://hoppii2025.hosei.ac.jp/portal/")!
    static let dashboardURL = baseURL.appendingPathComponent("ip_mods.php/plugin/score_summary_table/dashboard")
    let baseURL: URL
    let cookies: [MoodleSession.Cookie]

    static func allowsNavigation(_ url: URL) -> Bool {
        url.scheme == "https" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil &&
        ["hoppii2025.hosei.ac.jp", "idp.hosei.ac.jp", "lms2025.hosei.ac.jp"].contains(url.host?.lowercased() ?? "")
    }

    static func accepts(_ cookie: MoodleSession.Cookie) -> Bool {
        // Do not persist Hoppii/IdP or university-wide SSO cookies.
        let path = Self.dashboardURL.path
        let pathMatches = path == cookie.path || (path.hasPrefix(cookie.path) &&
            (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
        return cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == Self.baseURL.host &&
            cookie.matches(Self.dashboardURL) && cookie.path.hasPrefix("/") && pathMatches
    }

    var isValid: Bool { baseURL == Self.baseURL && !cookies.isEmpty && cookies.allSatisfy(Self.accepts) }
}

struct MoodleSession: Codable, Sendable {
    let baseURL: URL
    let cookies: [Cookie]

    struct Cookie: Codable, Sendable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let secure: Bool
        let httpOnly: Bool
        let expiresAt: Date?

        init(_ cookie: HTTPCookie) {
            name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
            secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly; expiresAt = cookie.expiresDate
        }

        func matches(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased(), expiresAt == nil || expiresAt! > .now else { return false }
            let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }

        var nativeCookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: path,
                .secure: secure ? "TRUE" : "FALSE"
            ]
            if httpOnly { properties[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE" }
            if let expiresAt { properties[.expires] = expiresAt }
            return HTTPCookie(properties: properties)
        }
    }
}

struct KeychainService: CalendarCredentialStore {
    private let service = "jp.universitytaskmanager.moodle"
    private let account = "calendar-feed-url"

    private var webClassQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "jp.universitytaskmanager.webclass",
         kSecAttrAccount as String: "webclass-session"]
    }

    func webClassSession() throws -> WebClassSession? {
        var query = webClassQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let session = try? JSONDecoder().decode(WebClassSession.self, from: data) else { throw AppFailure.keychain }
        return session.isValid ? session : nil
    }

    func saveWebClassSession(_ session: WebClassSession) throws {
        guard session.isValid else { throw AppFailure.webClassLoginRequired }
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(session),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(webClassQuery as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(webClassQuery.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw AppFailure.keychain }
        } else if status != errSecSuccess { throw AppFailure.keychain }
    }

    static func moodleRoot(for calendarURL: URL) -> URL {
        var parts = URLComponents(url: calendarURL, resolvingAgainstBaseURL: false)!
        let path = parts.path
        parts.query = nil; parts.fragment = nil
        if let range = path.range(of: "/calendar/") { parts.path = String(path[..<range.lowerBound]) + "/" }
        else { parts.path = "/" }
        return parts.url!
    }

    func moodleSession(for calendarURL: URL) throws -> MoodleSession? {
        var query = baseQuery
        query[kSecAttrAccount as String] = "moodle-session"
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let session = try? JSONDecoder().decode(MoodleSession.self, from: data) else { throw AppFailure.keychain }
        let base = Self.moodleRoot(for: calendarURL)
        guard session.baseURL == base, session.cookies.contains(where: { $0.matches(base) }) else { return nil }
        return session
    }

    func saveMoodleSession(_ session: MoodleSession, for calendarURL: URL) throws {
        let base = Self.moodleRoot(for: calendarURL)
        guard session.baseURL == base, !session.cookies.isEmpty,
              session.cookies.allSatisfy({ $0.matches(base) }) else { throw AppFailure.moodleLoginRequired }
        let data = try JSONEncoder().encode(session)
        var query = baseQuery
        query[kSecAttrAccount as String] = "moodle-session"
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw AppFailure.keychain }
        } else if status != errSecSuccess { throw AppFailure.keychain }
    }

    static func validatedURL(_ text: String) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.fragment == nil, let url = parts.url,
              !value.contains(where: { $0.isWhitespace }) else {
            throw AppFailure.invalidURL
        }
        return url
    }

    func calendarURL() throws -> URL? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { throw AppFailure.keychain }
        return try Self.validatedURL(text)
    }

    func saveCalendarURL(_ text: String) throws {
        let url = try Self.validatedURL(text)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(url.absoluteString.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let result = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            let newItem = baseQuery.merging(attributes) { _, new in new }
            guard SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess else { throw AppFailure.keychain }
        } else if result != errSecSuccess {
            throw AppFailure.keychain
        }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
