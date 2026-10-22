import Combine
import Foundation

@MainActor
final class NotificationController: ObservableObject {
    @Published private(set) var preferences: NotificationPreferences
    @Published private(set) var authorization: NotificationAuthorization = .notDetermined
    @Published private(set) var errorMessage: String?
    @Published private(set) var scheduledCount = 0
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var testMessage: String?
    private(set) var state: NotificationState
    private let defaults: UserDefaults?
    private let center: any TaskNotificationCenter
    private let backend: BackendClient
    private let snapshot: @MainActor () throws -> ([TaskItem], [TaskSource])
    private let now: @MainActor () -> Date
    private var running = false
    private var refreshAgain = false
    private var generation = 0
    private var lastStateData: Data?
    private let prefix = "notifications.v1."

    init(defaults: UserDefaults? = .standard, center: any TaskNotificationCenter = MacTaskNotificationCenter(),
         backend: BackendClient = BackendClient(), snapshot: @escaping @MainActor () throws -> ([TaskItem], [TaskSource]),
         restoredPreferences: NotificationPreferences? = nil, restoredState: NotificationState? = nil,
         now: @escaping @MainActor () -> Date = { .now }) {
        self.defaults = defaults; self.center = center; self.backend = backend; self.snapshot = snapshot; self.now = now
        preferences = restoredPreferences ?? defaults?.data(forKey: "notifications.v1.preferences")
            .flatMap { try? JSONDecoder().decode(NotificationPreferences.self, from: $0) } ?? NotificationPreferences()
        state = restoredState ?? defaults?.data(forKey: "notifications.v1.state")
            .flatMap { try? JSONDecoder().decode(NotificationState.self, from: $0) } ?? NotificationState()
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isRequestingPermission else { return }
        generation += 1
        if enabled && !preferences.enabled {
            // Enabling is not a new-task event. Preserve receipts, silently baseline the cache.
            state.observations = []; state.sources = []; state.events = []
        }
        preferences.enabled = enabled; persistPreferences()
        testMessage = nil
        var permissionFailed = false
        if enabled {
            isRequestingPermission = true
            defer { isRequestingPermission = false }
            do {
                if await center.authorization() == .notDetermined { _ = try await center.requestAuthorization() }
            } catch { permissionFailed = true }
        }
        await refresh()
        if permissionFailed { errorMessage = "通知の許可を確認できませんでした。macOSのシステム設定を確認してください。" }
    }

    func setOption(_ key: WritableKeyPath<NotificationPreferences, Bool>, _ value: Bool) async {
        guard key != \.enabled else { await setEnabled(value); return }
        generation += 1
        preferences[keyPath: key] = value; persistPreferences()
        await refresh()
    }

    /// Serial, coalesced reconciliation; refresh snapshots after every successful DB merge.
    func refresh() async {
        if running { refreshAgain = true; return }
        running = true
        defer { running = false }
        repeat {
            refreshAgain = false
            let revision = generation
            do {
                authorization = await center.authorization()
                let pending = await center.pending(), delivered = await center.deliveredIDs()
                guard revision == generation else { refreshAgain = true; continue }
                let permitted = preferences.enabled && authorization == .authorized
                if !permitted {
                    // OFF must work even when storage/the TypeScript runtime is unavailable.
                    center.removePending(pending.filter { $0.id.hasPrefix("assignment.v1.") || $0.id == "assignment.test" }.map(\.id))
                    center.removeDelivered(delivered.filter { $0.hasPrefix("assignment.v1.") || $0 == "assignment.test" })
                    state.observations = []; state.sources = []; state.events = []; persistState()
                    scheduledCount = 0; errorMessage = nil
                    continue
                }
                let (tasks, synced) = try snapshot()
                let plan = try await backend.notificationPlan(tasks: tasks, syncedSources: synced,
                    preferences: preferences, state: state, now: now())
                guard revision == generation else { refreshAgain = true; continue }
                let valid = Set(plan.validIDs)
                let selected = Set(plan.requests.map(\.id))
                center.removePending(pending.filter {
                    $0.id.hasPrefix("assignment.v1.") && (!valid.contains($0.id) || ($0.fireAt > now() && !selected.contains($0.id)))
                }.map(\.id))
                center.removeDelivered(delivered.filter { $0.hasPrefix("assignment.v1.") && !valid.contains($0) })
                state = plan.state
                // Persist outbox/baseline before submitting. An interrupted add can be retried.
                persistState()
                let existing = Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let alreadyDelivered = Set(delivered)
                var hadFailure = false
                for item in plan.requests {
                    guard revision == generation else { refreshAgain = true; break }
                    let request = PendingTaskNotification(id: item.id, title: item.heading, body: item.body,
                        fireAt: item.fireAt, sound: preferences.sound)
                    let old = existing[item.id]
                    let acceptedAtBoundary = item.fireAt <= now().addingTimeInterval(1) && state.receipts.contains { $0.id == item.id }
                    // Do not repeatedly replace identical OS requests (especially at their firing boundary).
                    if !acceptedAtBoundary && !alreadyDelivered.contains(item.id) &&
                        (old == nil || old?.title != request.title || old?.body != request.body || old?.sound != request.sound) {
                        do { try await center.add(request, taskID: item.taskID) }
                        catch { hadFailure = true; continue }
                    }
                    if revision != generation {
                        center.removePending([item.id]); center.removeDelivered([item.id]); refreshAgain = true; break
                    }
                    if !state.receipts.contains(where: { $0.id == item.id && $0.fireAt == item.fireAt }) ||
                        state.events.contains(where: { $0.id == item.id }) {
                        state.receipts.removeAll { $0.id == item.id }
                        state.receipts.append(.init(id: item.id, fireAt: item.fireAt))
                        state.events.removeAll { $0.id == item.id }
                        // Save each new receipt; unchanged OS reservations do not rewrite the journal.
                        persistState()
                    }
                }
                scheduledCount = await center.pending().filter { $0.id.hasPrefix("assignment.v1.") }.count
                errorMessage = hadFailure ? "一部の通知を登録できませんでした。次回の確認時に再試行します。" : nil
            } catch {
                // A storage/backend failure must not erase pending requests or the receipt journal.
                errorMessage = "通知の予定を更新できませんでした。課題データは保持しています。"
            }
        } while refreshAgain
    }

    func sendTest() async {
        guard preferences.enabled, await center.authorization() == .authorized else {
            testMessage = "先に通知をONにし、macOSで許可してください。"; return
        }
        do {
            try await center.add(.init(id: "assignment.test", title: "大学課題管理のテスト通知",
                body: "通知が有効です。集中モードや通知の表示設定によって表示が制限される場合があります。",
                fireAt: now().addingTimeInterval(3), sound: preferences.sound), taskID: nil)
            testMessage = "3秒後のテスト通知を予約しました。"
        } catch { testMessage = "テスト通知を登録できませんでした。システム設定を確認してください。" }
    }

    private func persistPreferences() {
        if let data = try? JSONEncoder().encode(preferences) { defaults?.set(data, forKey: prefix + "preferences") }
    }
    private func persistState() {
        // Bounded, title/URL/credential-free journal. Keep the wire's millisecond dates separate from DB dates.
        state.receipts = Array(state.receipts.suffix(20_000))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(state), data != lastStateData {
            defaults?.set(data, forKey: prefix + "state"); lastStateData = data
        }
    }
}
