import SwiftUI
import WebKit
import DSMKit

/// DSM's own web desktop in an in-app browser, signed in automatically.
///
/// Sign-in: the app opens a separate DSM session for the browser (so logging out on the web page
/// doesn't drop the app's own connection) and hands DSM's session cookie to a private, in-memory
/// web view. The password never goes into a URL, a script or a log; it is only sent in the POST
/// body of the login request, exactly like every other login the app makes.
/// If that session can't be created (e.g. two-step verification without a remembered device),
/// the page simply opens at DSM's login screen.
struct WebDSMView: View {
    let device: DeviceProfile
    let endpoint: Endpoint

    @Environment(\.dismiss) private var dismiss
    @Environment(DeviceStore.self) private var store
    @Environment(SessionManager.self) private var session
    @State private var cookie: HTTPCookie?
    @State private var prepared = false
    @State private var note: String?
    @State private var webClient: DSMClient?
    @State private var model = WebViewModel()
    @State private var pageURL: URL?
    @State private var pagePin: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if prepared, let url = pageURL {
                    HomeDSMWebViewRepresentable(url: url, cookie: cookie, pinnedSHA256: pagePin, model: model)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView("正在登录网页版…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.loading && model.progress < 1 {
                    ProgressView(value: model.progress).progressViewStyle(.linear).tint(Theme.accent)
                }
            }
            .overlay(alignment: .bottom) {
                if let note {
                    Text(note)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .onTapGesture { self.note = nil }
                }
            }
            .navigationTitle(model.title.isEmpty ? device.name : model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.webView?.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!model.canGoBack)
                    Button { model.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .task { await prepare() }
        .onDisappear {
            let client = webClient
            Task { await client?.logout() }
        }
    }

    private func prepare() async {
        defer { prepared = true }
        let ports = endpoint.kind == .lan ? try? await sessionWebPorts() : nil
        guard let url = DSMWebAddress.url(endpoint: endpoint, ports: ports), let host = url.host else { return }
        pageURL = url
        let pagePort = url.port ?? (url.scheme == "https" ? 443 : 80)
        let pin = pagePort == endpoint.port ? endpoint.pinnedCertificateSHA256 : nil
        pagePin = pin
        guard let password = store.password(for: device.id) else {
            note = "没有保存密码，请在网页中手动登录"
            return
        }
        let client = DSMClient(baseURL: url,
                               transport: URLSessionTransport(pinnedSHA256: pin))
        do {
            let token = KeychainStore.get(KeychainStore.deviceTokenKey(device.id))
            let result = try await client.login(account: device.username, password: password, deviceToken: token)
            webClient = client
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: "id",
                .value: result.sid,
                .domain: host,
                .path: "/",
            ]
            if url.scheme == "https" { props[.secure] = "TRUE" }
            cookie = HTTPCookie(properties: props)
        } catch {
            note = "自动登录失败（\(error.userMessage)），请在网页中手动登录"
        }
    }

    /// Uses the app's already signed-in client. Failure just keeps the saved LAN port.
    private func sessionWebPorts() async throws -> DSMWebPorts {
        guard let client = session.client else { throw DSMError.notAuthenticated }
        return try await client.webPorts()
    }
}

@MainActor
@Observable
final class WebViewModel {
    var title = ""
    var progress = 0.0
    var loading = false
    var canGoBack = false
    @ObservationIgnored weak var webView: WKWebView?
}

private struct HomeDSMWebViewRepresentable: UIViewRepresentable {
    let url: URL
    let cookie: HTTPCookie?
    let pinnedSHA256: String?
    let model: WebViewModel

    func makeCoordinator() -> Coordinator { Coordinator(pinnedSHA256: pinnedSHA256, model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // In-memory only: the session cookie never touches disk and is gone when the page closes.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        model.webView = view
        context.coordinator.observe(view)

        let request = URLRequest(url: url)
        if let cookie {
            view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { view.load(request) }
        } else {
            view.load(request)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let pinnedSHA256: String?
        let model: WebViewModel
        private var observations: [NSKeyValueObservation] = []

        init(pinnedSHA256: String?, model: WebViewModel) {
            self.pinnedSHA256 = pinnedSHA256
            self.model = model
        }

        func observe(_ view: WKWebView) {
            observations = [
                view.observe(\.title) { [weak self] v, _ in
                    let title = v.title ?? ""
                    Task { @MainActor in self?.model.title = title }
                },
                view.observe(\.estimatedProgress) { [weak self] v, _ in
                    let p = v.estimatedProgress
                    Task { @MainActor in self?.model.progress = p }
                },
                view.observe(\.isLoading) { [weak self] v, _ in
                    let l = v.isLoading
                    Task { @MainActor in self?.model.loading = l }
                },
                view.observe(\.canGoBack) { [weak self] v, _ in
                    let b = v.canGoBack
                    Task { @MainActor in self?.model.canGoBack = b }
                },
            ]
        }

        /// Same rule as the app's API calls: a certificate the user pinned is accepted only if it
        /// still matches; otherwise normal system validation applies.
        func webView(_ webView: WKWebView,
                     respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  let pinned = pinnedSHA256 else {
                return (.performDefaultHandling, nil)
            }
            let seen = URLSessionTransport.leafFingerprint(trust) ?? ""
            if Self.hex(seen) == Self.hex(pinned) {
                return (.useCredential, URLCredential(trust: trust))
            }
            return (.cancelAuthenticationChallenge, nil)
        }

        private static func hex(_ fingerprint: String) -> String { fingerprint.uppercased().filter(\.isHexDigit) }
    }
}
