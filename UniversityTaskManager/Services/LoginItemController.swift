import Combine
import Foundation
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isUpdating = false
    let isDemo: Bool

    init(isDemo: Bool = false) { self.isDemo = isDemo; if !isDemo { refresh() } }

    func refresh() {
        guard !isDemo else { return }
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ value: Bool) async {
        guard !isDemo, !isUpdating else { return }
        isUpdating = true; errorMessage = nil
        defer { isUpdating = false; refresh() }
        do {
            if value { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "自動起動の設定を変更できませんでした。システム設定の「一般」→「ログイン項目」で状態を確認してください。"
        }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
