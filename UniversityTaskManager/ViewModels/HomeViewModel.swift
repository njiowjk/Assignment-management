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

    let isDemo: Bool
    let storageAvailable: Bool
    private let repository: (any TaskRepository)?
    private let credentials: any CalendarCredentialStore
    private let sectionBuilder: TaskSectionBuilder

    init(
        repository: (any TaskRepository)?, isDemo: Bool = false,
        credentials: any CalendarCredentialStore = KeychainService(),
        sectionBuilder: TaskSectionBuilder = TaskSectionBuilder()
    ) {
        self.repository = repository
        self.isDemo = isDemo
        self.storageAvailable = repository != nil
        self.credentials = credentials
        self.sectionBuilder = sectionBuilder
        guard repository != nil else {
            errorMessage = AppFailure.storage.localizedDescription
            return
        }
        reload()
        if !isDemo {
            do {
                if let url = try credentials.calendarURL() {
                    isConfigured = true
                    loginBaseURL = KeychainService.moodleRoot(for: url)
                    hasMoodleSession = try credentials.moodleSession(for: url) != nil
                }
            }
            catch { errorMessage = AppFailure.message(for: error) }
        }
    }

    var visibleTaskCount: Int {
        sections.reduce(0) { $0 + $1.tasks.count }
    }

    func reload() {
        guard let repository else { return }
        do {
            let tasks = try repository.fetchTasks()
            sections = sectionBuilder.sections(from: tasks, now: .now)
            unknownTasks = tasks.filter { !$0.completionIsKnown && $0.status != .completed }.sorted { $0.deadline < $1.deadline }
            lastUpdatedAt = try repository.lastSyncedAt(for: .moodle)
        } catch { errorMessage = AppFailure.message(for: error) }
    }

    func configureCalendar(_ text: String) -> Bool {
        guard !isSyncing, !isDemo, storageAvailable else { return false }
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
        guard !isSyncing, !isDemo, let repository, isConfigured else { return }
        isSyncing = true
        errorMessage = nil
        syncMessage = nil
        defer { isSyncing = false }
        do {
            let existing = try repository.fetchTasks()
            let result = try await SyncService(repository: repository).sync(MoodleConnector(credentials: credentials, existing: existing))
            reload()
            syncMessage = "同期完了・新規 \(result.inserted)件／更新 \(result.updated)件／締切変更 \(result.deadlineChanges)件"
        } catch is CancellationError {
            // ウィンドウ終了などによるキャンセルは同期失敗として表示しない。
        } catch {
            if error as? AppFailure == .moodleLoginRequired { hasMoodleSession = false }
            errorMessage = AppFailure.message(for: error)
        }
    }
}

