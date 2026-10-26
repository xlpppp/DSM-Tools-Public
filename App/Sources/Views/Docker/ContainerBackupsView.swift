import SwiftUI
import DSMKit

/// Backups of container settings on the NAS, plus image update and rollback.
/// With `container == nil` it lists every backup, which is how a deleted container is restored.
struct ContainerBackupsView: View {
    let container: String?

    @Environment(SessionManager.self) private var session
    @State private var backups: [RemoteFile] = []
    @State private var loaded = false
    @State private var step: ContainerJobStep?
    @State private var confirmUpdate = false
    @State private var restoring: RemoteFile?
    @State private var message: String?
    @State private var alert: String?

    var body: some View {
        List {
            if let container {
                Section {
                    Button { Task { await backup(container) } } label: {
                        Label("立即备份当前配置", systemImage: "externaldrive.badge.plus")
                    }
                    Button { Task { if await AdminGate.shared.unlock() { confirmUpdate = true } } } label: {
                        Label("拉取最新镜像并重建", systemImage: "arrow.triangle.2.circlepath")
                    }
                } footer: {
                    Text("更新前会自动备份。备份只含容器配置（镜像、端口、挂载、环境变量等），映射文件夹里的数据保持原样。")
                }
                .disabled(step != nil && step != .done)
            }
            if let step, step != .done {
                Section { HStack { ProgressView(); Text(step.label) } }
            }
            if let message {
                Section { Label(message, systemImage: "checkmark.circle").foregroundStyle(Theme.good) }
            }
            Section {
                ForEach(backups) { file in
                    Button { Task { if await AdminGate.shared.unlock() { restoring = file } } } label: { row(file) }
                        .buttonStyle(.plain)
                }
                if loaded && backups.isEmpty {
                    Text("还没有备份").foregroundStyle(Theme.secondaryText)
                }
            } header: {
                Text("备份（\(DSMClient.backupFolder)）")
            } footer: {
                Text("点一条备份可恢复或回滚。备份文件含环境变量原文，与 Container Manager 自身保存的一致，请勿共享该文件夹。")
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .navigationTitle(container.map { "\($0) · 备份" } ?? "容器备份")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("拉取最新镜像并重建容器？", isPresented: $confirmUpdate, titleVisibility: .visible) {
            Button("更新", role: .destructive) { Task { await update() } }
        } message: {
            Text("会停止并删除旧容器，再用相同配置创建新容器。期间服务中断；如新版本有问题，可从备份回滚。")
        }
        .sheet(item: $restoring) { file in
            RestoreBackupSheet(file: file) { backup, image in
                Task { await restore(backup, image: image) }
            }
        }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    private func row(_ file: RemoteFile) -> some View {
        let parts = file.name.replacingOccurrences(of: ".json", with: "").split(separator: "@", maxSplits: 1)
        return HStack {
            Image(systemName: "doc.badge.clock").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(parts.first ?? "")).font(.subheadline.weight(.medium))
                Text(file.modified?.formatted(date: .abbreviated, time: .shortened) ?? String(parts.last ?? ""))
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            backups = try await client.containerBackups(for: container)
        } catch {
            alert = error.userMessage
        }
        loaded = true
    }

    private func backup(_ name: String) async {
        guard let client = session.client else { return }
        step = .backingUp
        defer { step = nil }
        do {
            try await client.backupContainer(name, note: "手动备份")
            message = "已备份"
            await load()
        } catch {
            alert = error.userMessage
        }
    }

    private func update() async {
        guard let client = session.client, let container else { return }
        message = nil
        do {
            try await client.updateContainerImage(container) { s in Task { @MainActor in step = s } }
            message = "已更新并重新启动"
        } catch {
            alert = error.userMessage + "\n\n如容器已被删除，可从下方最新的自动备份恢复。"
        }
        step = nil
        await load()
    }

    private func restore(_ backup: ContainerBackup, image: String) async {
        guard let client = session.client else { return }
        message = nil
        do {
            try await client.restoreContainer(from: backup, image: image) { s in Task { @MainActor in step = s } }
            message = "已从备份恢复 \(backup.container)"
        } catch {
            alert = error.userMessage
        }
        step = nil
        await load()
    }
}

private struct RestoreBackupSheet: View {
    let file: RemoteFile
    let onRestore: (ContainerBackup, String) -> Void

    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var backup: ContainerBackup?
    @State private var image = ""
    @State private var confirm = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(error).foregroundStyle(Theme.warning) }
                if let backup {
                    Section("备份内容") {
                        InfoRow(label: "容器", value: backup.container)
                        InfoRow(label: "备份时镜像", value: backup.image)
                        InfoRow(label: "时间", value: backup.created.formatted(date: .abbreviated, time: .shortened))
                        if !backup.note.isEmpty { InfoRow(label: "备注", value: backup.note) }
                        InfoRow(label: "端口", value: backup.settings.ports.map(\.display).joined(separator: "\n").nilIfBlank)
                        InfoRow(label: "挂载", value: backup.settings.volumes.map { "\($0.hostPath) → \($0.mountPoint)" }
                            .joined(separator: "\n").nilIfBlank)
                    }
                    Section {
                        TextField("镜像", text: $image)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    } header: {
                        Text("使用的镜像")
                    } footer: {
                        Text("回滚镜像版本：把标签改成旧版本号（如 nginx:1.25），恢复时会先拉取该版本。标签为 latest 时只能恢复配置，无法退回旧镜像。")
                    }
                    Section {
                        Button("恢复此备份", role: .destructive) { confirm = true }
                    }
                } else if error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle("恢复备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .confirmationDialog("用这份备份重建容器？", isPresented: $confirm, titleVisibility: .visible) {
                Button("恢复", role: .destructive) {
                    if let backup { onRestore(backup, image.trimmingCharacters(in: .whitespaces)) }
                    dismiss()
                }
            } message: {
                Text("同名容器会先自动备份，再停止并删除，然后按备份配置重新创建并启动。")
            }
            .task {
                guard let client = session.client else { return }
                do {
                    let b = try await client.loadBackup(at: file.path)
                    backup = b
                    image = b.image
                } catch {
                    self.error = error.userMessage
                }
            }
        }
    }
}

extension ContainerJobStep {
    var label: String {
        switch self {
        case .backingUp: return "正在备份当前配置…"
        case .pulling(let image): return "正在拉取镜像 \(image)…"
        case .stopping: return "正在停止容器…"
        case .removing: return "正在删除旧容器…"
        case .creating: return "正在创建新容器…"
        case .starting: return "正在启动…"
        case .done: return "完成"
        }
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
