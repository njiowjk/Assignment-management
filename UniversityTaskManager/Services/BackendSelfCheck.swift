import Foundation

/// Safe distribution diagnostic: synthetic data only; no database, Keychain, OS permission, or network.
struct BackendSelfCheck {
    struct Result: Encodable, Sendable { let version = 1; let ok: Bool; let checks: [String] }

    static func run(backend: BackendClient = BackendClient()) async throws -> Result {
        guard try await backend.health().protocolVersion == 1 else { throw AppFailure.backend }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let feed = Data("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:distribution-self-check\r\nSUMMARY:Self check\r\nDTSTART;TZID=Asia/Tokyo:20270115T170000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)
        let parsed = try await backend.parseICS(feed, timeZone: "Asia/Tokyo")
        guard parsed.count == 1, parsed[0].externalID == "distribution-self-check",
              parsed[0].deadline == ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z") else { throw AppFailure.backend }
        let remote = RemoteTask(externalID: "self-check", source: .moodle, courseName: "Self check", title: "Self check",
            deadline: date.addingTimeInterval(172800), isCompleted: false)
        let merged = try await backend.merge(existing: [], tasks: [remote], source: .moodle, at: date)
        guard merged.tasks.count == 1, merged.summary.inserted == 1 else { throw AppFailure.backend }
        let schedule = try await backend.syncPolicy(states: [], enabled: [.moodle], intervalSeconds: 1800, trigger: .startup, now: date)
        guard schedule.due == [.moodle] else { throw AppFailure.backend }
        var settings = NotificationPreferences(); settings.enabled = true
        let plan = try await backend.notificationPlan(tasks: merged.tasks, syncedSources: [.moodle], preferences: settings,
            state: NotificationState(), now: date)
        guard plan.requests.count == 3 else { throw AppFailure.backend }
        return Result(ok: true, checks: ["health", "ics-timezone", "merge", "sync-policy", "notifications"])
    }
}
