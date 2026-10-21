import Combine
import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var sections: [TaskSection] = []
    @Published private(set) var lastUpdatedAt: Date?

    private let repository: any TaskRepository
    private let sectionBuilder: TaskSectionBuilder
    private let nowProvider: () -> Date

    init(
        repository: any TaskRepository,
        sectionBuilder: TaskSectionBuilder = TaskSectionBuilder(),
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.sectionBuilder = sectionBuilder
        self.nowProvider = nowProvider
        reload()
    }

    var visibleTaskCount: Int {
        sections.reduce(0) { $0 + $1.tasks.count }
    }

    func reload() {
        let now = nowProvider()
        sections = sectionBuilder.sections(from: repository.fetchTasks(), now: now)
        lastUpdatedAt = now
    }
}

