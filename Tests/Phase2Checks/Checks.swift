import Foundation

/// Swift tests cover the native storage/Keychain boundary and real TypeScript IPC.
/// Parser, HTTP and domain rules are tested in backend/tests.
@main
@MainActor
struct Phase2Checks {
    static var count = 0
    static let now = iso("2026-10-21T12:00:00Z")

    static func main() async throws {
        try credentialChecks()
        try classificationChecks()
        try await bridgeChecks()
        try await persistenceChecks()
        print("PASS: \(count) native/TypeScript integration checks")
    }

    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw CheckFailure(label: label) }
        count += 1
    }

    static func iso(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    static func credentialChecks() throws {
        _ = try KeychainService.validatedURL(" https://example.test/?authtoken=synthetic \n")
        count += 1
        for url in ["http://example.test/", "https://user:password@example.test/", "not-a-url",
                    "https://example.test/a b", "https:///", "file:///tmp/feed"] {
            do { _ = try KeychainService.validatedURL(url); throw CheckFailure(label: "invalid URL accepted") }
            catch let failure as AppFailure { try check(failure == .invalidURL, "invalid URL rejected") }
        }
        let error = NSError(domain: "synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "authtoken=synthetic"])
        try check(!AppFailure.message(for: error).contains("synthetic"), "raw errors redacted")
        let calendar = URL(string: "https://example.test/moodle/calendar/export_execute.php?authtoken=synthetic")!
        try check(KeychainService.moodleRoot(for: calendar).absoluteString == "https://example.test/moodle/",
                  "official login URL omits feed token and preserves site path")
        let cookie = HTTPCookie(properties: [.name: "MoodleSession", .value: "synthetic", .domain: "example.test",
            .path: "/moodle/", .secure: "TRUE", HTTPCookiePropertyKey(rawValue: "HttpOnly"): "TRUE"])!
        let saved = MoodleSession.Cookie(cookie)
        try check(saved.matches(calendar) && !saved.matches(URL(string: "https://other.test/")!), "session cookies scoped to Moodle host")
        try check(saved.nativeCookie?.value == cookie.value && saved.nativeCookie?.isSecure == true,
                  "cookie roundtrip restores secure native session")
    }

    static func classificationChecks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let classifier = DeadlineClassifier(calendar: calendar)
        let cases: [(String, DeadlineBucket)] = [
            ("2026-10-21T11:00:00Z", .overdue), ("2026-10-21T18:00:00Z", .today),
            ("2026-10-22T09:00:00Z", .tomorrow), ("2026-10-25T23:00:00Z", .thisWeek),
            ("2026-10-26T09:00:00Z", .later)]
        for (date, bucket) in cases { try check(classifier.bucket(for: iso(date), relativeTo: now) == bucket, "deadline bucket") }
        let pending = TaskItem(externalID: "pending", source: .moodle, courseName: "授業", title: "未提出", deadline: now,
                               completionIsKnown: true)
        let done = TaskItem(externalID: "done", source: .moodle, courseName: "授業", title: "提出済み", deadline: now,
                            status: .completed, completionIsKnown: true)
        let unknown = TaskItem(externalID: "unknown", source: .moodle, courseName: "授業", title: "不明", deadline: now)
        let sections = TaskSectionBuilder(classifier: classifier).sections(from: [pending, done, unknown], now: now)
        try check(sections.flatMap(\.tasks).map(\.externalID) == ["pending"], "home displays confirmed incomplete only")
        try check(!done.isVisibleOnHome && !unknown.isVisibleOnHome, "completed and unknown excluded from main task groups")
    }

    static func bridgeChecks() async throws {
        let backend = BackendClient()
        let feed = Data("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:bridge\r\nSUMMARY:課題\r\nDTSTART;TZID=Asia/Tokyo:20261022T170000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)
        let tasks = try await backend.parseICS(feed, timeZone: "Asia/Tokyo")
        try check(tasks.count == 1 && tasks[0].externalID == "bridge", "Swift calls TypeScript parser")
        try check(tasks[0].deadline == iso("2026-10-22T08:00:00Z") && tasks[0].isCompleted == nil,
                  "date and unknown submission survive JSON transfer")
        do { _ = try await backend.parseICS(Data("<html>synthetic</html>".utf8), timeZone: "Asia/Tokyo")
            throw CheckFailure(label: "invalid feed accepted")
        } catch let error as AppFailure {
            try check(error == .invalidCalendar, "TypeScript errors mapped to native messages")
        }
        let cancelled = Task { try await backend.parseICS(feed, timeZone: "Asia/Tokyo") }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw CheckFailure(label: "cancelled request succeeded") }
        catch is CancellationError { count += 1 }

        // Exercise the app-resource/runtime.json path, without process environment overrides.
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("backend-resources-" + UUID().uuidString)
        let directory = resources.appendingPathComponent("Backend")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = ProcessInfo.processInfo.environment
        let worker = URL(fileURLWithPath: environment["ASSIGNMENT_BACKEND_DIR"]!).appendingPathComponent("worker.mjs")
        try FileManager.default.copyItem(at: worker, to: directory.appendingPathComponent("worker.mjs"))
        let config = try JSONSerialization.data(withJSONObject: ["nodeExecutable": environment["ASSIGNMENT_NODE_EXECUTABLE"]!])
        try config.write(to: directory.appendingPathComponent("runtime.json"))
        let packaged = try await BackendClient(resourceDirectory: resources).parseICS(feed, timeZone: "Asia/Tokyo")
        try check(packaged == tasks, "app resource layout resolves and executes bundled worker")
    }

    static func remote(title: String = "課題", due: Date = now, source: TaskSource = .moodle,
                       completed: Bool? = nil) -> RemoteTask {
        RemoteTask(externalID: "one", source: source, courseName: "授業", title: title,
                   deadline: due, isCompleted: completed)
    }

    static func persistenceChecks() async throws {
        let repository = try CoreDataTaskRepository(inMemory: true)
        try check(try repository.fetchTasks().isEmpty, "empty database")
        let inserted = try await repository.merge([remote()], source: .moodle, at: now)
        let original = try repository.fetchTasks()[0]
        try check(inserted.inserted == 1 && !original.completionIsKnown, "insert via TypeScript")
        _ = try await repository.merge([remote()], source: .moodle, at: now)
        try check(try repository.fetchTasks().count == 1, "idempotent native save")
        let change = try await repository.merge([remote(title: "変更", due: now.addingTimeInterval(100))], source: .moodle, at: now)
        let updated = try repository.fetchTasks()[0]
        try check(change.updated == 1 && change.deadlineChanges == 1 && updated.id == original.id &&
                  updated.firstDetectedAt == original.firstDetectedAt, "identity and deadline changes survive IPC")
        _ = try await repository.merge([remote(source: .webClass)], source: .webClass, at: now)
        _ = try await repository.merge([], source: .moodle, at: now)
        let missing = try repository.fetchTasks()
        try check(missing.count == 2 && missing.first(where: { $0.source == .moodle })!.isRemovedFromSource &&
                  !missing.first(where: { $0.source == .webClass })!.isRemovedFromSource, "source isolation and retention")
        _ = try await repository.merge([remote(completed: true)], source: .moodle, at: now)
        _ = try await repository.merge([remote()], source: .moodle, at: now)
        let completed = try repository.fetchTasks().first { $0.source == .moodle }!
        try check(completed.status == .completed && completed.completionIsKnown, "unknown never reopens completion")
        let before = try repository.fetchTasks()
        let lastSync = try repository.lastSyncedAt(for: .moodle)
        do { _ = try await repository.merge([remote(), remote()], source: .moodle, at: now)
            throw CheckFailure(label: "duplicate accepted")
        } catch let error as AppFailure { try check(error == .invalidCalendar, "duplicate rejected before saving") }
        do { _ = try await SyncService(repository: repository).sync(FailingConnector())
            throw CheckFailure(label: "failed sync succeeded")
        } catch let error as AppFailure { try check(error == .network, "failed sync surfaced") }
        try check(try repository.fetchTasks() == before && repository.lastSyncedAt(for: .moodle) == lastSync,
                  "failed fetch and failed merge preserve cache and last-success timestamp")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("assignment-check-" + UUID().uuidString)
        let url = directory.appendingPathComponent("tasks.sqlite")
        do {
            let disk = try CoreDataTaskRepository(storeURL: url)
            _ = try await disk.merge([remote(due: now.addingTimeInterval(-100))], source: .moodle, at: now)
        }
        let reopened = try CoreDataTaskRepository(storeURL: url)
        let cached = try reopened.fetchTasks()
        try check(cached.count == 1 && cached[0].status == .overdue, "SQLite survives restart")
        try check(try reopened.lastSyncedAt(for: .moodle) == now, "last success survives restart")
        let result = try await reopened.merge([remote(title: "再読込後の更新")], source: .moodle, at: now)
        try check(result.updated == 1 && (try reopened.fetchTasks()[0].id) == cached[0].id,
                  "existing native DB updates through TypeScript without new IDs")
        let beforeFailure = try reopened.fetchTasks()
        let beforeFailureDate = try reopened.lastSyncedAt(for: .moodle)
        let unavailable = BackendClient(resourceDirectory: directory.appendingPathComponent("missing-resources"))
        let noBackend = try CoreDataTaskRepository(storeURL: url, backend: unavailable)
        do {
            _ = try await noBackend.merge([], source: .moodle, at: now.addingTimeInterval(500))
            throw CheckFailure(label: "missing backend succeeded")
        } catch let failure as AppFailure { try check(failure == .backend, "missing backend fails safely") }
        try check(try noBackend.fetchTasks() == beforeFailure && noBackend.lastSyncedAt(for: .moodle) == beforeFailureDate,
                  "backend unavailable preserves offline cache and last-success timestamp")
    }
}

struct CheckFailure: Error { let label: String }

struct FailingConnector: TaskSourceConnector {
    let source: TaskSource = .moodle
    func fetchTasks() async throws -> [RemoteTask] { throw AppFailure.network }
}
