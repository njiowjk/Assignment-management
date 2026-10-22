import AppKit
import SwiftUI

struct NotificationSettings: View {
    @ObservedObject var controller: NotificationController
    let isDemo: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("課題の通知").font(.title2.bold())
            Toggle("課題・締切の通知を有効にする", isOn: Binding(get: { controller.preferences.enabled }, set: { value in
                Task { await controller.setEnabled(value) }
            }))
            .disabled(isDemo || controller.isRequestingPermission)
            if controller.preferences.enabled {
                Text(permissionText).font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    option("新しい課題", \.newTask)
                    option("締切の24時間前", \.dayBefore)
                    option("締切の3時間前", \.hoursBefore)
                    option("締切の変更", \.deadlineChanged)
                    option("締切を迎えたとき（未完了のみ）", \.overdue)
                    option("通知音", \.sound)
                }.disabled(isDemo || controller.isRequestingPermission)
                HStack {
                    Button("テスト通知") { Task { await controller.sendTest() } }
                        .disabled(isDemo || controller.authorization != .authorized)
                    Button("macOSの通知設定を開く") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") { NSWorkspace.shared.open(url) }
                    }
                }
                Text("予約済み \(controller.scheduledCount)件").font(.caption).foregroundStyle(.secondary)
            }
            if let message = controller.testMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let message = controller.errorMessage { Text(message).font(.caption).foregroundStyle(.red) }
            Text("初回の既存課題・過去の締切はまとめて通知しません。提出状況が確認できた未完了課題だけが対象です。提出済みの確認・締切変更後に古い通知を取り消します。")
                .font(.caption).foregroundStyle(.secondary)
            Text("予約した通知はアプリ終了後も届きます。終了中は同期されないため、別の端末で提出した場合も、次の同期までは古い情報で通知されることがあります。OFFにすると予約を取り消します。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .task { if !isDemo { await controller.refresh() } }
        .onChange(of: scenePhase) { phase in
            if phase == .active && !isDemo { Task { await controller.refresh() } }
        }
    }

    private var permissionText: String {
        switch controller.authorization {
        case .authorized: "macOSの通知：許可済み（集中モードなどにより表示されない場合があります）"
        case .denied: "macOSの通知：拒否されています。「macOSの通知設定を開く」から許可してください。"
        case .notDetermined: "macOSの通知：未許可。一度OFFにしてからONにすると、許可を確認します。"
        }
    }

    private func option(_ label: String, _ key: WritableKeyPath<NotificationPreferences, Bool>) -> some View {
        Toggle(label, isOn: Binding(get: { controller.preferences[keyPath: key] }, set: { value in
            Task { await controller.setOption(key, value) }
        }))
    }
}
