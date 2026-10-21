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
            do { isConfigured = try credentials.calendarURL() != nil }
            catch { errorMessage = AppFailure.message(for: error) }
        }
    }

    var visibleTaskCount: Int {
        sections.reduce(0) { $0 + $1.tasks.count }
    }

    func reload() {
        guard let repository else { return }
        do {
            sections = sectionBuilder.sections(from: try repository.fetchTasks(), now: .now)
            lastUpdatedAt = try repository.lastSyncedAt(for: .moodle)
        } catch { errorMessage = AppFailure.message(for: error) }
    }

    func configureCalendar(_ text: String) -> Bool {
        guard !isSyncing, !isDemo, storageAvailable else { return false }
        do {
            try credentials.saveCalendarURL(text)
            isConfigured = true
            errorMessage = nil
            syncMessage = "カレンダーURLをKeychainに保存しました。"
            return true
        } catch {
            errorMessage = AppFailure.message(for: error)
            return false
        }
    }

    func syncMoodle() async {
        guard !isSyncing, !isDemo, let repository, isConfigured else { return }
        isSyncing = true
        errorMessage = nil
        syncMessage = nil
        defer { isSyncing = false }
        do {
            let result = try await SyncService(repository: repository).sync(MoodleConnector(credentials: credentials))
            reload()
            syncMessage = "同期完了・新規 \(result.inserted)件／更新 \(result.updated)件／締切変更 \(result.deadlineChanges)件"
        } catch is CancellationError {
            // ウィンドウ終了などによるキャンセルは同期失敗として表示しない。
        } catch {
            errorMessage = AppFailure.message(for: error)
        }
    }
}

