import SwiftUI
import WebKit
import DSMKit

struct VirtualMachinesView: View {
    enum Power: String {
        case shutdown = "关机", powerOff = "强制断电"
    }

    @Environment(SessionManager.self) private var session
    @State private var vms: [VirtualMachine] = []
    @State private var loaded = false
    @State private var unavailable = false
    @State private var working: Set<String> = []
    @State private var pending: (vm: VirtualMachine, power: Power)?
    @State private var alert: String?

    var body: some View {
        List {
            if unavailable {
                ContentUnavailableView("未安装 Virtual Machine Manager", systemImage: "desktopcomputer",
                                       description: Text("请先在套件中心安装 Virtual Machine Manager。"))
            } else {
                Section {
                    ForEach(vms) { vm in row(vm) }
                    if loaded && vms.isEmpty { Text("没有虚拟机").foregroundStyle(Theme.secondaryText) }
                } footer: {
                    if !vms.isEmpty {
                        Text("控制台通过 DSM 网页版的 Virtual Machine Manager 打开，在其中选中虚拟机后点「连接」。")
                    }
                }
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .navigationTitle("虚拟机")
        .toolbar {
            if !unavailable {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { VMConsoleView() } label: { Image(systemName: "display") }
                }
            }
        }
        .task { await poll() }
        .refreshable { await load() }
        .confirmationDialog("\(pending?.power.rawValue ?? "")「\(pending?.vm.name ?? "")」？", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let p = pending {
                Button(p.power.rawValue, role: .destructive) { power(p.vm, p.power) }
            }
        } message: {
            Text(pending?.power == .powerOff
                 ? "相当于直接拔掉电源，未保存的数据会丢失，只在虚拟机无响应时使用。"
                 : "会通知虚拟机里的系统正常关机。")
        }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    private func row(_ vm: VirtualMachine) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background((vm.isRunning ? Color(hex: 0x14B8A6) : Color(hex: 0x94A3B8)).gradient,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.name).font(.subheadline.weight(.medium))
                Text([vm.vcpus.map { "\($0) 核" }, vm.memoryMB.map { Format.bytes(Int64($0) * 1_048_576) },
                      vm.disks.isEmpty ? nil : Format.bytes(Int64(vm.disks.compactMap(\.sizeMB).reduce(0, +)) * 1_048_576)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if working.contains(vm.id) {
                ProgressView()
            } else {
                Menu {
                    if vm.isRunning {
                        Button { pending = (vm, .shutdown) } label: { Label("关机", systemImage: "power") }
                        Button(role: .destructive) { pending = (vm, .powerOff) } label: {
                            Label("强制断电", systemImage: "bolt.slash")
                        }
                    } else {
                        Button { powerOn(vm) } label: { Label("开机", systemImage: "play.fill") }
                    }
                } label: {
                    StatusChip(text: vm.statusLabel, color: vm.isRunning ? Theme.good : Theme.secondaryText)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func poll() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        guard await client.hasVirtualMachineManager else {
            unavailable = true
            loaded = true
            return
        }
        do {
            vms = try await client.virtualMachines()
        } catch {
            if !loaded { alert = error.userMessage }
        }
        loaded = true
    }

    private func powerOn(_ vm: VirtualMachine) {
        act(vm) { try await $0.powerOnVM(vm.id) }
    }

    private func power(_ vm: VirtualMachine, _ p: Power) {
        pending = nil
        act(vm) { client in
            switch p {
            case .shutdown: try await client.shutdownVM(vm.id)
            case .powerOff: try await client.powerOffVM(vm.id)
            }
        }
    }

    private func act(_ vm: VirtualMachine, _ work: @escaping (DSMClient) async throws -> Void) {
        guard let client = session.client else { return }
        working.insert(vm.id)
        Task {
            do { try await work(client) } catch { alert = error.userMessage }
            working.remove(vm.id)
            await load()
        }
    }
}

/// DSM's Virtual Machine Manager in a web view, signed in with the app's session, for the noVNC console.
struct VMConsoleView: View {
    @Environment(SessionManager.self) private var session
    @State private var url: URL?
    @State private var sid: String?

    var body: some View {
        Group {
            if let url {
                DSMWebView(url: url, sessionID: sid, pinnedFingerprint: session.endpoint?.pinnedCertificateSHA256)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("虚拟机控制台")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let client = session.client else { return }
            sid = await client.sessionID
            url = client.vmManagerURL()
        }
    }
}

/// WKWebView for DSM pages. Hands over the session cookie and honours the certificate the user trusted.
struct DSMWebView: UIViewRepresentable {
    let url: URL
    let sessionID: String?
    let pinnedFingerprint: String?

    func makeCoordinator() -> Coordinator { Coordinator(pinned: pinnedFingerprint) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Keep DSM's cookies out of the shared store; they die with the view.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        // DSM's desktop UI is built for large screens; ask for the desktop layout.
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        if let sessionID, let host = url.host,
           let cookie = HTTPCookie(properties: [.domain: host, .path: "/", .name: "id", .value: sessionID, .secure: "TRUE"]) {
            config.websiteDataStore.httpCookieStore.setCookie(cookie) { view.load(URLRequest(url: url)) }
        } else {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let pinned: String?
        init(pinned: String?) { self.pinned = pinned }

        func webView(_ webView: WKWebView,
                     respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust, let pinned else {
                return (.performDefaultHandling, nil)
            }
            // Same rule as the API client: accept a self-signed certificate only if it is the one the user trusted.
            if URLSessionTransport.leafFingerprint(trust)?.uppercased() == pinned.uppercased() {
                return (.useCredential, URLCredential(trust: trust))
            }
            return (.performDefaultHandling, nil)
        }
    }
}
