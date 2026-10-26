import SwiftUI

/// Entry for the terminal module: shell, SFTP and Docker command line, all over the device's SSH settings.
struct SSHHubView: View {
    @Environment(DeviceStore.self) private var store
    @State private var editing = false

    var body: some View {
        List {
            Section {
                NavigationLink { TerminalScreen(title: "终端") } label: {
                    hubRow("SSH 终端", detail: "完整的命令行，支持方向键、Ctrl、Tab", symbol: "terminal.fill", color: Color(hex: 0x0F172A))
                }
                NavigationLink { SFTPScreen() } label: {
                    hubRow("SFTP 文件", detail: "浏览整个系统目录，上传下载", symbol: "folder.badge.gearshape", color: Color(hex: 0xF59E0B))
                }
                NavigationLink { TerminalScreen.docker } label: {
                    hubRow("Docker 命令行", detail: "常用 docker 命令一键输入", symbol: "cube.box.fill", color: Color(hex: 0x0EA5E9))
                }
            }
            if let ssh = store.selected?.ssh {
                Section("连接") {
                    InfoRow(label: "地址", value: ssh.host.isEmpty ? "沿用当前连接地址" : ssh.host)
                    InfoRow(label: "端口", value: ssh.port == 22 ? "自动（读取 DSM 设置，默认 22）" : String(ssh.port))
                    InfoRow(label: "账号", value: ssh.username.isEmpty ? store.selected?.username : ssh.username)
                    InfoRow(label: "主机指纹", value: ssh.trustedHostKeySHA256 == nil ? "未信任" : "已信任")
                    Button("修改 SSH 设置") { editing = true }
                }
            }
        }
        .navigationTitle("终端")
        .sheet(isPresented: $editing) { DeviceEditorView(profile: store.selected) }
    }

    private func hubRow(_ title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }
}

extension TerminalScreen {
    /// Docker needs root on DSM. Commands go through sudo with the app's prompt, which the terminal
    /// answers once with the saved SSH password; the app never keeps a root shell open.
    /// sudo's secure_path on DSM may not include /usr/local/bin, so docker is called by full path.
    static let sudoDocker = "sudo -p '\(TerminalController.sudoPrompt)' \"$(command -v docker || echo /usr/local/bin/docker)\""

    static var docker: TerminalScreen {
        TerminalScreen(title: "Docker 命令行", quickCommands: [
            .init(label: "ps -a", command: "\(sudoDocker) ps -a"),
            .init(label: "stats", command: "\(sudoDocker) stats --no-stream"),
            .init(label: "images", command: "\(sudoDocker) images"),
            .init(label: "compose ls", command: "\(sudoDocker) compose ls"),
            .init(label: "system df", command: "\(sudoDocker) system df"),
            .init(label: "network ls", command: "\(sudoDocker) network ls"),
            .init(label: "volume ls", command: "\(sudoDocker) volume ls"),
        ])
    }

    /// A shell inside a running container: bash when the image has it, otherwise sh.
    static func exec(into container: String) -> TerminalScreen {
        TerminalScreen(title: container,
                       initialCommand: "\(sudoDocker) exec -it \(shellQuoted(container)) sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
    }

    /// Follows a container's log in the terminal; used when the Web API can't return it.
    static func logs(of container: String) -> TerminalScreen {
        TerminalScreen(title: "\(container) 日志",
                       initialCommand: "\(sudoDocker) logs --tail 300 -f \(shellQuoted(container))")
    }

    /// Single-quotes a word for sh.
    static func shellQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
