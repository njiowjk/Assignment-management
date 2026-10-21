import SwiftUI

struct TaskRowView: View {
    let task: TaskItem
    let bucket: DeadlineBucket

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.courseName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Label(task.source.rawValue, systemImage: task.source.systemImageName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(sourceColor)
            }

            Text(task.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)

            Label(deadlineText, systemImage: "clock")
                .font(.caption)
                .foregroundStyle(bucket == .overdue ? Color.red : Color.secondary)
            if task.isRemovedFromSource {
                Text("今回の取得範囲に見つかりません・保存済み")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var deadlineText: String {
        switch bucket {
        case .overdue:
            "期限切れ・\(task.deadline.formatted(date: .abbreviated, time: .shortened))"
        case .today:
            "今日 \(task.deadline.formatted(date: .omitted, time: .shortened))"
        case .tomorrow:
            "明日 \(task.deadline.formatted(date: .omitted, time: .shortened))"
        case .thisWeek, .later:
            task.deadline.formatted(date: .abbreviated, time: .shortened)
        }
    }

    private var sourceColor: Color {
        switch task.source {
        case .moodle: .orange
        case .webClass: .blue
        }
    }
}
