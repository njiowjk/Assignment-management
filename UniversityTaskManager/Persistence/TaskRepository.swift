import Foundation

@MainActor
protocol TaskRepository {
    func fetchTasks() throws -> [TaskItem]
    func lastSyncedAt(for source: TaskSource) throws -> Date?
    func merge(_ tasks: [RemoteTask], source: TaskSource, at date: Date) throws -> SyncSummary
}

struct SyncSummary: Equatable, Sendable {
    var inserted = 0
    var updated = 0
    var deadlineChanges = 0
    var missing = 0
}

