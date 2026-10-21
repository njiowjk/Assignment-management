import Foundation

struct SampleTaskRepository: TaskRepository {
    private let calendar: Calendar
    private let now: Date

    init(calendar: Calendar = .autoupdatingCurrent, now: Date = .now) {
        self.calendar = calendar
        self.now = now
    }

    func fetchTasks() -> [TaskItem] {
        let todayStart = calendar.startOfDay(for: now)

        return [
            makeTask(
                id: "webclass-optimization-02",
                source: .webClass,
                course: "最適化",
                title: "第02回演習問題",
                detail: "期限を過ぎています。提出状況をWebClassで確認してください。",
                deadline: calendar.date(byAdding: .hour, value: -10, to: todayStart) ?? now,
                status: .overdue
            ),
            makeTask(
                id: "moodle-database-04",
                source: .moodle,
                course: "データベース",
                title: "第4回 SQL演習",
                detail: "SQLクエリを提出します。",
                deadline: date(onDayOffset: 0, hour: 17, minute: 0)
            ),
            makeTask(
                id: "webclass-english-week-03",
                source: .webClass,
                course: "科学英語2",
                title: "第3週の課題",
                detail: "指定された英文を読み、確認テストに回答します。",
                deadline: date(onDayOffset: 1, hour: 9, minute: 0)
            ),
            makeTask(
                id: "moodle-linear-algebra-report",
                source: .moodle,
                course: "線形代数",
                title: "レポート課題",
                detail: "PDF形式でレポートを提出します。",
                deadline: dateLaterThisWeek(hour: 23, minute: 59)
            ),
            makeTask(
                id: "webclass-programming-quiz",
                source: .webClass,
                course: "プログラミング基礎",
                title: "第6回確認テスト",
                detail: "授業内容のオンライン確認テストです。",
                deadline: date(onDayOffset: 10, hour: 18, minute: 0)
            ),
            makeTask(
                id: "moodle-completed-hidden",
                source: .moodle,
                course: "情報科学",
                title: "提出済み課題（一覧には表示されません）",
                deadline: date(onDayOffset: 1, hour: 12, minute: 0),
                status: .completed
            )
        ]
    }

    func lastSyncedAt(for source: TaskSource) -> Date? { now }

    func merge(_ tasks: [RemoteTask], source: TaskSource, at date: Date) throws -> SyncSummary {
        throw AppFailure.storage
    }

    private func makeTask(
        id: String,
        source: TaskSource,
        course: String,
        title: String,
        detail: String? = nil,
        deadline: Date,
        status: TaskStatus = .active
    ) -> TaskItem {
        TaskItem(
            externalID: id,
            source: source,
            courseName: course,
            title: title,
            detail: detail,
            deadline: deadline,
            status: status,
            sourceURL: nil,
            firstDetectedAt: now,
            lastSyncedAt: now,
            completedAt: status == .completed ? now : nil
        )
    }

    private func date(onDayOffset dayOffset: Int, hour: Int, minute: Int) -> Date {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private func dateLaterThisWeek(hour: Int, minute: Int) -> Date {
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now) else {
            return date(onDayOffset: 4, hour: hour, minute: minute)
        }

        let candidateDay = calendar.date(byAdding: .day, value: -1, to: weekInterval.end) ?? weekInterval.end
        let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: candidateDay) ?? candidateDay
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now

        if candidate > tomorrow {
            return candidate
        }

        return date(onDayOffset: 3, hour: hour, minute: minute)
    }
}

