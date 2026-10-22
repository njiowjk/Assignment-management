import SwiftUI
import WebKit

struct WebClassLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser: WebClassLoginModel
    let onConnect: @MainActor (WebClassSession) async -> String?

    init(previousSession: WebClassSession?, onConnect: @escaping @MainActor (WebClassSession) async -> String?) {
        _browser = StateObject(wrappedValue: WebClassLoginModel(previousSession: previousSession))
        self.onConnect = onConnect
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("WebClassにログイン").font(.title2.bold())
                Text("HOPPII → 法政大学統合認証 → WebClassの公式画面です。パスワードは保存しません。")
                    .font(.callout)
                Text("受験中・課題回答中は連携しないでください。ログイン後、課題一覧に進み「連携して同期」を押してください。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(browser.currentHost).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
            Divider()
            WebClassWebView(model: browser)
            Divider()
            if let error = browser.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal)
            }
            HStack {
                Button("閉じる") { dismiss() }.disabled(browser.isSaving)
                Button("HOPPIIで再ログイン") { browser.openPortal() }.disabled(browser.isSaving)
                Button("課題一覧へ") { browser.openDashboard() }.disabled(browser.isSaving || !browser.isOnWebClass)
                Spacer()
                if browser.isSaving { ProgressView().controlSize(.small) }
                Button(browser.isSaving ? "確認・同期中…" : "連携して同期") {
                    Task {
                        browser.isSaving = true
                        defer { browser.isSaving = false }
                        do {
                            let session = try await browser.captureSession()
                            if let error = await onConnect(session) { browser.errorMessage = error }
                            else { dismiss() }
                        } catch { browser.errorMessage = AppFailure.message(for: error) }
                    }
                }.buttonStyle(.borderedProminent).disabled(!browser.canConnect || browser.isSaving)
            }.padding()
        }.frame(width: 860, height: 700)
    }
}

private struct WebClassWebView: NSViewRepresentable {
    let model: WebClassLoginModel
    func makeNSView(context: Context) -> WKWebView { model.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
private final class WebClassLoginModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var canConnect = false
    @Published var isSaving = false
    @Published var isOnWebClass = false
    @Published var currentHost = "hoppii2025.hosei.ac.jp"
    @Published var errorMessage: String?

    init(previousSession: WebClassSession?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        Task {
            if let previousSession, previousSession.isValid {
                for value in previousSession.cookies {
                    if let cookie = value.nativeCookie {
                        await withCheckedContinuation { continuation in
                            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
                        }
                    }
                }
                openDashboard()
            } else { webView.load(URLRequest(url: WebClassSession.portalURL)) }
        }
    }

    func openDashboard() { webView.load(URLRequest(url: WebClassSession.dashboardURL)) }
    func openPortal() { webView.load(URLRequest(url: WebClassSession.portalURL)) }

    private func verifyLogin() async -> Bool {
        guard let url = webView.url, url.host == WebClassSession.baseURL.host,
              url.scheme == "https", url.path == WebClassSession.dashboardURL.path else { return false }
        // Only read dashboard configuration metadata, never credential inputs, names, or passwords.
        let script = """
        (() => [...document.querySelectorAll('script.js-config[type="application/json"]')].some(s => {
            try { const c = JSON.parse(s.textContent);
                return c.API_URL === '/webclass/ip_mods.php/plugin/score_summary_table' &&
                    c.TOP_URL === '/webclass/' && typeof c.userWebClassId === 'string' &&
                    /^[A-Za-z0-9_-]{1,200}$/.test(c.userWebClassId);
            } catch { return false; }
        }))()
        """
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in continuation.resume(returning: value as? Bool == true) }
        }
    }

    func captureSession() async throws -> WebClassSession {
        guard await verifyLogin() else { throw AppFailure.webClassLoginRequired }
        let cookies: [MoodleSession.Cookie] = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0.map(MoodleSession.Cookie.init))
            }
        }
        let session = WebClassSession(baseURL: WebClassSession.baseURL, cookies: cookies.filter(WebClassSession.accepts))
        guard session.isValid else { throw AppFailure.webClassLoginRequired }
        return session
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        currentHost = url.host ?? ""
        isOnWebClass = url.host == WebClassSession.baseURL.host
        errorMessage = nil
        Task {
            canConnect = await verifyLogin()
            if canConnect { return }
            // These are the exact public SSO/dashboard links observed in this university's UI.
            if url.host == "hoppii2025.hosei.ac.jp" && url.path == "/portal/u001/index.php" {
                webView.load(URLRequest(url: URL(string: "https://hoppii2025.hosei.ac.jp/portal/sso/Parm.php?auth_mode=1&group_id=")!))
            } else if isOnWebClass && url.path == "/webclass/" { openDashboard() }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { canConnect = false }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        errorMessage = "公式画面に接続できませんでした。ネットワークを確認してください。"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, WebClassSession.allowsNavigation(url) else {
            errorMessage = "大学の認証・WebClass以外への移動は許可していません。"
            decisionHandler(.cancel); return
        }
        // Never start a quiz, attendance registration, or other activity inside the login view.
        if url.host == WebClassSession.baseURL.host && url.path.contains("/contents/") {
            errorMessage = "この画面は連携専用です。教材は普段のブラウザで開いてください。"
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, WebClassSession.allowsNavigation(url) {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
