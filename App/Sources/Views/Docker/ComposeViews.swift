import SwiftUI
import DSMKit

/// All containers, with a running / stopped filter. Opened from the Docker page's top entry.
struct ContainerListView: View {
    enum Filter: String, CaseIterable { case all = "全部", running = "运行中", stopped = "已停止" }

    @Environment(SessionManager.self) private var session
    @State private var containers: [DockerContainer] = []
    @State private var resources: [String: ContainerResource] = [:]
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var loaded = false
    @State private var confirm: ContainerCommand?
    @State private var working: Set<String> = []
    @State private var alert: String?

    private var shown: [DockerContainer] {
        containers.filter { c in
            switch filter {
            case .all: return true
            case .running: return c.isRunning
            case .stopped: return !c.isRunning
            }
        }
        .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.image.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                Picker("筛选", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                ForEach(shown) { c in
                    NavigationLink {
                        ContainerDetailView(name: c.name)
                    } label: {
                        ContainerRow(container: c, resource: resources[c.name], working: working.contains(c.name))
                    }
                    .swipeActions(edge: .trailing) {
                        if c.isRunning {
                            Button { confirm = ContainerCommand(kind: .stop, name: c.name) } label: { Label("停止", systemImage: "stop.fill") }
                                .tint(Theme.danger)
                            Button { confirm = ContainerCommand(kind: .restart, name: c.name) } label: { Label("重启", systemImage: "arrow.clockwise") }
                                .tint(.orange)
                        } else {
                            Button { run(ContainerCommand(kind: .start, name: c.name)) } label: { Label("启动", systemImage: "play.fill") }
                                .tint(Theme.good)
                        }
                    }
                }
                if loaded && shown.isEmpty { Text("没有容器").foregroundStyle(Theme.secondaryText) }
            } footer: {
                Text("左滑可启动、停止、重启；点进容器可查看日志、终端和修改参数。")
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .searchable(text: $search, prompt: "搜索容器或镜像")
        .navigationTitle("容器")
        .refreshable { await load() }
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await load()
            }
        }
        .containerCommandDialog($confirm) { run($0) }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            containers = try await client.containers()
            if let r = try? await client.containerResources() {
                resources = Dictionary(r.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            }
        } catch {
            if !loaded { alert = error.userMessage }
        }
        loaded = true
    }

    private func run(_ command: ContainerCommand) {
        guard let client = session.client else { return }
        working.insert(command.name)
        Task {
            do {
                try await command.perform(on: client)
            } catch {
                alert = error.userMessage
            }
            working.remove(command.name)
            await load()
        }
    }
}

/// Container Manager projects (docker compose). Opened from the Docker page's top entry.
struct ComposeListView: View {
    @Environment(SessionManager.self) private var session
    @State private var projects: [DockerProject] = []
    @State private var search = ""
    @State private var loaded = false
    @State private var creating = false
    @State private var confirm: ContainerCommand?
    @State private var working: Set<String> = []
    @State private var alert: String?

