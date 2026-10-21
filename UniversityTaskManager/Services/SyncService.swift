import Foundation

@MainActor
final class SyncService {
    private let repository: any TaskRepository

    init(repository: any TaskRepository) { self.repository = repository }

    func sync(_ connector: any TaskSourceConnector) async throws -> SyncSummary {
        let tasks = try await connector.fetchTasks()
        try Task.checkCancellation()
        // 取得・解析が全て成功した時だけ、対象Sourceのデータと同期時刻を同時保存する。
        return try repository.merge(tasks, source: connector.source, at: .now)
    }
}
