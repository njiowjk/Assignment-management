import AppKit
import SwiftUI

struct MenuBarTaskView: View {
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject var coordinator: SyncCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("未完了 \(viewModel.visibleTaskCount)件", systemImage: "checklist").font(.headline)
                Spacer()
                if coordinator.isRunning { ProgressView().controlSize(.small) }
            }
            ForEach(viewModel.sections.prefix(3)) { section in
                Text("\(section.bucket.rawValue)　\(section.tasks.count)件").font(.caption)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(viewModel.sections.flatMap(\.tasks).prefix(6))) { task in
                        Button { showMain() } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.courseName).font(.caption).foregroundStyle(.secondary)
                                Text(task.title).lineLimit(2)
                                Text("\(task.deadline.formatted(date: .abbreviated, time: .shortened)) ・ \(task.source.rawValue)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                    if viewModel.visibleTaskCount == 0 { Text("確認済みの未完了課題はありません").font(.callout) }
                }
            }.frame(maxHeight: 260)
            if !viewModel.unknownTasks.isEmpty {
                Text("確認できなかった課題 \(viewModel.unknownTasks.count)件").font(.caption).foregroundStyle(.orange)
            }
            Text("Moodle：\(viewModel.statusText(for: .moodle))").font(.caption).lineLimit(2)
            Text("WebClass：\(viewModel.statusText(for: .webClass))").font(.caption).lineLimit(2)
            if let date = coordinator.nextRunAt {
                Text("次回同期 \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            } else { Text(coordinator.automaticEnabled ? "自動同期：連携・認証状態を確認してください" : "自動同期：OFF").font(.caption).foregroundStyle(.secondary) }
            if let error = coordinator.schedulingError { Text(error).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                Button("課題一覧") { showMain() }
                Button("今すぐ同期") { Task { await viewModel.syncAll() } }
                    .disabled(viewModel.isDemo || viewModel.isLoadingCredentials || coordinator.isRunning)
                Button("設定") { showMain(); viewModel.showingSettings = true }
                Spacer()
                Button("終了") { NSApplication.shared.terminate(nil) }
            }.controlSize(.small)
        }.padding(16).frame(width: 370)
    }

    private func showMain() {
        openWindow(id: "main")
        if #available(macOS 14, *) { NSApplication.shared.activate() }
        else { NSApplication.shared.activate(ignoringOtherApps: true) }
    }
}
