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
        try await schedulingChecks()
        try await notificationChecks()
        print("PASS: \(count) native/TypeScript integration checks")
    }

    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw CheckFailure(label: label) }
        count += 1
    }

    static func notificationChecks() async throws {
        var clock = now
        var tasks = [TaskItem(externalID: "notification-synthetic", source: .moodle, courseName: "授業", title: "課題",
            deadline: now.addingTimeInterval(172800), completionIsKnown: true)]
        let center = SyntheticNotificationCenter(now: { clock })
        let controller = NotificationController(defaults: nil, center: center, snapshot: { (tasks, [.moodle]) }, now: { clock })
        await controller.refresh()
        try check(!controller.preferences.enabled && center.requests.isEmpty && center.permissionRequests == 0,
                  "notifications default OFF; startup never requests notification permission")
        await controller.setEnabled(true)
        try check(center.permissionRequests == 1 && controller.authorization == .authorized, "explicit ON requests OS permission once")
        try check(center.requests.count == 3 && controller.scheduledCount == 3, "initial cache reserves only three future reminders")
        let initialIDs = Set(center.requests.keys), initialAdds = center.adds.count
        await controller.refresh()
        try check(center.adds.count == initialAdds, "identical reconciliation never replaces existing OS requests")
        let newTask = TaskItem(externalID: "notification-new", source: .moodle, courseName: "授業", title: "新規",
            deadline: now.addingTimeInterval(259200), completionIsKnown: true)
        tasks.append(newTask)
        await controller.refresh()
        try check(center.delivered.contains(where: { $0.hasSuffix(".newTask") }), "new task generates immediate alert after baseline")
        let alertCount = center.adds.filter { $0.hasSuffix(".newTask") }.count
        await controller.refresh()
        try check(center.adds.filter { $0.hasSuffix(".newTask") }.count == alertCount, "repeated sync never replays immediate alert")
        let persisted = try JSONDecoder().decode(NotificationState.self, from: JSONEncoder().encode(controller.state))
        let restored = NotificationController(defaults: nil, center: center, snapshot: { (tasks, [.moodle]) },
            restoredPreferences: controller.preferences, restoredState: persisted, now: { clock })
        await restored.refresh()
        try check(center.adds.filter { $0.hasSuffix(".newTask") }.count == alertCount, "receipt journal roundtrips across controller restart")
        tasks[0].deadline = now.addingTimeInterval(345600)
        await restored.refresh()
        try check(initialIDs.isDisjoint(with: Set(center.requests.keys)), "deadline change removes old OS reservations")
        try check(center.delivered.contains(where: { $0.hasSuffix(".deadlineChanged") }), "deadline change posts one immediate alert")
        tasks[0].status = .completed
        tasks[1].completionIsKnown = false
        await restored.refresh()
        try check(center.requests.isEmpty && center.delivered.isEmpty, "completed and unknown cancel both pending and delivered notifications")
        tasks[0].status = .active
        tasks[1].completionIsKnown = true
        await restored.refresh()
        await restored.setOption(\.dayBefore, false)
        try check(center.requests.keys.allSatisfy { !$0.hasSuffix(".dayBefore") }, "per-type OFF cancels only that type")
        await restored.sendTest()
        try check(center.requests["assignment.test"] != nil && restored.testMessage?.contains("3秒") == true, "test notification is user-triggered and uses no private task data")
        center.requests["unrelated"] = PendingTaskNotification(id: "unrelated", title: "other", body: "other", fireAt: clock.addingTimeInterval(10), sound: false)
        await restored.setEnabled(false)
        try check(Set(center.requests.keys) == ["unrelated"] && center.delivered.isEmpty, "master OFF cancels task/test requests but preserves unrelated notifications")

        let failedCenter = SyntheticNotificationCenter(now: { clock })
        failedCenter.status = .authorized
        var enabled = NotificationPreferences(); enabled.enabled = true
        let failure = NotificationController(defaults: nil, center: failedCenter, snapshot: { (tasks, [.moodle]) }, restoredPreferences: enabled, now: { clock })
        await failure.refresh()
        tasks.append(TaskItem(externalID: "retry", source: .moodle, courseName: "授業", title: "再試行",
            deadline: clock.addingTimeInterval(180000), completionIsKnown: true))
        failedCenter.failAdds = true
        await failure.refresh()
        try check(failure.errorMessage != nil && failure.state.events.count == 1, "failed OS add retains immediate outbox with visible error")
        failedCenter.failAdds = false
        await failure.refresh()
        try check(failure.errorMessage == nil && failure.state.events.isEmpty, "successful retry drains outbox without losing the event")
        let accepted = failedCenter.adds.count
        clock = clock.addingTimeInterval(400000)
        failedCenter.requests = [:]; failedCenter.delivered = []
        await failure.refresh()
        try check(failedCenter.adds.count == accepted, "restart after deadlines never replays already accepted reminders")

        let deniedCenter = SyntheticNotificationCenter(now: { clock }); deniedCenter.status = .denied
        let denied = NotificationController(defaults: nil, center: deniedCenter, snapshot: { throw AppFailure.storage })
        await denied.setEnabled(true)
        try check(denied.authorization == .denied && deniedCenter.permissionRequests == 0 && deniedCenter.adds.isEmpty,
                  "denied permission does not prompt again or post notifications")
        let offlineCenter = SyntheticNotificationCenter(now: { clock }); offlineCenter.status = .authorized
        offlineCenter.requests["assignment.v1.synthetic"] = .init(id: "assignment.v1.synthetic", title: "", body: "", fireAt: clock, sound: false)
        let noBackend = NotificationController(defaults: nil, center: offlineCenter,
            backend: BackendClient(resourceDirectory: URL(fileURLWithPath: "/nonexistent-synthetic-backend")),
            snapshot: { (tasks, [.moodle]) }, restoredPreferences: enabled)
        await noBackend.refresh()
        try check(offlineCenter.requests.count == 1 && noBackend.errorMessage != nil, "failed backend preserves existing OS reservations and reports error")
        await noBackend.setEnabled(false)
        try check(offlineCenter.requests.isEmpty, "OFF still cancels OS requests if both storage and backend are unavailable")

        let unacknowledged = persisted.events + [.init(id: "assignment.v1.\(newTask.id.uuidString.lowercased()).\(Int(newTask.deadline.timeIntervalSince1970 * 1000)).0.newTask",
            taskID: newTask.id.uuidString.lowercased(), kind: "newTask", fireAt: now)]
        var crashState = persisted; crashState.events = unacknowledged; crashState.receipts = []
        let crashCenter = SyntheticNotificationCenter(now: { now }); crashCenter.status = .authorized
        crashCenter.delivered = Set(unacknowledged.map(\.id))
        let recovering = NotificationController(defaults: nil, center: crashCenter, snapshot: { ([newTask], [.moodle]) },
            restoredPreferences: enabled, restoredState: crashState, now: { now })
        await recovering.refresh()
        try check(crashCenter.adds.allSatisfy { !$0.hasSuffix(".newTask") }, "OS-delivered ID prevents replay if an earlier registration receipt was not saved")

        let gate = AsyncSyncGate(), racingCenter = SyntheticNotificationCenter(now: { clock })
        racingCenter.status = .authorized; racingCenter.addGate = gate
        let racing = NotificationController(defaults: nil, center: racingCenter,
            snapshot: { ([TaskItem(externalID: "race", source: .moodle, courseName: "授業", title: "競合",
                deadline: clock.addingTimeInterval(172800), completionIsKnown: true)], [.moodle]) }, restoredPreferences: enabled, now: { clock })
        let refreshing = Task { await racing.refresh() }
        let waitUntil = Date().addingTimeInterval(3)
        while !gate.waiting && Date() < waitUntil { try await Task.sleep(for: .milliseconds(2)) }
        try check(gate.waiting, "notification reconciliation awaits OS add without blocking UI")
        await racing.setEnabled(false)
        racingCenter.addGate = nil; gate.resume(); await refreshing.value
        try check(racingCenter.requests.isEmpty && racingCenter.delivered.isEmpty, "OFF during an in-flight add cannot reintroduce cancelled notifications")
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
            }, schedulingDefaults: nil)
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
        let vm = HomeViewModel(repository: repository, credentials: credentials, schedulingDefaults: nil)
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

        let denied = HomeViewModel(repository: repository, credentials: DeniedCredentials(), schedulingDefaults: nil)
        await denied.loadCredentials()
        try check(!denied.isLoadingCredentials && denied.errorMessage != nil, "denied Keychain access becomes a visible error, not a stuck launch")
        try check(denied.visibleTaskCount == 1, "denied authentication preserves visible offline cache")
        try check(denied.statusText(for: .moodle).contains("Keychain") && denied.statusText(for: .webClass).contains("Keychain"),
                  "each source reports credential access failure")
    }

    static func schedulingChecks() async throws {
        var clock = now
        var calls: [TaskSource] = []
        var allAutomatic = true
        let moodleOutcome: SyncOutcome = .attention
        let coordinator = SyncCoordinator(defaults: nil, usesSystemEvents: false,
            enabledSources: { [.moodle, .webClass] }, synchronize: { source, interactive in
                calls.append(source)
                allAutomatic = allAutomatic && !interactive
                return source == .moodle ? moodleOutcome : .success
            }, now: { clock })
        try check(coordinator.intervalSeconds == 1800 && coordinator.automaticEnabled, "default is 30 minute automatic sync")
        await coordinator.start()
        try check(calls == [.moodle, .webClass], "startup checks both sources independently")
        await coordinator.start()
        await coordinator.request(.wake)
        try check(calls.count == 2, "duplicate start and early wake do not duplicate sync")
        clock = clock.addingTimeInterval(86400)
        await coordinator.request(.wake)
        try check(calls == [.moodle, .webClass, .webClass], "wake coalesces missed intervals and skips authentication-blocked source")
        try check(allAutomatic, "automatic triggers never request interactive credentials")
        try check(coordinator.states.first(where: { $0.source == .moodle })?.blocked == true, "source requiring login remains paused")
        // A separately constructed coordinator tests explicit manual bypass without the auto-only assertion.
        var manualCalls = 0
        let manual = SyncCoordinator(defaults: nil, usesSystemEvents: false, enabledSources: { [.moodle] }, synchronize: { _, interactive in
            if interactive { manualCalls += 1 }
            return .success
        }, now: { clock })
        manual.setAutomaticEnabled(false)
        await manual.request(.wake)
        try check(manualCalls == 0 && manual.nextRunAt == nil, "automatic OFF suppresses wake sync")
        await manual.request(.manual)
        try check(manualCalls == 1 && manual.nextRunAt == nil, "manual sync works while automatic OFF")
        coordinator.stop(); manual.stop()

        let gate = AsyncSyncGate()
        var active = 0, peak = 0, runs = 0
        let serial = SyncCoordinator(defaults: nil, usesSystemEvents: false, enabledSources: { [.moodle] }, synchronize: { _, _ in
            active += 1; peak = max(peak, active); runs += 1
            if runs == 1 { await gate.wait() }
            active -= 1
            return .success
        })
        let first = Task { await serial.request(.manual) }
        let deadline = Date().addingTimeInterval(3)
        while !gate.waiting && Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try check(gate.waiting && serial.isRunning, "long-running sync is guarded before awaiting network")
        await serial.request(.wake)
        await serial.request(.manual)
        await serial.request(.manual)
        gate.resume()
        await first.value
        while (runs < 2 || serial.isRunning) && Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try check(runs == 2 && peak == 1, "overlapping manual requests coalesce into exactly one serial follow-up")
        serial.stop()

        let repository = try CoreDataTaskRepository(inMemory: true)
        let probe = CredentialModeProbe()
        var fetches = 0
        let vm = HomeViewModel(repository: repository, credentials: CredentialModeStore(probe: probe), connectorFactory: { source, _ in
            fetches += 1
            return SyntheticConnector(source: source, shouldFail: false)
        }, schedulingDefaults: nil)
        await vm.loadCredentials()
        try check(probe.quietReads == 3 && probe.interactiveReads == 0, "startup selects noninteractive Keychain adapter")
        let reads = probe.quietReads
        await vm.coordinator.request(.startup)
        try check(fetches == 1 && probe.quietReads == reads && probe.interactiveReads == 0, "automatic sync reuses memory credentials without any Keychain calls")
        await vm.syncAll()
        try check(probe.interactiveReads == 3 && fetches == 2, "explicit manual sync alone can refresh interactive credentials")

        let blockedProbe = CredentialModeProbe()
        let blocked = HomeViewModel(repository: repository, credentials: CredentialModeStore(probe: blockedProbe, denyQuiet: true), connectorFactory: { source, _ in
            SyntheticConnector(source: source, shouldFail: false)
        }, schedulingDefaults: nil)
        await blocked.loadCredentials()
        try check(!blocked.isConfigured && blocked.statusText(for: .moodle).contains("使用許可"), "noninteractive access denial provides explicit authorization guidance")
        await blocked.authorizeSavedCredentials()
        try check(blocked.isConfigured && blockedProbe.interactiveReads == 3, "explicit authorization restores saved configuration without re-entering the calendar URL")
        let demoLoginItem = LoginItemController(isDemo: true)
        await demoLoginItem.setEnabled(true)
        try check(!demoLoginItem.enabled, "demo mode cannot register a real login item")
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
            .appendingPathComponent("Moved App.app/Contents/Resources")
        let directory = resources.appendingPathComponent("Backend")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = ProcessInfo.processInfo.environment
        let worker = URL(fileURLWithPath: environment["ASSIGNMENT_BACKEND_DIR"]!).appendingPathComponent("worker.mjs")
        try FileManager.default.copyItem(at: worker, to: directory.appendingPathComponent("worker.mjs"))
        let helper = resources.deletingLastPathComponent().appendingPathComponent("Helpers/node")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: environment["ASSIGNMENT_BUNDLED_NODE_EXECUTABLE"]!).resolvingSymlinksInPath(), to: helper)
        let config = try JSONSerialization.data(withJSONObject: ["version": 1, "nodeExecutable": "../../Helpers/node"])
        try config.write(to: directory.appendingPathComponent("runtime.json"))
        let packaged = try await BackendClient(resourceDirectory: resources).parseICS(feed, timeZone: "Asia/Tokyo")
        try check(packaged == tasks, "app resource layout resolves and executes bundled worker")
        let selfCheck = try await BackendSelfCheck.run(backend: BackendClient(resourceDirectory: resources))
        try check(selfCheck.ok && selfCheck.checks.count == 5, "standalone diagnostic exercises synthetic backend features without private data")
        for unsafePath in [environment["ASSIGNMENT_NODE_EXECUTABLE"]!, "../../../node", "node"] {
            let unsafe = try JSONSerialization.data(withJSONObject: ["version": 1, "nodeExecutable": unsafePath])
            try unsafe.write(to: directory.appendingPathComponent("runtime.json"))
            do { _ = try await BackendClient(resourceDirectory: resources).health(); throw CheckFailure(label: "external runtime accepted") }
            catch let failure as AppFailure { try check(failure == .backend, "distributed runtime rejects external or arbitrary paths") }
        }
        try config.write(to: directory.appendingPathComponent("runtime.json"))
        let removed = helper.deletingLastPathComponent().appendingPathComponent("node-original")
        try FileManager.default.moveItem(at: helper, to: removed)
        try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: removed)
        do { _ = try await BackendClient(resourceDirectory: resources).health(); throw CheckFailure(label: "symlink runtime accepted") }
        catch let failure as AppFailure { try check(failure == .backend, "distributed runtime rejects symlink replacement") }
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

