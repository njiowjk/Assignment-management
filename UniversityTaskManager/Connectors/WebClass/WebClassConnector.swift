import Foundation

/// 調査済みの課題一覧読取APIをTypeScriptから呼ぶ薄いアダプター。
struct WebClassConnector: TaskSourceConnector {
    let source: TaskSource = .webClass
    var credentials: any CalendarCredentialStore = KeychainService()

    func fetchTasks() async throws -> [RemoteTask] {
        guard let session = try credentials.webClassSession() else { throw AppFailure.webClassLoginRequired }
        return try await BackendClient().fetchWebClass(session: session)
    }
}

