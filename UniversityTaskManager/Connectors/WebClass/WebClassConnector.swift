import Foundation

/// 実際のHOPPII/WebClass通信フローを確認した後にのみ実装する。
struct WebClassConnector: TaskSourceConnector {
    let source: TaskSource = .webClass

    func fetchTasks() async throws -> [RemoteTask] {
        throw ConnectorError.notConfigured(source: source)
    }
}