@MainActor
final class SyntheticNotificationCenter: TaskNotificationCenter {
    var status: NotificationAuthorization = .notDetermined
    var permissionRequests = 0
    var requests: [String: PendingTaskNotification] = [:]
    var delivered: Set<String> = []
    var adds: [String] = []
    var failAdds = false
    var addGate: AsyncSyncGate?
    let now: () -> Date
    init(now: @escaping () -> Date) { self.now = now }
    func authorization() async -> NotificationAuthorization { status }
    func requestAuthorization() async throws -> Bool { permissionRequests += 1; status = .authorized; return true }
    func pending() async -> [PendingTaskNotification] { Array(requests.values) }
    func deliveredIDs() async -> [String] { Array(delivered) }
    func add(_ request: PendingTaskNotification, taskID: UUID?) async throws {
        if let addGate { await addGate.wait() }
        if failAdds { throw AppFailure.storage }
        adds.append(request.id)
        if request.fireAt <= now() { delivered.insert(request.id) }
        else { requests[request.id] = request }
    }
    func removePending(_ ids: [String]) { for id in ids { requests.removeValue(forKey: id) } }
    func removeDelivered(_ ids: [String]) { for id in ids { delivered.remove(id) } }
}

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

@MainActor
final class AsyncSyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    func wait() async { await withCheckedContinuation { continuation = $0; waiting = true } }
    func resume() { continuation?.resume(); continuation = nil }
}

final class CredentialModeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var quiet = 0, interactive = 0
    var quietReads: Int { lock.withLock { quiet } }
    var interactiveReads: Int { lock.withLock { interactive } }
    func record(quiet value: Bool) { lock.withLock { if value { quiet += 1 } else { interactive += 1 } } }
}

struct CredentialModeStore: CalendarCredentialStore {
    let probe: CredentialModeProbe
    var denyQuiet = false
    var quiet = false
    func withoutAuthenticationUI() -> any CalendarCredentialStore { Self(probe: probe, denyQuiet: denyQuiet, quiet: true) }
    func calendarURL() throws -> URL? {
        probe.record(quiet: quiet)
        if denyQuiet && quiet { throw AppFailure.keychainAuthorizationRequired }
        return URL(string: "https://example.test/calendar/feed?authtoken=synthetic")
    }
    func moodleSession(for calendarURL: URL) throws -> MoodleSession? {
        probe.record(quiet: quiet)
        return MoodleSession(baseURL: KeychainService.moodleRoot(for: calendarURL), cookies: [])
    }
    func webClassSession() throws -> WebClassSession? { probe.record(quiet: quiet); return nil }
    func saveCalendarURL(_ text: String) throws {}
}
