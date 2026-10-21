import Foundation

protocol TaskSourceConnector: Sendable {
    var source: TaskSource { get }

    func fetchTasks() async throws -> [RemoteTask]
}

enum ConnectorError: LocalizedError, Sendable {
    case notConfigured(source: TaskSource)
    case authenticationRequired(source: TaskSource)
    case invalidResponse(source: TaskSource)

    var errorDescription: String? {
        switch self {
        case let .notConfigured(source):
            "\(source.rawValue)連携はまだ設定されていません。"
        case let .authenticationRequired(source):
            "\(source.rawValue)へのログインが必要です。"
        case let .invalidResponse(source):
            "\(source.rawValue)から取得したデータを確認できませんでした。"
        }
    }
}

