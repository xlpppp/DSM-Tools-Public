import SwiftUI
import DSMKit

/// Edits a container's settings. Container Manager applies changes by recreating the container.
struct ContainerEditView: View {
    let original: String
    let onSaved: () async -> Void

    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ContainerProfile
    @State private var memoryMB: String
    @State private var choosingFolderFor: Int?
    @State private var confirmSave = false
    @State private var saving = false
    @State private var alert: String?

    init(original: String, profile: ContainerProfile, onSaved: @escaping () async -> Void) {
        self.original = original
        self.onSaved = onSaved
        _profile = State(initialValue: profile)
        _memoryMB = State(initialValue: profile.memoryLimit > 0 ? String(profile.memoryLimit / 1_048_576) : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("常规") {
                    LabeledContent("容器名称") {
                        TextField("名称", text: $profile.name).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("镜像", value: profile.image)
                    Toggle("自动重新启动", isOn: $profile.autoRestart)
                    TextField("执行命令（留空用镜像默认）", text: $profile.command)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    LabeledContent("内存限制") {
                        HStack {
                            TextField("不限制", text: $memoryMB)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                            Text("MB").foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Picker("CPU 优先级", selection: $profile.cpuPriority) {
                        Text("默认").tag(0)
                        Text("低").tag(10)
                        Text("中").tag(50)
                        Text("高").tag(90)
                        if ![0, 10, 50, 90].contains(profile.cpuPriority) {
                            Text("\(profile.cpuPriority)").tag(profile.cpuPriority)
                        }
                    }
                    Toggle("以高权限执行容器", isOn: $profile.privileged)
                } header: {
                    Text("资源")
                } footer: {
                    if profile.privileged {
                        Text("高权限容器可以访问 NAS 的全部设备，只对完全信任的镜像开启。").foregroundStyle(Theme.warning)
                    }
                }

                Section {
                    ForEach(profile.ports.indices, id: \.self) { i in
                        HStack {
                            TextField("本地", value: $profile.ports[i].hostPort, format: .number.grouping(.never))
                                .keyboardType(.numberPad)
                                .frame(maxWidth: 80)
                            Image(systemName: "arrow.right").foregroundStyle(Theme.secondaryText)
                            TextField("容器", value: $profile.ports[i].containerPort, format: .number.grouping(.never))
                                .keyboardType(.numberPad)
                                .frame(maxWidth: 80)
                            Spacer()
                            Picker("", selection: $profile.ports[i].proto) {
                                Text("TCP").tag("tcp")
                                Text("UDP").tag("udp")
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        .font(.callout.monospaced())
                    }
                    .onDelete { profile.ports.remove(atOffsets: $0) }
                    Button {
                        profile.ports.append(PortBinding(hostPort: nil, containerPort: 80))
                    } label: { Label("添加端口", systemImage: "plus") }
                } header: {
                    Text("端口映射（本地 → 容器）")
                }

                Section("存储空间映射") {
                    ForEach(profile.volumes.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                choosingFolderFor = i
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                    Text(profile.volumes[i].hostPath.isEmpty ? "选择 NAS 文件夹" : profile.volumes[i].hostPath)
                                        .lineLimit(1)
                                }
                            }
                            TextField("容器内路径，如 /data", text: $profile.volumes[i].mountPoint)
                                .font(.callout.monospaced())
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Toggle("只读", isOn: $profile.volumes[i].readOnly)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { profile.volumes.remove(atOffsets: $0) }
                    Button {
                        profile.volumes.append(VolumeBinding(hostPath: "", mountPoint: ""))
                    } label: { Label("添加文件夹", systemImage: "plus") }
                }

                Section("环境变量") {
                    ForEach(profile.env.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("名称", text: $profile.env[i].key)
                                .font(.caption.weight(.semibold).monospaced())
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                            if profile.env[i].isSensitive {
                                SecureField("值", text: $profile.env[i].value)
                                    .font(.callout.monospaced())
                            } else {
                                TextField("值", text: $profile.env[i].value)
                                    .font(.callout.monospaced())
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }
                    }
                    .onDelete { profile.env.remove(atOffsets: $0) }
                    Button {
                        profile.env.append(EnvVariable(key: "", value: ""))
                    } label: { Label("添加变量", systemImage: "plus") }
                }
            }
            .navigationTitle("编辑容器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("保存") { confirmSave = true } }
                }
            }
            .sheet(item: Binding(get: { choosingFolderFor.map(FolderSlot.init) }, set: { choosingFolderFor = $0?.index })) { slot in
                FolderPickerSheet(title: "选择文件夹") { path in
                    if profile.volumes.indices.contains(slot.index) { profile.volumes[slot.index].hostPath = path }
                }
            }
            .confirmationDialog("保存并重建容器？", isPresented: $confirmSave, titleVisibility: .visible) {
                Button("保存") { save() }
            } message: {
                Text("容器会按新设置重新创建，运行中的容器会重启。映射文件夹里的数据不受影响。")
            }
            .alert("保存失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alert ?? "")
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private struct FolderSlot: Identifiable {
        let index: Int
        var id: Int { index }
    }

    private func save() {
        guard let client = session.client else { return }
        var edited = profile
        edited.memoryLimit = (Int64(memoryMB.trimmingCharacters(in: .whitespaces)) ?? 0) * 1_048_576
        edited.env.removeAll { $0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        edited.volumes.removeAll { $0.hostPath.isEmpty || $0.mountPoint.isEmpty }
        saving = true
        Task {
            do {
                try await client.updateContainer(original, profile: edited)
                await onSaved()
                dismiss()
            } catch {
                alert = error.userMessage
            }
            saving = false
        }
    }
}
