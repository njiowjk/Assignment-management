import Combine
import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var sections: [TaskSection] = []
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var isConfigured = false
    @Published private(set) var isSyncing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var syncMessage: String?
    @Published private(set) var unknownTasks: [TaskItem] = []
    @Published private(set) var loginBaseURL: URL?
    @Published private(set) var hasMoodleSession = false
    @Published private(set) var isWebClassConfigured = false
    @Published private(set) var hasWebClassSession = false
    @Published private(set) var lastMoodleUpdatedAt: Date?
    @Published private(set) var lastWebClassUpdatedAt: Date?
    @Published private(set) var moodleSyncError: String?
    @Published private(set) var webClassSyncError: String?
    @Published private(set) var isLoadingCredentials: Bool
    @Published var showingSettings = false

    let isDemo: Bool
    let storageAvailable: Bool
    private let repository: (any TaskRepository)?
    private let credentials: any CalendarCredentialStore
    private let sectionBuilder: TaskSectionBuilder
    private let connectorFactory: (@MainActor (TaskSource, [TaskItem]) -> any TaskSourceConnector)?
    private var credentialsLoaded = false
    private var credentialLoadTask: Task<CredentialSnapshot, Never>?
    private var cachedCredentials = CredentialSnapshot()
    private var serviceTask: Task<Void, Never>?
    private let schedulingDefaults: UserDefaults?
    lazy var coordinator = SyncCoordinator(defaults: schedulingDefaults, usesSystemEvents: !isDemo,
        enabledSources: { [weak self] in self?.configuredSources ?? [] },
        synchronize: { [weak self] source, interactive in
            guard let self else { return .cancelled }
            return await self.performSync(source, interactive: interactive)
        }, refreshPresentation: { [weak self] in self?.reload() })
    lazy var loginItem = LoginItemController(isDemo: isDemo)

    init(
        repository: (any TaskRepository)?, isDemo: Bool = false,
        credentials: any CalendarCredentialStore = KeychainService(),
        sectionBuilder: TaskSectionBuilder = TaskSectionBuilder(),
        connectorFactory: (@MainActor (TaskSource, [TaskItem]) -> any TaskSourceConnector)? = nil,
        schedulingDefaults: UserDefaults? = .standard
    ) {
        self.repository = repository
        self.isDemo = isDemo
        self.storageAvailable = repository != nil
        self.credentials = credentials
        self.sectionBuilder = sectionBuilder
        self.connectorFactory = connectorFactory
        self.schedulingDefaults = isDemo ? nil : schedulingDefaults
        self.isLoadingCredentials = !isDemo && repository != nil
        guard repository != nil else {
            errorMessage = AppFailure.storage.localizedDescription
            return
        }
        reload()
    }

    /// Startup reads are noninteractive. Only an explicit user action may allow Keychain UI.
    /// The immutable snapshot is then reused by automated sync without Keychain calls.
    func loadCredentials(allowAuthenticationUI: Bool = false, force: Bool = false) async {
        if force && credentialLoadTask == nil { credentialsLoaded = false }
        guard !credentialsLoaded, !isDemo, storageAvailable else { return }
        let task: Task<CredentialSnapshot, Never>
        if let pending = credentialLoadTask { task = pending }
        else {
            isLoadingCredentials = true
            let store = allowAuthenticationUI ? credentials : credentials.withoutAuthenticationUI()
            task = Task.detached(priority: .userInitiated) { CredentialSnapshot.read(from: store) }
            credentialLoadTask = task
        }
        let snapshot = await task.value
        guard !credentialsLoaded else { return }
        credentialsLoaded = true
        credentialLoadTask = nil
        isLoadingCredentials = false
        cachedCredentials = snapshot
        isConfigured = snapshot.calendarURL != nil
        loginBaseURL = snapshot.calendarURL.map(KeychainService.moodleRoot)
        hasMoodleSession = snapshot.hasMoodleSession
        hasWebClassSession = snapshot.hasWebClassSession
        isWebClassConfigured = snapshot.hasWebClassSession
        moodleSyncError = snapshot.moodleError
        webClassSyncError = snapshot.webClassError
        let failures = [snapshot.moodleError, snapshot.webClassError].compactMap { $0 }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    func startServices() {
        guard serviceTask == nil, !isDemo else { return }
        serviceTask = Task { [weak self] in
            guard let self else { return }
            await self.loadCredentials()
            await self.coordinator.start()
        }
    }

    func stopServices() { serviceTask?.cancel(); serviceTask = nil; coordinator.stop() }

    private var configuredSources: [TaskSource] {
        TaskSource.allCases.filter { $0 == .moodle ? isConfigured : isWebClassConfigured }
    }

    func authorizeSavedCredentials() async {
        await loadCredentials(allowAuthenticationUI: true, force: true)
        await coordinator.request(.manual)
    }

    var visibleTaskCount: Int {
        sections.reduce(0) { $0 + $1.tasks.count }
    }

    var hasAnySource: Bool { isConfigured || isWebClassConfigured }

    func statusText(for source: TaskSource) -> String {
        if isLoadingCredentials { return "保存済みログイン情報を確認中…" }
        let failure = source == .moodle ? moodleSyncError : webClassSyncError
        if let failure { return failure }
        let configured = source == .moodle ? isConfigured : isWebClassConfigured
        let session = source == .moodle ? hasMoodleSession : hasWebClassSession
        guard configured else { return "未連携" }
        guard session else { return "ログインが必要です" }
        if coordinator.states.contains(where: { $0.source == source && $0.blocked }) {
            return "自動同期を一時停止中です。設定を確認し、手動で再試行してください。"
        }
        let date = source == .moodle ? lastMoodleUpdatedAt : lastWebClassUpdatedAt
        return date.map { "最終同期 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "未同期"
    }

    func reload() {
        guard let repository else { return }
        do {
            let tasks = try repository.fetchTasks()
            sections = sectionBuilder.sections(from: tasks, now: .now)
            unknownTasks = tasks.filter { !$0.completionIsKnown && $0.status != .completed }.sorted { $0.deadline < $1.deadline }
            lastMoodleUpdatedAt = try repository.lastSyncedAt(for: .moodle)
            lastWebClassUpdatedAt = try repository.lastSyncedAt(for: .webClass)
            lastUpdatedAt = [lastMoodleUpdatedAt, lastWebClassUpdatedAt].compactMap { $0 }.max()
        } catch { errorMessage = AppFailure.message(for: error) }
    }

    func configureCalendar(_ text: String) -> Bool {
        guard !isLoadingCredentials, !isSyncing, !isDemo, storageAvailable else { return false }
        do {
            try credentials.saveCalendarURL(text)
            let url = try KeychainService.validatedURL(text)
            loginBaseURL = KeychainService.moodleRoot(for: url)
            hasMoodleSession = try credentials.moodleSession(for: url) != nil
            isConfigured = true
            errorMessage = nil
            syncMessage = "カレンダーURLをKeychainに保存しました。"
            return true
        } catch {
            errorMessage = AppFailure.message(for: error)
            return false
        }
    }

    func currentMoodleSession() -> MoodleSession? {
        cachedCredentials.moodleSession
    }

    func connectMoodleSession(_ session: MoodleSession) async -> String? {
        do {
            guard let url = try credentials.calendarURL() else { throw AppFailure.invalidURL }
            try credentials.saveMoodleSession(session, for: url)
            hasMoodleSession = true
            await syncMoodle()
            return errorMessage
        } catch { return AppFailure.message(for: error) }
    }

    func syncMoodle() async {
        await loadCredentials(allowAuthenticationUI: true, force: true)
        guard !Task.isCancelled else { return }
        guard isConfigured else { return }
        await coordinator.request(.manual, sources: [.moodle])
    }

    func currentWebClassSession() -> WebClassSession? { cachedCredentials.webClassSession }

    func connectWebClassSession(_ session: WebClassSession) async -> String? {
        guard !isSyncing, !isDemo, storageAvailable else { return "同期中は連携できません。" }
        do {
            try credentials.saveWebClassSession(session)
            isWebClassConfigured = true
            hasWebClassSession = true
            await syncWebClass()
            return errorMessage
        } catch { return AppFailure.message(for: error) }
    }

    func syncWebClass() async {
        await loadCredentials(allowAuthenticationUI: true, force: true)
        guard !Task.isCancelled else { return }
        guard isWebClassConfigured else { return }
        await coordinator.request(.manual, sources: [.webClass])
    }

    func syncAll() async {
        await loadCredentials(allowAuthenticationUI: true, force: true)
        guard !Task.isCancelled else { return }
        await coordinator.request(.manual)
    }

    private func performSync(_ source: TaskSource, interactive: Bool) async -> SyncOutcome {
        guard !isSyncing, !isDemo, let repository else { return .cancelled }
        isSyncing = true
        errorMessage = nil
        syncMessage = nil
        defer { isSyncing = false }
        var outcome: SyncOutcome = .success
            do {
                try Task.checkCancellation()
                let connector: any TaskSourceConnector
                let store = CachedCredentialStore(snapshot: cachedCredentials)
                if let connectorFactory {
                    connector = connectorFactory(source, try repository.fetchTasks())
                } else if source == .moodle {
                    if !interactive && cachedCredentials.moodleSession == nil { throw AppFailure.moodleLoginRequired }
                    connector = MoodleConnector(credentials: store, existing: try repository.fetchTasks())
                } else { connector = WebClassConnector(credentials: store) }
                let result = try await SyncService(repository: repository).sync(connector)
                if source == .moodle { moodleSyncError = nil }
                else { webClassSyncError = nil; hasWebClassSession = true }
                syncMessage = "\(source.rawValue)：新規 \(result.inserted)件／更新 \(result.updated)件／締切変更 \(result.deadlineChanges)件"
            } catch is CancellationError { outcome = .cancelled }
            catch {
                let message = AppFailure.message(for: error)
                if source == .moodle {
                    moodleSyncError = message
                    if error as? AppFailure == .moodleLoginRequired { hasMoodleSession = false }
                } else {
                    webClassSyncError = message
                    if error as? AppFailure == .webClassLoginRequired { hasWebClassSession = false }
                }
                errorMessage = "\(source.rawValue)：\(message)"
                outcome = (error as? AppFailure == .network || error as? AppFailure == .server) ? .transient : .attention
                // One LMS failure must not prevent syncing the other source.
            }
        reload()
        return outcome
    }
}

private struct CredentialSnapshot: Sendable {
    var calendarURL: URL?
    var hasMoodleSession = false
    var hasWebClassSession = false
    var moodleError: String?
    var webClassError: String?
    var moodleSession: MoodleSession?
    var webClassSession: WebClassSession?

    static func read(from store: any CalendarCredentialStore) -> Self {
        var result = Self()
        do {
            result.webClassSession = try store.webClassSession()
            result.hasWebClassSession = result.webClassSession != nil
        }
        catch { result.webClassError = AppFailure.message(for: error) }
        do {
            result.calendarURL = try store.calendarURL()
            if let url = result.calendarURL {
                result.moodleSession = try store.moodleSession(for: url)
                result.hasMoodleSession = result.moodleSession != nil
            }
        } catch { result.moodleError = AppFailure.message(for: error) }
        return result
    }
}

/// Immutable, in-memory credentials for one sync. Automated sync never calls Keychain.
private struct CachedCredentialStore: CalendarCredentialStore {
    let snapshot: CredentialSnapshot
    func calendarURL() throws -> URL? { snapshot.calendarURL }
    func moodleSession(for calendarURL: URL) throws -> MoodleSession? { snapshot.moodleSession }
    func webClassSession() throws -> WebClassSession? { snapshot.webClassSession }
    func saveCalendarURL(_ text: String) throws { throw AppFailure.keychain }
}

