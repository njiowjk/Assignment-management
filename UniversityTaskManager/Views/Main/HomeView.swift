import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    @State private var showingSettings = false
    @State private var showingUnknown = false
    @Environment(\.scenePhase) private var scenePhase
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                syncSummary
                Divider()
                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                if viewModel.sections.isEmpty && viewModel.unknownTasks.isEmpty {
                    emptyState
                } else {
                    taskList
                }
            }
            .navigationTitle("課題")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("設定", systemImage: "gearshape")
                    }
                    .disabled(viewModel.isLoadingCredentials)
                    Button {
                        if viewModel.isDemo { viewModel.reload() }
                        else { Task { await viewModel.syncAll() } }
                    } label: {
                        Label("今すぐ同期", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isSyncing || (!viewModel.isDemo && !viewModel.hasAnySource))
                }
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .sheet(isPresented: $showingSettings) { SettingsView(viewModel: viewModel) }
        .onReceive(clock) { _ in viewModel.reload() }
        .onChange(of: scenePhase) { phase in if phase == .active { viewModel.reload() } }
    }

    private var taskList: some View {
        List {
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
            if !viewModel.unknownTasks.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showingUnknown) {
                        ForEach(viewModel.unknownTasks) { task in
                            let bucket = DeadlineClassifier().bucket(for: task.deadline, relativeTo: .now)
                            NavigationLink { TaskDetailView(task: task, bucket: bucket) } label: {
                                TaskRowView(task: task, bucket: bucket)
                            }
                        }
                    } label: {
                        Label("確認できなかった課題 \(viewModel.unknownTasks.count)件", systemImage: "questionmark.circle")
                    }
                } header: {
                    Text("未完了とは別に保存しています")
                }
            }
        }
        .listStyle(.inset)
    }

    private var syncSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("未完了 \(viewModel.visibleTaskCount)件", systemImage: "checklist")
                    .font(.headline)

                Spacer()

                if viewModel.isLoadingCredentials {
                    ProgressView().controlSize(.small)
                    Text("Keychainを確認中…")
                } else if viewModel.isSyncing {
                    ProgressView().controlSize(.small)
                    Text("同期中…")
                } else if let date = viewModel.lastUpdatedAt {
                    Text("最終同期 \(date.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("未同期")
                }
            }
            .font(.caption)
            if viewModel.isDemo {
                Text("サンプルデータを表示中").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Moodle：\(viewModel.statusText(for: .moodle))").font(.caption).foregroundStyle(.secondary)
                Text("WebClass：\(viewModel.statusText(for: .webClass))").font(.caption).foregroundStyle(.secondary)
            }
            if !viewModel.isDemo && !viewModel.isLoadingCredentials && (!viewModel.isWebClassConfigured || !viewModel.hasWebClassSession) {
                Button("WebClassにログインして連携") { showingSettings = true }.font(.callout)
            }
            if !viewModel.isDemo && !viewModel.isLoadingCredentials && viewModel.isConfigured && !viewModel.hasMoodleSession {
                Button("Moodleにログインして提出状況を確認") { showingSettings = true }
                    .font(.callout)
            }
            if !viewModel.unknownTasks.isEmpty {
                Text("提出状況を確認できていない課題が \(viewModel.unknownTasks.count)件あります。下の一覧から確認できます。")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let message = viewModel.syncMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
          if viewModel.isLoadingCredentials {
            ProgressView()
            Text("保存済みのログイン情報を確認しています")
                .font(.title3.weight(.semibold))
            Text("Keychainの確認画面が出た場合は認証してください。課題画面はこのまま開いています。")
                .foregroundStyle(.secondary)
          } else {
            Image(systemName: viewModel.hasAnySource ? "calendar" : "link.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
            Text(viewModel.hasAnySource ? "未完了の課題はありません" : "LMSを連携しましょう")
                .font(.title3.weight(.semibold))
            Text(viewModel.hasAnySource ? "同期すると、Moodle・WebClassの課題を締切順に表示します。" : "設定でMoodleまたはWebClassを連携すると、課題を取得できます。")
                .foregroundStyle(.secondary)
            if !viewModel.hasAnySource {
                Button("LMS連携を設定") { showingSettings = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.storageAvailable || viewModel.isDemo)
            }
          }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
