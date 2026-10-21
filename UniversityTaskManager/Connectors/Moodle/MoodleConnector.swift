import Foundation

struct MoodleConnector: TaskSourceConnector {
    let source: TaskSource = .moodle
    private let credentials: any CalendarCredentialStore
    private let session: URLSession
    private let parser: ICSParser

    init(credentials: any CalendarCredentialStore = KeychainService(),
         session: URLSession? = nil, parser: ICSParser = ICSParser()) {
        self.credentials = credentials
        self.parser = parser
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration, delegate: CalendarRedirectPolicy(),
                                      delegateQueue: nil)
        }
    }

    func fetchTasks() async throws -> [RemoteTask] {
        guard let url = try credentials.calendarURL() else { throw ConnectorError.notConfigured(source: source) }
        var request = URLRequest(url: url)
        request.setValue("text/calendar", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw AppFailure.server }
            if http.statusCode == 401 || http.statusCode == 403 || (300..<400).contains(http.statusCode) {
                throw AppFailure.authentication
            }
            guard (200..<300).contains(http.statusCode) else { throw AppFailure.server }
            guard http.mimeType?.lowercased() != "text/html" else { throw AppFailure.authentication }
            guard response.expectedContentLength <= 8 * 1_024 * 1_024 else { throw AppFailure.tooLarge }
            var data = Data()
            for try await byte in bytes {
                if data.count >= 8 * 1_024 * 1_024 { throw AppFailure.tooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return try parser.parse(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as AppFailure {
            throw failure
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AppFailure.network
        }
    }
}

/// トークン付きURLを別のオリジンやHTTPへ転送しない。
final class CalendarRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    static func allows(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target, target.scheme?.lowercased() == "https",
              original.host?.lowercased() == target.host?.lowercased(),
              (original.port ?? 443) == (target.port ?? 443),
              target.user == nil, target.password == nil else { return false }
        return true
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.allows(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }
}

