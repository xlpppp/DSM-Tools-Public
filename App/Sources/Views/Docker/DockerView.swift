import SwiftUI
import DSMKit

struct DockerView: View {
    enum Tab: String, CaseIterable {
        case containers = "容器", projects = "Compose", images = "镜像", networks = "网络"
    }

    @Environment(SessionManager.self) private var session
    @State private var tab: Tab = .containers
    @State private var containers: [DockerContainer] = []
    @State private var resources: [String: ContainerResource] = [:]
    @State private var projects: [DockerProject] = []
    @State private var images: [DockerImage] = []
    @State private var networks: [DockerNetwork] = []
    @State private var loaded = false
    @State private var unavailable = false
    @State private var search = ""
    @State private var confirm: ContainerCommand?
    @State private var working: Set<String> = []
    @State private var alert: String?
    @State private var entry: Entry?

    enum Entry: Hashable { case containers, compose }

    var body: some View {
        List {
            if unavailable {
                ContentUnavailableView("未安装 Container Manager", systemImage: "cube.box",
                                       description: Text("请先在套件中心安装 Container Manager（DSM 7.1 及以下为 Docker 套件）。"))
            } else {
                Section {
                    entries
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    summary
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    Picker("分类", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                switch tab {
                case .containers: containerSection
                case .projects: projectSection
                case .images: imageSection
                case .networks: networkSection
                }
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .searchable(text: $search, prompt: "搜索")
        .navigationTitle("Docker")
        .navigationDestination(item: $entry) { e in
            switch e {
            case .containers: ContainerListView()
            case .compose: ComposeListView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { ContainerBackupsView(container: nil) } label: { Image(systemName: "clock.arrow.circlepath") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { TerminalScreen.docker } label: { Image(systemName: "terminal") }
            }
        }
        .refreshable { await loadAll() }
        .task { await poll() }
        .containerCommandDialog($confirm) { run($0) }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    /// The two management entries at the top: containers and compose projects.
    private var entries: some View {
        HStack(spacing: 10) {
            // Buttons rather than NavigationLinks: two links in one List row would both fire.
            Button {
                entry = .containers
            } label: {
                entryTile("容器", detail: "\(containers.filter(\.isRunning).count) 运行 / 共 \(containers.count)",
                          symbol: "shippingbox.fill", color: Color(hex: 0x0EA5E9))
            }
            Button {
                entry = .compose
            } label: {
                entryTile("Compose", detail: "\(projects.filter(\.isRunning).count) 运行 / 共 \(projects.count)",
                          symbol: "square.stack.3d.up.fill", color: Color(hex: 0x6366F1))
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, 10)
    }

    private func entryTile(_ title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }

    private var summary: some View {
        let running = containers.filter(\.isRunning).count
        let cpu = resources.values.reduce(0) { $0 + $1.cpuPercent }
        let memory = resources.values.reduce(Int64(0)) { $0 + $1.memoryBytes }
        return HStack(spacing: 10) {
            summaryTile("运行中", "\(running)/\(containers.count)", symbol: "play.circle.fill", color: Theme.good)
            summaryTile("CPU", String(format: "%.1f%%", cpu), symbol: "cpu", color: Theme.accent)
            summaryTile("内存", Format.bytes(memory), symbol: "memorychip", color: Theme.memory)
        }
        .padding(.bottom, 8)
    }

    private func summaryTile(_ title: String, _ value: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }

    private func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }

    // MARK: Sections

    private var containerSection: some View {
        Section {
            ForEach(containers.filter { matches($0.name) || matches($0.image) }) { c in
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
            if loaded && containers.isEmpty { Text("没有容器").foregroundStyle(Theme.secondaryText) }
        }
    }

    private var projectSection: some View {
        Section {
            ForEach(projects.filter { matches($0.name) }) { p in
                HStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color(hex: 0x0EA5E9).gradient, in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.subheadline.weight(.medium))
                        Text([p.path, "\(p.containerCount) 个容器"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    if working.contains(p.id) {
                        ProgressView()
                    } else {
                        Button(p.isRunning ? "停止" : "启动") {
                            if p.isRunning {
                                confirm = ContainerCommand(kind: .stopProject, name: p.id, label: p.name)
                            } else {
                                run(ContainerCommand(kind: .startProject, name: p.id, label: p.name))
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(p.isRunning ? Theme.danger : Theme.good)
                    }
                }
            }
            if loaded && projects.isEmpty { Text("没有 Compose 项目").foregroundStyle(Theme.secondaryText) }
        } footer: {
            Text("即 Container Manager 中的「项目」。点上方 Compose 入口可查看、编辑 docker-compose.yml，新建或删除项目。")
        }
    }

    private var imageSection: some View {
        Section {
            ForEach(images.filter { matches($0.display) }) { image in
                VStack(alignment: .leading, spacing: 3) {
                    Text(image.display).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text([Format.bytes(image.size), image.created?.formatted(date: .numeric, time: .omitted)]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }
        } footer: {
            Text("共 \(images.count) 个镜像，占用 \(Format.bytes(images.reduce(0) { $0 + $1.size }))")
        }
    }

    private var networkSection: some View {
        Section {
            ForEach(networks.filter { matches($0.name) }) { n in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(n.name).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(n.driver).font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    Text([n.subnet, n.gateway.map { "网关 \($0)" }, "\(n.containers.count) 个容器"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    // MARK: Data

    private func poll() async {
        await loadAll()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            await loadContainers()
        }
    }

    private func loadAll() async {
        guard let client = session.client else { return }
        guard await client.hasDocker else {
            unavailable = true
            loaded = true
            return
        }
        await loadContainers()
        async let p = try? client.dockerProjects()
        async let i = try? client.dockerImages()
        async let n = try? client.dockerNetworks()
        projects = await p ?? []
        images = await i ?? []
        networks = await n ?? []
        loaded = true
    }

    private func loadContainers() async {
        guard let client = session.client, !unavailable else { return }
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
            await loadAll()
        }
    }
}

struct ContainerRow: View {
    let container: DockerContainer
    let resource: ContainerResource?
    let working: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background((container.isRunning ? Color(hex: 0x0EA5E9) : Color(hex: 0x94A3B8)).gradient,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Circle()
                    .fill(container.isRunning ? Theme.good : Theme.secondaryText)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(container.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(container.image).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer()
            if working {
                ProgressView()
            } else if container.isRunning, let r = resource {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "CPU %.1f%%", r.cpuPercent))
                    Text(Format.bytes(r.memoryBytes))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
            } else {
                Text(container.statusLabel).font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A container or project action, kept as a value so dangerous ones can be confirmed first.
struct ContainerCommand: Identifiable {
    enum Kind { case start, stop, restart, delete, startProject, stopProject }
    let kind: Kind
    let name: String
    var label: String?

    var id: String { "\(kind)-\(name)" }
    var title: String { label ?? name }

    var needsConfirmation: Bool { kind != .start && kind != .startProject }

    var question: String {
        switch kind {
        case .start, .startProject: return "启动「\(title)」？"
        case .stop: return "停止容器「\(title)」？"
        case .restart: return "重启容器「\(title)」？"
        case .delete: return "删除容器「\(title)」？"
        case .stopProject: return "停止项目「\(title)」中的所有容器？"
        }
    }

    var detail: String {
        switch kind {
        case .delete: return "只删除容器本身，镜像和映射到 NAS 文件夹里的数据会保留。删除后无法撤销。"
        case .stop, .stopProject: return "容器提供的服务会中断。"
        case .restart: return "容器提供的服务会短暂中断。"
        default: return ""
        }
    }

    var verb: String {
        switch kind {
        case .start, .startProject: return "启动"
        case .stop, .stopProject: return "停止"
        case .restart: return "重启"
        case .delete: return "删除"
        }
    }

    func perform(on client: DSMClient) async throws {
        switch kind {
        case .start: try await client.startContainer(name)
        case .stop: try await client.stopContainer(name)
        case .restart: try await client.restartContainer(name)
        case .delete: try await client.deleteContainer(name, force: true)
        case .startProject: try await client.startProject(name)
        case .stopProject: try await client.stopProject(name)
        }
    }
}

extension View {
    func containerCommandDialog(_ command: Binding<ContainerCommand?>, run: @escaping (ContainerCommand) -> Void) -> some View {
        confirmationDialog(command.wrappedValue?.question ?? "", isPresented: Binding(
            get: { command.wrappedValue != nil }, set: { if !$0 { command.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: command.wrappedValue) { c in
            Button(c.verb, role: .destructive) { run(c) }
        } message: { c in
            Text(c.detail)
        }
    }
}
