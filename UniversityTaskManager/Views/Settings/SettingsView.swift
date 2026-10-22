import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: HomeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var calendarURL = ""
    @State private var pasteMessage: String?
    @FocusState private var isURLFocused: Bool
    @State private var showingLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Moodle連携").font(.title2.bold())
            Label(viewModel.isConfigured ? "カレンダーURL登録済み" : "未設定",
                  systemImage: viewModel.isConfigured ? "checkmark.shield" : "link")
            Text("Moodleの「カレンダー」→「カレンダーをエクスポート」から、授業の予定と十分な期間を選び「URLを取得」で生成したURLを貼り付けてください。")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField(viewModel.isConfigured ? "変更する場合は新しいURLを入力" : "HTTPSのカレンダーURL", text: $calendarURL)
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()
                    .focused($isURLFocused)
                    .accessibilityLabel("MoodleカレンダーURL")
                Button("貼り付け") {
                    // ボタンを押したときだけ読み、クリップボードや登録済みURLは変更しない。
                    if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                        calendarURL = text
                        pasteMessage = nil
                    } else {
                        pasteMessage = "コピーしたURLが見つかりません。MoodleでURLをコピーしてください。"
                    }
                    isURLFocused = true
                }
            }
            .disabled(viewModel.isSyncing)
            if let pasteMessage {
                Text(pasteMessage).font(.caption).foregroundStyle(.secondary)
            }
            if viewModel.isDemo {
                Text("デモモードでは入力を試せますが、URLの保存・同期は行いません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("URLはKeychainに保存されます。登録済みURLは画面に再表示しません。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Label(viewModel.hasMoodleSession ? "提出状況の自動確認：連携済み" : "提出状況の自動確認：ログインが必要です",
                  systemImage: viewModel.hasMoodleSession ? "checkmark.shield" : "person.crop.circle.badge.exclamationmark")
                .font(.callout)
            Button(viewModel.hasMoodleSession ? "Moodleに再ログイン" : "Moodleにログイン") { showingLogin = true }
                .disabled(viewModel.loginBaseURL == nil || viewModel.isDemo || viewModel.isSyncing)
            Text("初回のみ公式画面でログインしてください。以後の同期で提出済みを自動的に除外します。セッションが切れた場合は再ログインが必要です。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let message = viewModel.syncMessage {
                Text(message).foregroundStyle(.secondary)
            }
            HStack {
                Button("閉じる") { calendarURL = ""; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(viewModel.isSyncing ? "同期中…" : "保存して同期") {
                    if viewModel.configureCalendar(calendarURL) {
                        calendarURL = ""
                        Task { await viewModel.syncMoodle() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(calendarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          viewModel.isSyncing || viewModel.isDemo || !viewModel.storageAvailable)
            }
        }
        .padding(24)
        .frame(width: 510)
        .task { isURLFocused = true }
        .onDisappear { calendarURL = "" }
        .sheet(isPresented: $showingLogin) {
            if let baseURL = viewModel.loginBaseURL {
                MoodleLoginView(baseURL: baseURL, previousSession: viewModel.currentMoodleSession()) { session in
                    await viewModel.connectMoodleSession(session)
                }
            }
        }
    }
}