    var body: some View {
        List {
            Section {
                ForEach(projects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { p in
                    NavigationLink {
                        ComposeDetailView(id: p.id, name: p.name)
                    } label: {
                        ComposeRow(project: p, working: working.contains(p.id))
                    }
                    .swipeActions(edge: .trailing) {
                        if p.isRunning {
                            Button { confirm = ContainerCommand(kind: .stopProject, name: p.id, label: p.name) } label: { Label("停止", systemImage: "stop.fill") }
                                .tint(Theme.danger)
                        } else {
                            Button { run(ContainerCommand(kind: .startProject, name: p.id, label: p.name)) } label: { Label("启动", systemImage: "play.fill") }
                                .tint(Theme.good)
                        }
                    }
                }
                if loaded && projects.isEmpty {
                    ContentUnavailableView("没有 Compose 项目", systemImage: "square.stack.3d.up",
                                           description: Text("点右上角 + 用 docker-compose.yml 新建。"))
                }
            } footer: {
                Text("Compose 项目即 Container Manager 中的「项目」，一个项目用一份 docker-compose.yml 管理一组容器。")
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .searchable(text: $search, prompt: "搜索项目")
        .navigationTitle("Compose")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { if await AdminGate.shared.unlock() { creating = true } } } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $creating) { ComposeCreateView { await load() } }
        .refreshable { await load() }
        .task { await load() }
        .containerCommandDialog($confirm) { run($0) }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        guard await client.hasDockerProjects else {
            alert = "当前 DSM 不支持 Compose 项目，需要 DSM 7.2 的 Container Manager。"
            loaded = true
            return
        }
        do {
            projects = try await client.dockerProjects()
        } catch {
            alert = error.userMessage
        }
        loaded = true
    }

    private func run(_ command: ContainerCommand) {
        guard let client = session.client else { return }
        working.insert(command.name)
        Task {
            do {
                try await command.perform(on: client)
            } catch {
                alert = error.userMessage
            }
            working.remove(command.name)
            await load()
        }
    }
}

struct ComposeRow: View {
    let project: DockerProject
    let working: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background((project.isRunning ? Color(hex: 0x6366F1) : Color(hex: 0x94A3B8)).gradient,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Circle()
                    .fill(project.isRunning ? Theme.good : Theme.secondaryText)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text([project.path, "\(project.containerCount) 个容器"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer()
            if working {
                ProgressView()
            } else {
                Text(project.isRunning ? "运行中" : "已停止").font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ComposeDetailView: View {
    let id: String
    let name: String

    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var detail: DockerProjectDetail?
    @State private var working = false
    @State private var editing = false
    @State private var confirmStop = false
    @State private var confirmBuild = false
    @State private var confirmDelete = false
    @State private var keepFiles = true
    @State private var alert: String?

    var body: some View {
        List {
            if let detail {
                Section {
                    HStack(spacing: 12) {
                        actionButton("启动", symbol: "play.fill", color: Theme.good, enabled: !detail.isRunning) {
                            perform { try await $0.startProject(id) }
                        }
                        actionButton("停止", symbol: "stop.fill", color: Theme.danger, enabled: detail.isRunning) {
                            confirmStop = true
                        }
                        actionButton("重新构建", symbol: "hammer.fill", color: .orange, enabled: true) {
                            confirmBuild = true
                        }
                    }
                    .overlay { if working { ProgressView() } }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section("项目") {
                    InfoRow(label: "状态", value: detail.statusLabel)
                    InfoRow(label: "路径", value: detail.path)
                }
                if !detail.containers.isEmpty {
                    Section("容器") {
                        ForEach(detail.containers, id: \.self) { c in
                            NavigationLink {
                                ContainerDetailView(name: c)
                            } label: {
                                Label(c, systemImage: "shippingbox")
                            }
                        }
                    }
                }
                Section {
                    if detail.content.isEmpty {
                        Text("没有读到 docker-compose.yml").foregroundStyle(Theme.secondaryText)
                    } else {
                        ScrollView(.horizontal) {
                            Text(detail.content)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(.vertical, 4)
                        }
                    }
                } header: {
                    HStack {
                        Text("docker-compose.yml")
                        Spacer()
                        Button("编辑") { Task { if await AdminGate.shared.unlock() { editing = true } } }
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        Task { if await AdminGate.shared.unlock() { confirmDelete = true } }
                    } label: {
                        Label("删除项目", systemImage: "trash")
                    }
                }
            }
        }
        .overlay { if detail == nil && alert == nil { ProgressView() } }
        .navigationTitle(detail?.name ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) {
            if let detail {
                ComposeEditorView(id: id, content: detail.content) { await load() }
            }
        }
        .confirmationDialog("停止项目「\(name)」中的所有容器？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("停止", role: .destructive) { perform { try await $0.stopProject(id) } }
        } message: {
            Text("容器提供的服务会中断。")
        }
        .confirmationDialog("重新构建「\(name)」？", isPresented: $confirmBuild, titleVisibility: .visible) {
            Button("重新构建", role: .destructive) { perform { try await $0.buildProject(id) } }
        } message: {
            Text("按当前 docker-compose.yml 拉取镜像并重建容器，服务会短暂中断。映射到 NAS 文件夹的数据会保留。")
        }
        .confirmationDialog("删除项目「\(name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除项目和容器，保留文件夹", role: .destructive) { delete(keepFiles: true) }
            Button("同时删除项目文件夹", role: .destructive) { delete(keepFiles: false) }
        } message: {
            Text("项目的容器会被删除，镜像会保留。删除后无法撤销；选「同时删除项目文件夹」会删掉 docker-compose.yml 及该文件夹里的数据。")
        }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
        .task { await load() }
        .refreshable { await load() }
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

    private func load() async {
        guard let client = session.client else { return }
        do {
            detail = try await client.projectDetail(id)
        } catch {
            alert = error.userMessage
        }
    }

    private func perform(_ action: @escaping (DSMClient) async throws -> Void) {
        guard let client = session.client else { return }
        working = true
        Task {
            do {
                try await action(client)
            } catch {
                alert = error.userMessage
            }
            working = false
            await load()
        }
    }

    private func delete(keepFiles: Bool) {
        guard let client = session.client else { return }
        working = true
        Task {
            do {
                try await client.deleteProject(id, preserveContent: keepFiles)
                dismiss()
            } catch {
                alert = error.userMessage
            }
            working = false
        }
    }
}

/// Edits a project's docker-compose.yml. Saving only stores the file; rebuilding applies it.
struct ComposeEditorView: View {
    let id: String
    let onSaved: () async -> Void

    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var saving = false
    @State private var rebuild = true
    @State private var alert: String?

    init(id: String, content: String, onSaved: @escaping () async -> Void) {
        self.id = id
        self.onSaved = onSaved
        _content = State(initialValue: content)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    YAMLEditor(text: $content)
                } footer: {
                    Text("缩进请用空格，不要用 Tab。")
                }
                Section {
                    Toggle("保存后立即重新构建", isOn: $rebuild)
                } footer: {
                    Text("不重新构建时，运行中的容器仍使用旧配置。")
                }
            }
            .navigationTitle("docker-compose.yml")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("保存") { save() }.disabled(content.isEmpty) }
                }
            }
            .alert("保存失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alert ?? "")
            }
        }
    }

