import Foundation

struct NotificationPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var newTask = true
    var dayBefore = true
    var hoursBefore = true
    var deadlineChanged = true
    var overdue = true
    var sound = true
}

struct TaskNotification: Codable, Equatable, Sendable {
    let id: String
    let taskID: UUID
    let kind: String
    let fireAt: Date
    let deadline: Date
    let title: String
    let courseName: String
    let source: TaskSource

    var heading: String {
        switch kind {
        case "newTask": "新しい課題があります"
        case "dayBefore": "課題の締切まで24時間"
        case "hoursBefore": "課題の締切まで3時間"
        case "deadlineChanged": "課題の締切が変更されました"
        default: "課題が締切を迎えました"
        }
    }
    var body: String {
        let date = deadline.formatted(date: .abbreviated, time: .shortened)
        return "\(courseName.prefix(120))：\(title.prefix(160))\n締切 \(date)（\(source.rawValue)・最終同期時点の情報）"
    }
}

struct NotificationState: Codable, Sendable {
    struct Observation: Codable, Sendable { let taskID: String; let deadline: Date; let revision: Int }
    struct Receipt: Codable, Sendable { let id: String; let fireAt: Date }
    struct Event: Codable, Sendable { let id: String; let taskID: String; let kind: String; let fireAt: Date }
    var observations: [Observation] = []
    var sources: [TaskSource] = []
    var receipts: [Receipt] = []
    var events: [Event] = []
}

struct NotificationPlan: Codable, Sendable {
    let state: NotificationState
    let requests: [TaskNotification]
    let validIDs: [String]
}

enum NotificationAuthorization: Sendable { case notDetermined, denied, authorized }

struct PendingTaskNotification: Sendable {
    let id: String
    let title: String
    let body: String
    let fireAt: Date
    let sound: Bool
}
