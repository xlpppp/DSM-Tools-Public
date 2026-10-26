import SwiftUI
import DSMKit

struct ContainerDetailView: View {
    let name: String

    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var container: DockerContainer?
    @State private var resource: ContainerResource?
    @State private var profile: ContainerProfile?
    @State private var revealed: Set<String> = []
    @State private var confirm: ContainerCommand?
    @State private var editing = false
    @State private var working = false
    @State private var alert: String?

    var body: some View {
        List {
            if let container {
                header(container)
                Section("运行") {
                    InfoRow(label: "镜像", value: container.image)
                    InfoRow(label: "状态", value: container.upStatus ?? container.statusLabel)
                    InfoRow(label: "创建时间", value: container.created?.formatted(date: .abbreviated, time: .shortened))
                    if let resource, container.isRunning {
                        InfoRow(label: "CPU", value: String(format: "%.1f%%", resource.cpuPercent))
                        InfoRow(label: "内存", value: "\(Format.bytes(resource.memoryBytes))（\(String(format: "%.1f", resource.memoryPercent))%）")
                    }
                    NavigationLink {
                        ContainerLogsView(name: name)
                    } label: {
                        Label("日志", systemImage: "text.alignleft")
                    }
                    if container.isRunning {
                        NavigationLink {
                            TerminalScreen.exec(into: name)
                        } label: {
                            Label("容器内终端", systemImage: "terminal")
                        }
                    }
                }
            }
            if let profile {
                if !profile.ports.isEmpty {
                    Section("端口映射（本地 → 容器）") {
                        ForEach(profile.ports, id: \.self) { Text($0.display).font(.subheadline.monospaced()) }
                    }
                }
                if !profile.volumes.isEmpty {
                    Section("存储空间映射") {
                        ForEach(profile.volumes, id: \.self) { v in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.hostPath).font(.subheadline)
                                Text("→ \(v.mountPoint)\(v.readOnly ? "（只读）" : "")")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }
                if !profile.networks.isEmpty {
                    Section("网络") {
                        ForEach(profile.networks, id: \.self) { Text($0) }
                    }
                }
                if !profile.env.isEmpty {
                    Section {
                        ForEach(profile.env, id: \.self) { envRow($0) }
                    } header: {
                        Text("环境变量")
                    } footer: {
                        Text("密码、密钥类变量默认隐藏，点眼睛图标查看。")
                    }
                }
                Section("设置") {
                    InfoRow(label: "自动重启", value: profile.autoRestart ? "开启" : "关闭")
                    InfoRow(label: "内存限制", value: profile.memoryLimit > 0 ? Format.bytes(profile.memoryLimit) : "不限制")
                    InfoRow(label: "特权模式", value: profile.privileged ? "开启" : "关闭")
                    if !profile.command.isEmpty { InfoRow(label: "执行命令", value: profile.command) }
                }
            }
            if container != nil {
                Section {
                    NavigationLink {
                        ContainerBackupsView(container: name)
                    } label: {
                        Label("备份、更新与回滚", systemImage: "clock.arrow.circlepath")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        confirm = ContainerCommand(kind: .delete, name: name)
                    } label: {
                        Label("删除容器", systemImage: "trash")
                    }
                }
            }
        }
        .overlay { if container == nil && alert == nil { ProgressView() } }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { editing = true }.disabled(profile == nil)
            }
        }
        .sheet(isPresented: $editing) {
            if let profile {
                ContainerEditView(original: name, profile: profile) { await load() }
            }
        }
        .containerCommandDialog($confirm) { run($0) }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func header(_ c: DockerContainer) -> some View {
        Section {
            HStack(spacing: 12) {
                actionButton("启动", symbol: "play.fill", color: Theme.good, enabled: !c.isRunning) {
                    run(ContainerCommand(kind: .start, name: name))
                }
                actionButton("停止", symbol: "stop.fill", color: Theme.danger, enabled: c.isRunning) {
                    confirm = ContainerCommand(kind: .stop, name: name)
                }
                actionButton("重启", symbol: "arrow.clockwise", color: .orange, enabled: c.isRunning) {
                    confirm = ContainerCommand(kind: .restart, name: name)
                }
            }
            .overlay { if working { ProgressView() } }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private func actionButton(_ title: String, symbol: String, color: Color, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(enabled ? color : Theme.secondaryText.opacity(0.5))
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || working)
    }

    private func envRow(_ env: EnvVariable) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(env.key).font(.caption.weight(.semibold))
                Text(env.isSensitive && !revealed.contains(env.key) ? "••••••••" : env.value)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
            }
            Spacer()
            if env.isSensitive {
                Button {
                    if revealed.contains(env.key) { revealed.remove(env.key) } else { revealed.insert(env.key) }
                } label: {
                    Image(systemName: revealed.contains(env.key) ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            container = try await client.containers().first { $0.name == name }
            resource = try? await client.containerResources().first { $0.name == name }
            profile = try await client.containerProfile(name)
        } catch {
            alert = error.userMessage
        }
    }

    private func run(_ command: ContainerCommand) {
        guard let client = session.client else { return }
        working = true
        Task {
            do {
                try await command.perform(on: client)
                if command.kind == .delete {
                    dismiss()
                    return
                }
            } catch {
                alert = error.userMessage
            }
            working = false
            await load()
        }
    }
}

struct ContainerLogsView: View {
    let name: String
    @Environment(SessionManager.self) private var session
    @State private var lines: [ContainerLogLine] = []
    @State private var keyword = ""
    @State private var follow = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Section {
                    Text(error).foregroundStyle(Theme.warning)
                    NavigationLink {
                        TerminalScreen.logs(of: name)
                    } label: {
                        Label("改用 SSH 终端查看（docker logs）", systemImage: "terminal")
                    }
                }
            }
            ForEach(lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(line.isError ? Theme.danger : .primary)
                        .textSelection(.enabled)
                    Text(line.created).font(.caption2).foregroundStyle(Theme.secondaryText)
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay { if lines.isEmpty && error == nil { ContentUnavailableView("没有日志", systemImage: "text.alignleft") } }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $keyword, prompt: "搜索日志")
        .onSubmit(of: .search) { Task { await load() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { TerminalScreen.logs(of: name) } label: { Image(systemName: "terminal") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $follow) { Image(systemName: "dot.radiowaves.left.and.right") }
                    .toggleStyle(.button)
            }
        }
        .task(id: follow) {
            await load()
            while follow && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await load()
            }
        }
        .refreshable { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            lines = try await client.containerLogs(name, keyword: keyword.trimmingCharacters(in: .whitespaces)).lines
            error = nil
        } catch {
            self.error = error.userMessage
        }
    }
}
