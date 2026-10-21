import Foundation

enum DeadlineBucket: String, CaseIterable, Identifiable, Sendable {
    case overdue = "期限切れ"
    case today = "今日"
    case tomorrow = "明日"
    case thisWeek = "今週"
    case later = "それ以降"

    var id: Self { self }

    var systemImageName: String {
        switch self {
        case .overdue: "exclamationmark.triangle.fill"
        case .today: "sun.max.fill"
        case .tomorrow: "sunrise.fill"
        case .thisWeek: "calendar"
        case .later: "calendar.badge.clock"
        }
    }
}

struct DeadlineClassifier: Sendable {
    let calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func bucket(for deadline: Date, relativeTo now: Date) -> DeadlineBucket {
        if deadline < now {
            return .overdue
        }

        if calendar.isDate(deadline, inSameDayAs: now) {
            return .today
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(deadline, inSameDayAs: tomorrow) {
            return .tomorrow
        }

        if let week = calendar.dateInterval(of: .weekOfYear, for: now),
           deadline >= week.start,
           deadline < week.end {
            return .thisWeek
        }

        return .later
    }
}
