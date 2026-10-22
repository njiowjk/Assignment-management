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

    let isDemo: Bool
    let storageAvailable: Bool
    private let repository: (any TaskRepository)?
    private let credentials: any CalendarCredentialStore
    private let sectionBuilder: TaskSectionBuilder
    private let connectorFactory: (@MainActor (TaskSource, [TaskItem]) -> any TaskSourceConnector)?
    private var credentialsLoaded = false
    private var credentialLoadTask: Task<CredentialSnapshot, Never>?

    init(
        repository: (any TaskRepository)?, isDemo: Bool = false,
        credentials: any CalendarCredentialStore = KeychainService(),
        sectionBuilder: TaskSectionBuilder = TaskSectionBuilder(),
        connectorFactory: (@MainActor (TaskSource, [TaskItem]) -> any TaskSourceConnector)? = nil
    ) {
        self.repository = repository
        self.isDemo = isDemo
        self.storageAvailable = repository != nil
        self.credentials = credentials
        self.sectionBuilder = sectionBuilder
        self.connectorFactory = connectorFactory
        self.isLoadingCredentials = !isDemo && repository != nil
        guard repository != nil else {
            errorMessage = AppFailure.storage.localizedDescription
            return
        }
        reload()
    }

    /// Start only after SwiftUI has created the window. Keychain can display a blocking
    /// system authentication dialog, so it must not run in App/StateObject initialization.
    func loadCredentials() async {
        guard !credentialsLoaded, !isDemo, storageAvailable else { return }
        let task: Task<CredentialSnapshot, Never>
        if let pending = credentialLoadTask { task = pending }
        else {
            let store = credentials
            task = Task.detached(priority: .userInitiated) { CredentialSnapshot.read(from: store) }
            credentialLoadTask = task
        }
        let snapshot = await task.value
        guard !credentialsLoaded else { return }
        credentialsLoaded = true
        credentialLoadTask = nil
        isLoadingCredentials = false
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
        guard let url = try? credentials.calendarURL() else { return nil }
        return try? credentials.moodleSession(for: url)
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
        await loadCredentials()
        guard !Task.isCancelled else { return }
        guard isConfigured else { return }
        await syncSources([.moodle])
    }

    func currentWebClassSession() -> WebClassSession? { try? credentials.webClassSession() }

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
        await loadCredentials()
        guard !Task.isCancelled else { return }
        guard isWebClassConfigured else { return }
        await syncSources([.webClass])
    }

    func syncAll() async {
        await loadCredentials()
        guard !Task.isCancelled else { return }
        var sources: [TaskSource] = []
        if isConfigured { sources.append(.moodle) }
        if isWebClassConfigured { sources.append(.webClass) }
        await syncSources(sources)
    }

    private func syncSources(_ sources: [TaskSource]) async {
        guard !sources.isEmpty, !isSyncing, !isDemo, let repository else { return }
        isSyncing = true
        errorMessage = nil
        syncMessage = nil
        defer { isSyncing = false }
        var messages: [String] = [], failures: [String] = []
        for source in sources {
            do {
                try Task.checkCancellation()
                let connector: any TaskSourceConnector
                if let connectorFactory {
                    connector = connectorFactory(source, try repository.fetchTasks())
                } else if source == .moodle {
                    connector = MoodleConnector(credentials: credentials, existing: try repository.fetchTasks())
                } else { connector = WebClassConnector(credentials: credentials) }
                let result = try await SyncService(repository: repository).sync(connector)
                if source == .moodle { moodleSyncError = nil }
                else { webClassSyncError = nil; hasWebClassSession = true }
                messages.append("\(source.rawValue)：新規 \(result.inserted)件／更新 \(result.updated)件／締切変更 \(result.deadlineChanges)件")
            } catch is CancellationError { break }
            catch {
                let message = AppFailure.message(for: error)
                if source == .moodle {
                    moodleSyncError = message
                    if error as? AppFailure == .moodleLoginRequired { hasMoodleSession = false }
                } else {
                    webClassSyncError = message
                    if error as? AppFailure == .webClassLoginRequired { hasWebClassSession = false }
                }
                failures.append("\(source.rawValue)：\(message)")
                // One LMS failure must not prevent syncing the other source.
            }
        }
        syncMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        reload()
    }
}

private struct CredentialSnapshot: Sendable {
    var calendarURL: URL?
    var hasMoodleSession = false
    var hasWebClassSession = false
    var moodleError: String?
    var webClassError: String?

    static func read(from store: any CalendarCredentialStore) -> Self {
        var result = Self()
        do { result.hasWebClassSession = try store.webClassSession() != nil }
        catch { result.webClassError = AppFailure.message(for: error) }
        do {
            result.calendarURL = try store.calendarURL()
            if let url = result.calendarURL { result.hasMoodleSession = try store.moodleSession(for: url) != nil }
        } catch { result.moodleError = AppFailure.message(for: error) }
        return result
    }
}

