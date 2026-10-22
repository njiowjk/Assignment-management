import AppKit
import Combine
import Foundation
import Network

/// App-owned service, independent of any window/menu view's lifetime.
/// Swift adapts OS events; TypeScript owns due/retry/attention policy.
@MainActor
final class SyncCoordinator: ObservableObject {
    static let intervals = [900, 1800, 3600, 7200]
    @Published private(set) var intervalSeconds: Int
    @Published private(set) var automaticEnabled: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var nextRunAt: Date?
    @Published private(set) var schedulingError: String?
    @Published private(set) var states: [SyncPolicyState]
    private let defaults: UserDefaults?
    private let backend: BackendClient
    private let enabledSources: @MainActor () -> [TaskSource]
    private let synchronize: @MainActor (TaskSource, Bool) async -> SyncOutcome
    private let refreshPresentation: @MainActor () -> Void
    private let usesSystemEvents: Bool
    private let now: @MainActor () -> Date
    private var timer: Timer?
    private var displayTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var monitor: NWPathMonitor?
    private var wasOnline: Bool?
    private var started = false
    private var pendingManual: Set<TaskSource> = []
    private let prefix = "sync.v1."

    init(defaults: UserDefaults? = .standard, backend: BackendClient = BackendClient(), usesSystemEvents: Bool = true,
         enabledSources: @escaping @MainActor () -> [TaskSource],
         synchronize: @escaping @MainActor (TaskSource, Bool) async -> SyncOutcome,
         refreshPresentation: @escaping @MainActor () -> Void = {}, now: @escaping @MainActor () -> Date = { .now }) {
        self.defaults = defaults; self.backend = backend; self.usesSystemEvents = usesSystemEvents
        self.enabledSources = enabledSources; self.synchronize = synchronize; self.refreshPresentation = refreshPresentation
        self.now = now
        let value = defaults?.integer(forKey: "sync.v1.interval") ?? 0
        intervalSeconds = Self.intervals.contains(value) ? value : 1800
        automaticEnabled = defaults?.object(forKey: "sync.v1.automatic") as? Bool ?? true
        states = defaults?.data(forKey: "sync.v1.states").flatMap { try? JSONDecoder().decode([SyncPolicyState].self, from: $0) } ?? []
        // A damaged scheduling preference must not make all future sync attempts fail.
        if states.count > 2 || Set(states.map(\.source)).count != states.count || states.contains(where: {
            !(0...20).contains($0.failureCount) || ($0.lastAttemptAt.map { !($0.timeIntervalSince1970.isFinite) || abs($0.timeIntervalSince1970) > 8.64e12 } ?? false)
        }) { states = [] }
    }

    func start() async {
        guard !started else { return }
        started = true
        if usesSystemEvents {
            let center = NSWorkspace.shared.notificationCenter
            observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.request(.wake) }
            })
            observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.timer?.invalidate(); self?.timer = nil }
            })
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let online = path.status == .satisfied
                Task { @MainActor in
                    guard let self else { return }
                    let reconnected = self.wasOnline == false && online
                    self.wasOnline = online
                    if reconnected { await self.request(.network) }
                }
            }
            monitor.start(queue: DispatchQueue(label: "jp.universitytaskmanager.connectivity"))
            self.monitor = monitor
            let clock = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshPresentation() }
            }
            clock.tolerance = 10
            RunLoop.main.add(clock, forMode: .common)
            displayTimer = clock
        }
        await request(.startup)
    }

    func stop() {
        started = false; timer?.invalidate(); timer = nil
        displayTimer?.invalidate(); displayTimer = nil
        for value in observers { NSWorkspace.shared.notificationCenter.removeObserver(value) }
        observers = []; monitor?.cancel(); monitor = nil; wasOnline = nil
    }

    func setInterval(_ seconds: Int) {
        guard Self.intervals.contains(seconds) else { return }
        intervalSeconds = seconds; defaults?.set(seconds, forKey: prefix + "interval")
        Task { await request(.timer) }
    }

    func setAutomaticEnabled(_ enabled: Bool) {
        automaticEnabled = enabled; defaults?.set(enabled, forKey: prefix + "automatic")
        if !enabled { timer?.invalidate(); timer = nil; nextRunAt = nil }
        else { Task { await request(.startup) } }
    }

    func request(_ trigger: SyncTrigger, sources: [TaskSource]? = nil) async {
        let targets = sources ?? enabledSources()
        guard trigger == .manual || automaticEnabled else { return }
        if isRunning {
            if trigger == .manual { pendingManual.formUnion(targets) }
            return
        }
        isRunning = true
        timer?.invalidate(); timer = nil
        defer {
            isRunning = false
            if !pendingManual.isEmpty {
                let queued = TaskSource.allCases.filter { pendingManual.contains($0) }
                pendingManual = []
                Task { await request(.manual, sources: queued) }
            }
        }
        do {
            schedulingError = nil
            let plan = try await backend.syncPolicy(states: states, enabled: targets, intervalSeconds: intervalSeconds, trigger: trigger, now: now())
            states = plan.states
            for source in plan.due {
                if Task.isCancelled { break }
                if trigger != .manual && !automaticEnabled { break }
                let outcome = await synchronize(source, trigger == .manual)
                let update = try await backend.syncPolicy(states: states, enabled: [], intervalSeconds: intervalSeconds,
                    trigger: .timer, event: SyncPolicyEvent(source: source, outcome: outcome), now: now())
                states = update.states
                persist()
            }
            let final = try await backend.syncPolicy(states: states, enabled: enabledSources(), intervalSeconds: intervalSeconds, trigger: .timer, now: now())
            states = final.states; persist()
            nextRunAt = automaticEnabled ? final.nextRunAt : nil
            armTimer()
        } catch is CancellationError {
            // OS termination/cancellation must not cause immediate retry loops.
        } catch {
            schedulingError = AppFailure.message(for: error)
            nextRunAt = automaticEnabled ? Date().addingTimeInterval(300) : nil
            armTimer()
        }
    }

    private func persist() { if let data = try? JSONEncoder().encode(states) { defaults?.set(data, forKey: prefix + "states") } }

    private func armTimer() {
        guard started, usesSystemEvents, automaticEnabled, let nextRunAt else { return }
        // A single timer; coalesce overdue events instead of replaying every missed interval.
        let delay = max(5, nextRunAt.timeIntervalSinceNow)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.request(.timer) }
        }
        timer.tolerance = min(30, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
