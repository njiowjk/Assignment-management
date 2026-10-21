import SwiftUI

struct TaskDetailView: View {
    @Environment(\.openURL) private var openURL

    let task: TaskItem
    let bucket: DeadlineBucket

    var body: some View {
        Form {
            Section("課題") {
                LabeledContent("課題名", value: task.title)
                LabeledContent("授業名", value: task.courseName)
                LabeledContent("締切") {
                    Text(task.deadline.formatted(date: .long, time: .shortened))
                        .foregroundStyle(bucket == .overdue ? Color.red : Color.primary)
                }
                LabeledContent("取得元", value: task.source.rawValue)
                LabeledContent("状態", value: statusText)
                if !task.completionIsKnown {
                    Text("提出状況は未確認です。元のLMSで確認してください。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if task.isRemovedFromSource {
                    Text("今回のカレンダーには見つかりませんでした。取得期間外の可能性があるため、課題を残しています。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if let detail = task.detail, !detail.isEmpty {
                Section("説明") {
                    Text(detail)
                        .textSelection(.enabled)
                }
            }

            Section("同期情報") {
                LabeledContent("最終同期", value: task.lastSyncedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("外部ID", value: task.externalID)
            }

            if let sourceURL = task.sourceURL {
                Section {
                    Button("元のLMSページを開く") {
                        openURL(sourceURL)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(task.title)
        .frame(minWidth: 480, minHeight: 380)
    }

    private var statusText: String {
        if !task.completionIsKnown && task.status != .completed {
            return bucket == .overdue ? "期限切れ（提出状況未確認）" : "提出状況未確認"
        }
        return switch task.status {
        case .active:
            bucket == .overdue ? "期限切れ" : "未完了"
        case .overdue:
            "期限切れ"
        case .completed:
            "完了"
        case .unavailable:
            "取得不能"
        }
    }
}