    private func save() {
        guard let client = session.client else { return }
        saving = true
        Task {
            do {
                try await client.updateProject(id, content: content)
                if rebuild { try await client.buildProject(id) }
                await onSaved()
                dismiss()
            } catch {
                alert = error.userMessage
            }
            saving = false
        }
    }
}

/// New compose project in a NAS folder (Container Manager writes docker-compose.yml there).
struct ComposeCreateView: View {
    let onCreated: () async -> Void

    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var path = ""
    @State private var content = """
        services:
          app:
            image: nginx:latest
            restart: unless-stopped
            ports:
              - "8080:80"
        """
    @State private var choosingFolder = false
    @State private var saving = false
    @State private var startAfter = true
    @State private var alert: String?

    /// Container Manager only accepts lowercase letters, digits, "-" and "_".
    private var nameValid: Bool {
        !name.isEmpty && name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("项目名称（小写字母、数字、- _）", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        choosingFolder = true
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(path.isEmpty ? "选择项目文件夹（如 /docker/\(name.isEmpty ? "app" : name)）" : path).lineLimit(1)
                        }
                    }
                } footer: {
                    if !name.isEmpty && !nameValid { Text("名称只能包含小写字母、数字、- 和 _。").foregroundStyle(Theme.danger) }
                }
                Section("docker-compose.yml") {
                    YAMLEditor(text: $content)
                }
                Section {
                    Toggle("创建后立即构建并启动", isOn: $startAfter)
                }
            }
            .navigationTitle("新建 Compose 项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("创建") { create() }.disabled(!nameValid || path.isEmpty || content.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $choosingFolder) {
                FolderPickerSheet(title: "选择项目文件夹") { path = $0 }
            }
            .alert("创建失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alert ?? "")
            }
        }
    }

    private func create() {
        guard let client = session.client else { return }
        saving = true
        Task {
            do {
                try await client.createProject(name: name, sharePath: path, content: content)
                if startAfter, let project = try await client.dockerProjects().first(where: { $0.name == name }) {
                    try await client.buildProject(project.id)
                }
                await onCreated()
                dismiss()
            } catch {
                alert = error.userMessage
            }
            saving = false
        }
    }
}

/// A plain-text editor for YAML: monospaced, no autocorrect or smart quotes.
private struct YAMLEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.caption.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(minHeight: 280)
    }
}
