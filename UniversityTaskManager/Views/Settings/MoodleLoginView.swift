import SwiftUI
import WebKit

struct MoodleLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser: MoodleLoginModel
    let onConnect: @MainActor (MoodleSession) async -> String?

    init(baseURL: URL, previousSession: MoodleSession?,
         onConnect: @escaping @MainActor (MoodleSession) async -> String?) {
        _browser = StateObject(wrappedValue: MoodleLoginModel(baseURL: baseURL, previousSession: previousSession))
        self.onConnect = onConnect
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Moodleにログイン").font(.title2.bold())
                Text("大学公式サイト：\(browser.baseURL.host ?? "")")
                    .font(.callout).foregroundStyle(.secondary)
                Text("この画面でログイン後、「連携して同期」を押してください。パスワードはアプリに保存しません。")
                    .font(.callout)
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
            Divider()
            MoodleWebView(model: browser)
            Divider()
            if let error = browser.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal)
            }
            HStack {
                Button("閉じる") { dismiss() }.disabled(browser.isSaving)
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
                }
                .buttonStyle(.borderedProminent)
                .disabled(!browser.canConnect || browser.isSaving)
            }.padding()
        }
        .frame(width: 820, height: 680)
    }
}

private struct MoodleWebView: NSViewRepresentable {
    let model: MoodleLoginModel
    func makeNSView(context: Context) -> WKWebView { model.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
private final class MoodleLoginModel: NSObject, ObservableObject, WKNavigationDelegate {
    let baseURL: URL
    let webView: WKWebView
    @Published var canConnect = false
    @Published var isSaving = false
    @Published var errorMessage: String?

    init(baseURL: URL, previousSession: MoodleSession?) {
        self.baseURL = baseURL
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        Task {
            if let previousSession, previousSession.baseURL == baseURL {
                for value in previousSession.cookies where value.matches(baseURL) {
                    if let cookie = value.nativeCookie {
                        await withCheckedContinuation { continuation in
                            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                                continuation.resume()
                            }
                        }
                    }
                }
            }
            webView.load(URLRequest(url: baseURL))
        }
    }

    private var isOnMoodleOrigin: Bool {
        guard let current = webView.url else { return false }
        return current.scheme == "https" && current.host == baseURL.host &&
            (current.port ?? 443) == (baseURL.port ?? 443) && current.path.hasPrefix(baseURL.path)
    }

    private func verifyLogin() async -> Bool {
        guard isOnMoodleOrigin else { return false }
        let root = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let data = try? JSONEncoder().encode(root), let literal = String(data: data, encoding: .utf8) else { return false }
        // Read only login metadata, never username/password input values or page contents.
        let script = """
        (() => Boolean(window.M && M.cfg && M.cfg.userId > 0 &&
            M.cfg.wwwroot.replace(/\\/$/, '') === \(literal) &&
            !document.body.classList.contains('notloggedin')))()
        """
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? Bool == true)
            }
        }
    }

    func captureSession() async throws -> MoodleSession {
        guard await verifyLogin() else { throw AppFailure.moodleLoginRequired }
        let cookies: [MoodleSession.Cookie] = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.map(MoodleSession.Cookie.init))
            }
        }
        let scoped = cookies.filter { $0.matches(baseURL) }
        guard !scoped.isEmpty else { throw AppFailure.moodleLoginRequired }
        return MoodleSession(baseURL: baseURL, cookies: scoped)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { canConnect = await verifyLogin() }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        canConnect = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        errorMessage = "公式ログイン画面に接続できませんでした。ネットワークと、必要なら大学のVPNを確認してください。"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == "https", url.host == baseURL.host,
              (url.port ?? 443) == (baseURL.port ?? 443) else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
}
