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
        try await webClassChecks()
        try await startupChecks()
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

    static func webClassChecks() async throws {
        let base = WebClassSession.baseURL
        for host in ["hoppii2025.hosei.ac.jp", "idp.hosei.ac.jp", "lms2025.hosei.ac.jp"] {
            try check(WebClassSession.allowsNavigation(URL(string: "https://\(host)/")!), "official SSO host accepted")
        }
        for url in ["http://lms2025.hosei.ac.jp/", "https://evil.test/", "https://idp.hosei.ac.jp.evil.test/",
                    "https://lms2025.hosei.ac.jp:8443/", "https://user:password@idp.hosei.ac.jp/"] {
            try check(!WebClassSession.allowsNavigation(URL(string: url)!), "nonofficial navigation rejected")
        }
        let cookie = HTTPCookie(properties: [.name: "WCSynthetic", .value: "synthetic", .domain: base.host!,
            .path: "/webclass/", .secure: "TRUE"])!
        let session = WebClassSession(baseURL: base, cookies: [MoodleSession.Cookie(cookie)])
        try check(session.isValid, "LMS-only session accepted")
        for domain in ["hosei.ac.jp", ".hosei.ac.jp", "idp.hosei.ac.jp", "hoppii2025.hosei.ac.jp"] {
            let other = HTTPCookie(properties: [.name: "SSO", .value: "synthetic", .domain: domain, .path: "/"])!
            try check(!WebClassSession.accepts(MoodleSession.Cookie(other)), "university-wide and IdP cookies never persisted")
        }
        try check(!WebClassSession(baseURL: base, cookies: []).isValid, "empty session rejected")
        let restored = try JSONDecoder().decode(WebClassSession.self, from: JSONEncoder().encode(session))
        try check(restored.isValid && restored.cookies[0].nativeCookie?.value == "synthetic", "WebClass session JSON roundtrip")
        do {
            _ = try await BackendClient().fetchWebClass()
            throw CheckFailure(label: "anonymous WebClass fetch succeeded")
        } catch let error as AppFailure {
            try check(error == .webClassLoginRequired, "TypeScript WebClass auth error crosses native bridge")
        }

        // Test both failure directions without any university network or real Keychain access.
        for failedSource: TaskSource in [.moodle, .webClass] {
            let repository = try CoreDataTaskRepository(inMemory: true)
            _ = try await repository.merge([remote(source: failedSource, completed: false)], source: failedSource, at: now)
            let old = try repository.fetchTasks().first!
            let credentials = SyntheticCredentials(webSession: session)
            let vm = HomeViewModel(repository: repository, credentials: credentials, connectorFactory: { source, _ in
                SyntheticConnector(source: source, shouldFail: source == failedSource)
            })
            await vm.loadCredentials()
            try check(vm.hasAnySource && vm.hasWebClassSession && vm.isConfigured, "independent source configuration loaded")
            await vm.syncAll()
            let healthySource: TaskSource = failedSource == .moodle ? .webClass : .moodle
            let tasks = try repository.fetchTasks()
            try check(tasks.first(where: { $0.source == failedSource }) == old, "failed source retains exact task cache")
            try check(try repository.lastSyncedAt(for: failedSource) == now, "failed source keeps last success timestamp")
            try check(tasks.contains(where: { $0.source == healthySource }), "other LMS sync succeeds despite source failure")
            try check(vm.statusText(for: failedSource).contains("通信できません"), "per-source failure remains visible")
            try check(vm.statusText(for: healthySource).contains("最終同期"), "healthy source has own success timestamp")
            try check(!vm.isSyncing, "sync state is cleared on mixed success")
        }
    }

    static func startupChecks() async throws {
        let repository = try CoreDataTaskRepository(inMemory: true)
        _ = try await repository.merge([remote(completed: false)], source: .moodle, at: now)
        let credentials = StartupCredentials()
        let vm = HomeViewModel(repository: repository, credentials: credentials)
        try check(credentials.readCount == 0, "constructing the app model never opens Keychain")
        try check(vm.visibleTaskCount == 1, "offline cache is visible before credential authentication")
        let first = Task { await vm.loadCredentials() }
        let second = Task { await vm.loadCredentials() }
        let limit = Date().addingTimeInterval(2)
        while !credentials.isWaiting && Date() < limit { try await Task.sleep(for: .milliseconds(2)) }
        try check(credentials.isWaiting, "credential loading started in background")
        try check(vm.isLoadingCredentials && !credentials.readOnMainThread, "Keychain authentication never blocks the main actor")
        vm.reload()
        try check(vm.visibleTaskCount == 1 && vm.statusText(for: .moodle).contains("確認中"), "UI stays usable while authentication waits")
        credentials.resume()
        await first.value
        await second.value
        try check(!vm.isLoadingCredentials && vm.isConfigured, "credentials become available after authentication")
        try check(credentials.readCount == 2, "concurrent window starts share one credential read")
        await vm.loadCredentials()
        try check(credentials.readCount == 2, "reopening a window does not trigger startup Keychain reads again")

        let denied = HomeViewModel(repository: repository, credentials: DeniedCredentials())
        await denied.loadCredentials()
        try check(!denied.isLoadingCredentials && denied.errorMessage != nil, "denied Keychain access becomes a visible error, not a stuck launch")
        try check(denied.visibleTaskCount == 1, "denied authentication preserves visible offline cache")
        try check(denied.statusText(for: .moodle).contains("Keychain") && denied.statusText(for: .webClass).contains("Keychain"),
                  "each source reports credential access failure")
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

struct SyntheticCredentials: CalendarCredentialStore {
    let webSession: WebClassSession
    func calendarURL() throws -> URL? { URL(string: "https://example.test/calendar/feed?authtoken=synthetic") }
    func saveCalendarURL(_ text: String) throws {}
    func webClassSession() throws -> WebClassSession? { webSession }
    func moodleSession(for calendarURL: URL) throws -> MoodleSession? {
        MoodleSession(baseURL: KeychainService.moodleRoot(for: calendarURL), cookies: [])
    }
}

struct SyntheticConnector: TaskSourceConnector {
    let source: TaskSource
    let shouldFail: Bool
    func fetchTasks() async throws -> [RemoteTask] {
        if shouldFail { throw AppFailure.network }
        return [RemoteTask(externalID: "synthetic", source: source, courseName: "授業", title: "課題", deadline: .now, isCompleted: false)]
    }
}

/// Simulates a system authentication prompt without touching the user's Keychain.
final class StartupCredentials: CalendarCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var reads = 0
    private var waiting = false
    private var mainThread = false
    var readCount: Int { lock.withLock { reads } }
    var isWaiting: Bool { lock.withLock { waiting } }
    var readOnMainThread: Bool { lock.withLock { mainThread } }
    func resume() { gate.signal() }
    func calendarURL() throws -> URL? {
        lock.withLock { reads += 1; waiting = true; mainThread = mainThread || Thread.isMainThread }
        guard gate.wait(timeout: .now() + 3) == .success else { throw AppFailure.keychain }
        return URL(string: "https://example.test/calendar/feed?authtoken=synthetic")
    }
    func webClassSession() throws -> WebClassSession? {
        lock.withLock { reads += 1; mainThread = mainThread || Thread.isMainThread }
        return nil
    }
    func saveCalendarURL(_ text: String) throws {}
}

struct DeniedCredentials: CalendarCredentialStore {
    func calendarURL() throws -> URL? { throw AppFailure.keychain }
    func webClassSession() throws -> WebClassSession? { throw AppFailure.keychain }
    func saveCalendarURL(_ text: String) throws { throw AppFailure.keychain }
}
