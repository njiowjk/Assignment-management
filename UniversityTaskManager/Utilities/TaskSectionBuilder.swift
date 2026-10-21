import Foundation

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

    func sections(from tasks: [TaskItem], now: Date) -> [TaskSection] {
        let grouped = Dictionary(grouping: tasks.filter(\.isVisibleOnHome)) { task in
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

