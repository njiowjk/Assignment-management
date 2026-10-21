import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel: HomeViewModel

    @MainActor
    init(viewModel: HomeViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.sections.isEmpty {
                    emptyState
                } else {
                    taskList
                }
            }
            .navigationTitle("課題")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.reload()
                    } label: {
                        Label("再読み込み", systemImage: "arrow.clockwise")
                    }
                    .help("Phase 1のサンプルデータを再読み込み")
                }
            }
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private var taskList: some View {
        List {
            syncSummary

            ForEach(viewModel.sections) { section in
                Section {
                    ForEach(section.tasks) { task in
                        NavigationLink {
                            TaskDetailView(task: task, bucket: section.bucket)
                        } label: {
                            TaskRowView(task: task, bucket: section.bucket)
                        }
                    }
                } header: {
                    Label(section.bucket.rawValue, systemImage: section.bucket.systemImageName)
                        .font(.headline)
                        .foregroundStyle(section.bucket == .overdue ? Color.red : Color.primary)
                }
            }
        }
        .listStyle(.inset)
    }

    private var syncSummary: some View {
        Section {
            HStack {
                Label("未完了 \(viewModel.visibleTaskCount)件", systemImage: "checklist")
                    .font(.headline)

                Spacer()

                if let lastUpdatedAt = viewModel.lastUpdatedAt {
                    Text("サンプル更新 \(lastUpdatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("未完了の課題はありません")
                .font(.title3.weight(.semibold))
            Text("取得した課題は締切に応じてここへ表示されます。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
