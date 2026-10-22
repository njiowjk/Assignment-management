import AppKit
import SwiftUI

struct AutomaticSyncSettings: View {
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject var coordinator: SyncCoordinator
    @ObservedObject var loginItem: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("常駐・自動同期").font(.title2.bold())
            Toggle("定期的に同期", isOn: Binding(get: { coordinator.automaticEnabled }, set: { coordinator.setAutomaticEnabled($0) }))
            Picker("同期間隔", selection: Binding(get: { coordinator.intervalSeconds }, set: { coordinator.setInterval($0) })) {
                Text("15分").tag(900)
                Text("30分").tag(1800)
                Text("1時間").tag(3600)
                Text("2時間").tag(7200)
            }.disabled(!coordinator.automaticEnabled)
            if let next = coordinator.nextRunAt {
                Text("次回同期：\(next.formatted(date: .abbreviated, time: .shortened))").font(.caption)
            }
            Text("ウィンドウを閉じてもメニューバーに常駐します。スリープ中・アプリ終了中は同期せず、復帰後に必要な分を1回だけ同期します。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Macログイン時に起動", isOn: Binding(get: { loginItem.enabled }, set: { value in
                Task { await loginItem.setEnabled(value) }
            })).disabled(loginItem.isUpdating)
            if loginItem.needsApproval {
                Text("自動起動の登録は完了しました。システム設定で承認が必要です。")
                    .font(.caption).foregroundStyle(.orange)
                Button("システム設定で確認") { loginItem.openSettings() }
            }
            if let error = loginItem.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            if let error = coordinator.schedulingError { Text(error).font(.caption).foregroundStyle(.red) }
            ForEach(coordinator.states.filter(\.blocked), id: \.source) { state in
                Text("\(state.source.rawValue)：自動同期を一時停止中です。連携・ログイン状態を確認し、「今すぐ同期」で再試行してください。")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button("保存済み連携情報を読み込む") { Task { await viewModel.authorizeSavedCredentials() } }
                .disabled(viewModel.isLoadingCredentials || coordinator.isRunning)
            Text("自動同期では認証ダイアログを表示しません。Keychainの許可が必要な場合は上のボタンで読み込み、大学サイトのセッションが切れた場合は各LMSへ再ログインしてください。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(viewModel.isDemo || !viewModel.storageAvailable)
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginItem.refresh() }
    }
}
