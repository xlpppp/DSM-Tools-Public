import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import DSMKit

enum DriveRoute: Hashable {
    /// `ref` is a Drive path ("/mydrive/x") or "id:<n>".
    case folder(ref: String, name: String)
    case teamFolders
    case category(DriveCategory)
    case status
}

/// Entry point of the Synology Drive module: the portal's views plus server status.
struct DriveHomeView: View {
    @Environment(SessionManager.self) private var session
    @State private var available: Bool?
    @State private var status: DriveServerStatus?

    var body: some View {
        List {
            if available == false {
                Section {
                    ContentUnavailableView("未检测到 Synology Drive", systemImage: "externaldrive.badge.xmark",
                                           description: Text("请在套件中心安装并启用 Synology Drive Server。"))
                }
            } else {
                Section { statusCard }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                Section("浏览") {
                    ForEach(DriveCategory.allCases) { category in
                        NavigationLink(value: route(for: category)) {
                            Label {
                                Text(category.label)
                            } icon: {
                                Image(systemName: category.symbol).foregroundStyle(Module.drive.color)
                            }
                        }
                    }
                }
            }
        }
        .overlay { if available == nil { ProgressView() } }
        .navigationTitle("Synology Drive")
        .navigationDestination(for: DriveRoute.self) { route in
            switch route {
            case .status: DriveStatusView()
            default: DriveListView(route: route)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func route(for category: DriveCategory) -> DriveRoute {
        switch category {
        case .myDrive: return .folder(ref: "/mydrive/", name: category.label)
        case .teamFolders: return .teamFolders
        default: return .category(category)
        }
    }

    private var statusCard: some View {
        NavigationLink(value: DriveRoute.status) {
            HStack(spacing: 14) {
                Image(systemName: Module.drive.symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Module.drive.color.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Drive Server").font(.headline)
                    HStack(spacing: 6) {
                        if let package = status?.package {
                            StatusChip(text: package.statusLabel, color: package.isRunning ? Theme.good : Theme.warning)
                            Text("v\(package.version)").font(.caption).foregroundStyle(Theme.secondaryText)
                        } else if status != nil {
                            StatusChip(text: "已启用", color: Theme.good)
                        }
                        if let status {
                            Text("\(status.teamFolders.count) 个团队文件夹").font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .card()
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private func load() async {
        guard let client = session.client else { return }
        let has = await client.hasSynologyDrive
        available = has
        if has { status = await client.driveServerStatus() }
    }
}

// MARK: Listing

struct DriveListView: View {
    let route: DriveRoute

    @Environment(SessionManager.self) private var session
    @State private var items: [DriveItem] = []
    @State private var loaded = false
    @State private var loadError: String?
    @State private var sortKey = "name"
    @State private var ascending = true
    @State private var search = ""

    @State private var preview: RemoteFile?
    @State private var export: ExportItem?
    @State private var importing = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var busy: String?
    @State private var alert: String?

    private static let sortKeys: [(key: String, label: String)] = [
        ("name", "名称"), ("modified_time", "修改时间"), ("size", "大小"),
    ]

    private var title: String {
        switch route {
        case .folder(_, let name): return name
        case .teamFolders: return DriveCategory.teamFolders.label
        case .category(let c): return c.label
        case .status: return ""
        }
    }

    /// Only real folders accept uploads; the flat views (recent, starred…) do not.
    private var uploadFolder: String? {
        if case .folder(let ref, _) = route { return ref }
        return nil
    }

    private var visibleItems: [DriveItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if let loadError {
                Text(loadError).foregroundStyle(Theme.warning)
            }
            ForEach(visibleItems) { item in
                row(for: item)
                    .contextMenu { menu(for: item) }
            }
        }
        .overlay {
            if !loaded {
                ProgressView()
            } else if items.isEmpty && loadError == nil {
                ContentUnavailableView("这里还没有文件", systemImage: "externaldrive.badge.icloud")
            } else if visibleItems.isEmpty && !search.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .overlay(alignment: .bottom) { busyBanner }
        .searchable(text: $search, prompt: "搜索")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: sortKey) { Task { await load() } }
        .onChange(of: ascending) { Task { await load() } }
        .sheet(item: $preview) { FilePreviewView(file: $0) }
        .sheet(item: $export) { ActivityView(items: $0.items) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { upload(urls, scoped: true) }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, matching: .any(of: [.images, .videos]),
                      preferredItemEncoding: .current)
        .onChange(of: photoItems) { uploadPhotos() }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if uploadFolder != nil {
                Menu {
                    Button { importing = true } label: { Label("从文件上传", systemImage: "doc.badge.plus") }
                    Button { pickingPhotos = true } label: { Label("从相册上传", systemImage: "photo.badge.plus") }
                } label: { Image(systemName: "arrow.up.circle") }
                Menu {
                    Picker("排序", selection: $sortKey) {
                        ForEach(Self.sortKeys, id: \.key) { Text($0.label).tag($0.key) }
                    }
                    Toggle("升序", isOn: $ascending)
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
    }

    @ViewBuilder
    private func row(for item: DriveItem) -> some View {
        if item.isDirectory {
            NavigationLink(value: DriveRoute.folder(ref: folderRef(item), name: item.name)) { DriveRow(item: item) }
        } else {
            Button { open(item) } label: { DriveRow(item: item) }
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func menu(for item: DriveItem) -> some View {
        if !item.isDirectory {
            Button { open(item) } label: { Label("打开", systemImage: "eye") }
        }
        Button { download(item) } label: {
            Label(item.isDirectory ? "下载为 ZIP" : "下载到手机", systemImage: "arrow.down.circle")
        }
        Button { toggleStar(item) } label: {
            Label(item.starred ? "取消星标" : "加星标", systemImage: item.starred ? "star.slash" : "star")
        }
    }

    @ViewBuilder
    private var busyBanner: some View {
        if let busy {
            HStack(spacing: 10) {
                ProgressView()
                Text(busy).font(.subheadline)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 24)
        }
    }

    // MARK: Actions

    /// Folders under My Drive and team folders are addressed by path (uploads need one);
    /// anything else, such as items shared with me, by id.
    private func folderRef(_ item: DriveItem) -> String {
        item.fileStationPath != nil ? item.path : item.reference
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            switch route {
            case .folder(let ref, _):
                items = try await client.driveList(ref, sortBy: sortKey, ascending: ascending).items
            case .teamFolders:
                items = try await client.driveTeamFolders()
            case .category(let category):
                items = try await client.driveList(category).items
            case .status:
                items = []
            }
            loadError = nil
        } catch {
            loadError = error.userMessage
        }
        loaded = true
    }

    /// Opens in place through File Station when the item maps onto a File Station path
    /// (text, images, audio and video preview); otherwise downloads it and hands it to the share sheet.
    private func open(_ item: DriveItem) {
        if let path = item.fileStationPath {
            preview = RemoteFile(path: path, name: item.name, isDirectory: false, size: item.size, modified: item.modified)
        } else {
            download(item)
        }
    }

    private func download(_ item: DriveItem) {
        guard let client = session.client else { return }
        busy = "正在下载 \(item.name)…"
        Task {
            do {
                let local = try await client.driveDownload(item)
                export = ExportItem(items: [local])
            } catch {
                alert = error.userMessage
            }
            busy = nil
        }
    }

    private func toggleStar(_ item: DriveItem) {
        guard let client = session.client else { return }
        busy = item.starred ? "正在取消星标…" : "正在加星标…"
        Task {
            do {
                try await client.driveSetStarred([item], starred: !item.starred)
            } catch {
                alert = error.userMessage
            }
            busy = nil
            await load()
        }
    }

    private func upload(_ urls: [URL], scoped: Bool) {
        guard let client = session.client, let folder = uploadFolder, !urls.isEmpty else { return }
        let fileStationFolder = DriveItem.fileStationPath(for: folder.hasSuffix("/") ? String(folder.dropLast()) : folder)
        Task {
            var failed: [String] = []
            for (index, url) in urls.enumerated() {
                busy = "正在上传 \(index + 1)/\(urls.count)：\(url.lastPathComponent)"
                let access = scoped && url.startAccessingSecurityScopedResource()
                do {
                    try await client.driveUpload(fileAt: url, toFolder: folder)
                } catch {
                    // Drive's upload API is matched to the web portal but unverified on DSM 7.2;
                    // fall back to File Station, which writes to the same folder.
                    if let fileStationFolder {
                        do {
                            try await client.upload(fileAt: url, to: fileStationFolder)
                        } catch {
                            failed.append("\(url.lastPathComponent)：\(error.userMessage)")
                        }
                    } else {
                        failed.append("\(url.lastPathComponent)：\(error.userMessage)")
                    }
                }
                if access { url.stopAccessingSecurityScopedResource() }
                if !scoped { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            }
            busy = nil
            if !failed.isEmpty { alert = failed.joined(separator: "\n") }
            await load()
        }
    }

    private func uploadPhotos() {
        let picked = photoItems
        guard !picked.isEmpty else { return }
        photoItems = []
        busy = "正在读取照片…"
        Task {
            var urls: [URL] = []
            for item in picked {
                if let file = try? await item.loadTransferable(type: PickedFile.self) { urls.append(file.url) }
            }
            busy = nil
            if urls.count < picked.count { alert = "有 \(picked.count - urls.count) 项无法读取（可能仍在 iCloud 中下载）。" }
            upload(urls, scoped: false)
        }
    }
}

struct DriveRow: View {
    let item: DriveItem

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(kind: item.kind)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if item.starred {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    if item.shared {
                        Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(Theme.secondaryText)
                    }
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts: [String] = []
        if !item.isDirectory, let size = item.size { parts.append(Format.bytes(size)) }
        if let date = item.modified { parts.append(date.formatted(date: .numeric, time: .shortened)) }
        if let owner = item.owner { parts.append(owner) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Server status

/// Drive Server side: package state, team folders, connected clients, advertised APIs.
struct DriveStatusView: View {
    @Environment(SessionManager.self) private var session
    @State private var status: DriveServerStatus?

    var body: some View {
        List {
            if let status {
                Section("服务") {
                    InfoRow(label: "套件状态", value: status.package?.statusLabel ?? "无权限读取")
                    InfoRow(label: "版本", value: status.package?.version)
                    InfoRow(label: "团队文件夹", value: "\(status.teamFolders.count) 个")
                }
                if !status.teamFolders.isEmpty {
                    Section("团队文件夹") {
                        ForEach(status.teamFolders) { folder in
                            Label(folder.name, systemImage: "folder.fill.badge.person.crop")
                        }
                    }
                }
                Section {
                    if let connections = status.connections {
                        if connections.isEmpty {
                            Text("当前没有客户端连接").foregroundStyle(Theme.secondaryText)
                        }
                        ForEach(connections) { connectionRow($0) }
                    } else {
                        Text("无法读取客户端列表：\(status.connectionError ?? "未知错误")。需要管理员账号；该接口按 Drive 管理控制台推断，尚未在真机验证。")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                } header: {
                    Text("已连接的客户端")
                }
                Section("接口支持") {
                    ForEach(status.apis, id: \.name) { api in
                        InfoRow(label: api.name.replacingOccurrences(of: "SYNO.SynologyDrive", with: "Drive"),
                                value: "v\(api.maxVersion)")
                    }
                }
            }
        }
        .overlay { if status == nil { ProgressView() } }
        .navigationTitle("Drive 状态")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func connectionRow(_ c: DriveConnection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(c.device ?? c.user ?? "未知设备").font(.subheadline.weight(.medium))
                Spacer()
                if let client = c.client { StatusChip(text: client, color: Theme.accent) }
            }
            Text([c.user, c.address, c.version.map { "v\($0)" }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            if let seen = c.lastSeen {
                Text(seen.formatted(date: .numeric, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        guard let client = session.client else { return }
        status = await client.driveServerStatus()
    }
}
