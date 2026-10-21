import Foundation
import Testing
@testable import UniversityTaskManager

struct DeadlineClassifierTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    @Test("締切を5区分へ分類する")
    func classifiesDeadlines() {
        let classifier = DeadlineClassifier(calendar: calendar)
        let now = date("2026-10-07T12:00:00Z") // Wednesday

        #expect(classifier.bucket(for: date("2026-10-07T11:59:00Z"), relativeTo: now) == .overdue)
        #expect(classifier.bucket(for: date("2026-10-07T17:00:00Z"), relativeTo: now) == .today)
        #expect(classifier.bucket(for: date("2026-10-08T09:00:00Z"), relativeTo: now) == .tomorrow)
        #expect(classifier.bucket(for: date("2026-10-11T23:00:00Z"), relativeTo: now) == .thisWeek)
        #expect(classifier.bucket(for: date("2026-10-12T09:00:00Z"), relativeTo: now) == .later)
    }

    @Test("完了済みを除外し、締切順に並べる")
    func buildsOrderedSections() {
        let now = date("2026-10-07T12:00:00Z")
        let tasks = [
            task(id: "later", deadline: date("2026-10-07T18:00:00Z")),
            task(id: "earlier", deadline: date("2026-10-07T13:00:00Z")),
            task(id: "completed", deadline: date("2026-10-07T12:30:00Z"), status: .completed)
        ]
        let builder = TaskSectionBuilder(
            classifier: DeadlineClassifier(calendar: calendar)
        )

        let sections = builder.sections(from: tasks, now: now)

        #expect(sections.count == 1)
        #expect(sections.first?.bucket == .today)
        #expect(sections.first?.tasks.map(\.externalID) == ["earlier", "later"])
    }

    private func task(id: String, deadline: Date, status: TaskStatus = .active) -> TaskItem {
        TaskItem(
            externalID: id,
            source: .moodle,
            courseName: "Course",
            title: id,
            deadline: deadline,
            status: status,
            firstDetectedAt: deadline,
            lastSyncedAt: deadline
        )
    }
}
