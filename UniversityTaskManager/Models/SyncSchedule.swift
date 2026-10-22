import Foundation

enum SyncTrigger: String, Codable, Sendable { case startup, timer, wake, network, manual }
enum SyncOutcome: String, Codable, Sendable { case success, transient, attention, cancelled }

struct SyncPolicyState: Codable, Equatable, Sendable {
    var source: TaskSource
    var lastAttemptAt: Date?
    var failureCount = 0
    var blocked = false
}

struct SyncPolicyEvent: Codable, Sendable {
    let source: TaskSource
    let outcome: SyncOutcome
}

struct SyncPolicyPlan: Codable, Sendable {
    let states: [SyncPolicyState]
    let due: [TaskSource]
    let nextRunAt: Date?
}
