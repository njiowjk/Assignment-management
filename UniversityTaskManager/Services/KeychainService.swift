import Foundation
import Security

protocol CalendarCredentialStore: Sendable {
    func calendarURL() throws -> URL?
    func saveCalendarURL(_ text: String) throws
}

struct KeychainService: CalendarCredentialStore {
    private let service = "jp.universitytaskmanager.moodle"
    private let account = "calendar-feed-url"

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
