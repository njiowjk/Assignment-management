import Foundation
import UserNotifications

@MainActor
protocol TaskNotificationCenter {
    func authorization() async -> NotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func pending() async -> [PendingTaskNotification]
    func deliveredIDs() async -> [String]
    func add(_ request: PendingTaskNotification, taskID: UUID?) async throws
    func removePending(_ ids: [String])
    func removeDelivered(_ ids: [String])
}

/// Only the platform adapter knows UserNotifications. Construction never prompts.
@MainActor
struct MacTaskNotificationCenter: TaskNotificationCenter {
    private var center: UNUserNotificationCenter { .current() }
    func authorization() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        default: .notDetermined
        }
    }
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }
    func pending() async -> [PendingTaskNotification] {
        await center.pendingNotificationRequests().compactMap { request in
            guard let seconds = request.content.userInfo["fireAt"] as? Double else { return nil }
            return PendingTaskNotification(id: request.identifier, title: request.content.title, body: request.content.body,
                fireAt: Date(timeIntervalSince1970: seconds), sound: request.content.sound != nil)
        }
    }
    func deliveredIDs() async -> [String] { await center.deliveredNotifications().map(\.request.identifier) }
    func add(_ request: PendingTaskNotification, taskID: UUID?) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title; content.body = request.body
        if request.sound { content.sound = .default }
        content.userInfo = ["fireAt": request.fireAt.timeIntervalSince1970]
        if let taskID { content.userInfo["taskID"] = taskID.uuidString }
        let delay = request.fireAt.timeIntervalSinceNow
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: request.fireAt)
        components.calendar = calendar; components.timeZone = calendar.timeZone
        let trigger = delay > 1 ? UNCalendarNotificationTrigger(dateMatching: components, repeats: false) : nil
        try await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: trigger))
    }
    func removePending(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func removeDelivered(_ ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }
}

/// Tests/demo never read OS notification permissions or post real notifications.
@MainActor
struct DisabledTaskNotificationCenter: TaskNotificationCenter {
    func authorization() async -> NotificationAuthorization { .notDetermined }
    func requestAuthorization() async throws -> Bool { false }
    func pending() async -> [PendingTaskNotification] { [] }
    func deliveredIDs() async -> [String] { [] }
    func add(_ request: PendingTaskNotification, taskID: UUID?) async throws {}
    func removePending(_ ids: [String]) {}
    func removeDelivered(_ ids: [String]) {}
}
