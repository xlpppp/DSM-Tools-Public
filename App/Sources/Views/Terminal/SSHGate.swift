import SwiftUI
import DSMKit
import DSMSSH

/// Opens an SSH session for the selected NAS (asking the user to confirm the host key on first use)
/// and hands it to `content`. The session closes when the view goes away.
struct SSHGate<Content: View>: View {
    @ViewBuilder let content: (SSHSession) -> Content

    @Environment(DeviceStore.self) private var store
    @Environment(SessionManager.self) private var manager
    @State private var state: GateState = .connecting
    @State private var session: SSHSession?
    @State private var editing = false

    enum GateState: Equatable {
        case connecting
        case needsTrust(fingerprint: String, changedFrom: String?)
        case failed(String)
        case ready
    }

    var body: some View {
        Group {
            switch state {
            case .ready:
                if let session { content(session) }
            case .connecting:
                ProgressView("正在连接 SSH…")
            case .failed(let message):
                ContentUnavailableView {
                    Label("SSH 连接失败", systemImage: "terminal")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { Task { await connect() } }
                        .buttonStyle(.borderedProminent)
                    Button("修改 SSH 设置") { editing = true }
                }
            case .needsTrust(let fingerprint, let old):
                trustPrompt(fingerprint: fingerprint, old: old)
            }
        }
        .task { await connect() }
        .sheet(isPresented: $editing, onDismiss: { Task { await connect() } }) {
            DeviceEditorView(profile: store.selected)
        }
        .onDisappear {
            let s = session
            session = nil
            Task { await s?.close() }
        }
    }

    private func trustPrompt(fingerprint: String, old: String?) -> some View {
        VStack(spacing: 18) {
            Image(systemName: old == nil ? "key.viewfinder" : "exclamationmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(old == nil ? Theme.accent : Theme.danger)
            Text(old == nil ? "首次连接，请核对主机指纹" : "主机指纹已改变")
                .font(.headline)
            Text(old == nil
                 ? "在 NAS 上执行 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 可查看指纹，一致后再信任。"
                 : "如果你没有重装系统或重置 SSH，这可能是中间人攻击，请不要继续。")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Text(fingerprint)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
            Button(old == nil ? "信任并连接" : "我确认已更换，信任新指纹", role: old == nil ? nil : .destructive) {
                guard let id = store.selected?.id else { return }
                store.trustSSH(fingerprint: fingerprint, deviceID: id)
                Task { await connect() }
            }
            .buttonStyle(.borderedProminent)
            .tint(old == nil ? Theme.accent : Theme.danger)
        }
        .padding(24)
    }

    private func connect() async {
        guard let profile = store.selected else {
            state = .failed("没有选中的设备")
            return
        }
        state = .connecting
        let ssh = profile.ssh
        let user = ssh.username.trimmingCharacters(in: .whitespaces).isEmpty ? profile.username : ssh.username
        guard let password = KeychainStore.get(KeychainStore.sshPasswordKey(profile.id)) ?? store.password(for: profile.id) else {
            state = .failed("没有保存密码，请在设备设置里填写")
            return
        }
        // DSM knows its own sshd port (Control Panel › Terminal & SNMP), so a changed port works
        // without the user typing it. Needs admin; without it we fall back to the settings.
        var reported: TerminalSettings?
        if let client = manager.client { reported = try? await client.terminalSettings() }
        if reported?.sshEnabled == false {
            state = .failed("DSM 未启用 SSH。请在 控制面板 › 终端机和 SNMP 中勾选“启动 SSH 功能”。")
            return
        }
        var targets = SSHTarget.candidates(settings: ssh, current: manager.endpoint, endpoints: profile.endpoints,
                                           reportedPort: reported?.sshPort)
        if targets.count > 1 {
            var reachable: [SSHTarget] = []
            for target in targets {
                if await PortProbe.isOpen(host: target.host, port: target.port) { reachable.append(target) }
            }
            if !reachable.isEmpty { targets = reachable }
        }
        guard !targets.isEmpty else {
            state = .failed("当前只通过 QuickConnect 连接，它不转发 SSH。请在 SSH 设置里填写可直连的地址和端口。")
            return
        }
        var failures: [String] = []
        for target in targets {
            do {
                session = try await SSHSession.connect(host: target.host, port: target.port, username: user,
                                                       password: password, trustedFingerprint: ssh.trustedHostKeySHA256,
                                                       timeout: targets.count > 1 ? 6 : 10)
                state = .ready
                return
            } catch let error as SSHError {
                switch error {
                case .unknownHostKey(let fp):
                    state = .needsTrust(fingerprint: fp, changedFrom: nil)
                    return
                case .hostKeyChanged(let expected, let actual):
                    state = .needsTrust(fingerprint: actual, changedFrom: expected)
                    return
                case .authenticationFailed:
                    state = .failed("\(target.display)：\(error.message)")
                    return
                case .unreachable(let detail):
                    failures.append("\(target.display)：\(detail)")
                case .failed(let detail):
                    failures.append("\(target.display)：\(detail)")
                }
            } catch {
                failures.append("\(target.display)：\(error.localizedDescription)")
            }
        }
        state = .failed("无法连接 SSH\n" + failures.joined(separator: "\n"))
    }
}
