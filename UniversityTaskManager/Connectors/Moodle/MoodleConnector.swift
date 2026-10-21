import Foundation

/// Phase 2で、Keychain上のカレンダーURLとICS解析を実装する。
struct MoodleConnector: TaskSourceConnector {
    let source: TaskSource = .moodle

    func fetchTasks() async throws -> [RemoteTask] {
        throw ConnectorError.notConfigured(source: source)
    }
}

