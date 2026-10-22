import Foundation

/// Presentation-only filter; never changes stored completion, synchronization, or notifications.
enum TaskDeadlineFilter: String, CaseIterable, Identifiable, Sendable {
    case upcoming
    case all
    case overdue

    var id: Self { self }

    init(savedValue: String?) { self = savedValue.flatMap(Self.init(rawValue:)) ?? .upcoming }

    var title: String {
        switch self {
        case .upcoming: "期限内"
        case .all: "すべて"
        case .overdue: "期限切れ"
        }
    }

    var emptyTitle: String {
        switch self {
        case .upcoming: "期限内の未完了課題はありません"
        case .all: "未完了の課題はありません"
        case .overdue: "期限切れの未完了課題はありません"
        }
    }

    func includes(deadline: Date, now: Date) -> Bool {
        switch self {
        case .upcoming: deadline >= now
        case .all: true
        case .overdue: deadline < now
        }
    }
}

struct TaskSection: Identifiable, Hashable, Sendable {
    let bucket: DeadlineBucket
    let tasks: [TaskItem]

    var id: DeadlineBucket { bucket }
}

struct TaskSectionBuilder: Sendable {
    let classifier: DeadlineClassifier

    init(classifier: DeadlineClassifier = DeadlineClassifier()) {
        self.classifier = classifier
    }

    func sections(from tasks: [TaskItem], now: Date, filter: TaskDeadlineFilter = .all) -> [TaskSection] {
        let grouped = Dictionary(grouping: tasks.filter { $0.isVisibleOnHome && filter.includes(deadline: $0.deadline, now: now) }) { task in
            classifier.bucket(for: task.deadline, relativeTo: now)
        }

        return DeadlineBucket.allCases.compactMap { bucket in
            guard let tasks = grouped[bucket], !tasks.isEmpty else {
                return nil
            }

            return TaskSection(
                bucket: bucket,
                tasks: tasks.sorted {
                    if $0.deadline == $1.deadline {
                        return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    }
                    return $0.deadline < $1.deadline
                }
            )
        }
    }
}

