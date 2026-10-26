import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import DSMKit

struct FolderRoute: Hashable {
    let path: String
    let name: String
}

/// Entry point of the file module: the shared folders the account can see.
struct FilesRootView: View {
    @Environment(SessionManager.self) private var session
    @State private var shares: [RemoteFile] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Section { Text(error).foregroundStyle(Theme.warning) }
            }
            Section("共享文件夹") {
                ForEach(shares) { share in
                    NavigationLink(value: FolderRoute(path: share.path, name: share.name)) {
                        FileRow(file: share)
                    }
                }
            }
        }
        .overlay {
            if !loaded {
                ProgressView()
            } else if shares.isEmpty && error == nil {
                ContentUnavailableView("没有可访问的共享文件夹", systemImage: "folder")
            }
        }
        .navigationTitle("文件")
        .navigationDestination(for: FolderRoute.self) { FolderView(route: $0) }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            shares = try await client.listSharedFolders()
            error = nil
        } catch {
            self.error = error.userMessage
        }
        loaded = true
    }
}

struct FileRow: View {
    let file: RemoteFile

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(kind: file.kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
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
        if !file.isDirectory, let size = file.size { parts.append(Format.bytes(size)) }
        if let date = file.modified { parts.append(date.formatted(date: .numeric, time: .shortened)) }
        return parts.joined(separator: " · ")
    }
}

struct FileIcon: View {
    let kind: FileKind

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var symbol: String {
        switch kind {
        case .folder: return "folder.fill"
        case .audio: return "music.note"
        case .video: return "film.fill"
        case .image: return "photo.fill"
        case .text: return "doc.text.fill"
        case .archive: return "doc.zipper"
        case .other: return "doc.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .folder: return Color(hex: 0xF59E0B)
        case .audio: return Color(hex: 0x22C55E)
        case .video: return Color(hex: 0xEF4444)
        case .image: return Color(hex: 0xEC4899)
        case .text: return Color(hex: 0x2563EB)
        case .archive: return Color(hex: 0x8B5CF6)
        case .other: return Color(hex: 0x64748B)
        }
    }
}

/// Items handed to the system share sheet (downloaded files, share links).
struct ExportItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A photo or video from the library, copied to a temporary file that keeps its original name.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedFile(url: target)
        }
    }
}

private struct TransferRequest: Identifiable {
    let id = UUID()
    let paths: [String]
    let move: Bool
}

struct FolderView: View {
    let route: FolderRoute

    @Environment(SessionManager.self) private var session
    @State private var files: [RemoteFile] = []
    @State private var loaded = false
    @State private var loadError: String?
    @State private var sort: FileSort = .name
    @State private var ascending = true
    @State private var search = ""

    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()

    @State private var preview: RemoteFile?
    @State private var export: ExportItem?
    @State private var shareTarget: RemoteFile?
    @State private var transfer: TransferRequest?
    @State private var pendingDelete: [RemoteFile]?

    @State private var renameTarget: RemoteFile?
    @State private var creatingFolder = false
    @State private var compressPaths: [String]?
    @State private var nameInput = ""

    @State private var importing = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pickingPhotos = false

    @State private var busy: String?
    @State private var alert: String?

    private var visibleFiles: [RemoteFile] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var selectedFiles: [RemoteFile] { files.filter { selection.contains($0.id) } }

    var body: some View {
        List(selection: $selection) {
            if let loadError {
                Text(loadError).foregroundStyle(Theme.warning)
            }
            ForEach(visibleFiles) { file in
                row(for: file)
                    .contextMenu { menu(for: [file]) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = [file] } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button { beginRename(file) } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
            }
        }
        .environment(\.editMode, $editMode)
        .overlay {
            if !loaded {
                ProgressView()
            } else if files.isEmpty && loadError == nil {
                ContentUnavailableView("空文件夹", systemImage: "folder")
            } else if visibleFiles.isEmpty && !search.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .overlay(alignment: .bottom) { busyBanner }
        .searchable(text: $search, prompt: "在此文件夹中搜索")
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: sort) { Task { await load() } }
        .onChange(of: ascending) { Task { await load() } }
        .sheet(item: $preview) { FilePreviewView(file: $0) }
        .sheet(item: $export) { ActivityView(items: $0.items) }
        .sheet(item: $shareTarget) { ShareCreateSheet(name: $0.name, path: $0.path) }
        .sheet(item: $transfer) { request in
            FolderPickerSheet(title: request.move ? "移动到" : "复制到") { destination in
                run(request.move ? "正在移动…" : "正在复制…") { client in
                    try await client.copy(request.paths, to: destination, move: request.move)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { upload(urls, scoped: true) }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, matching: .any(of: [.images, .videos]),
                      preferredItemEncoding: .current)
        .onChange(of: photoItems) { uploadPhotos() }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                let paths = pendingDelete?.map(\.path) ?? []
                pendingDelete = nil
                run("正在删除…") { try await $0.delete(paths) }
            }
        } message: {
            Text("如果共享文件夹开启了回收站，可在回收站中找回。")
        }
        .alert("重命名", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("名称", text: $nameInput)
            Button("取消", role: .cancel) {}
            Button("确定") {
                guard let target = renameTarget else { return }
                let name = nameInput.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name != target.name else { return }
                run("正在重命名…") { try await $0.rename(target.path, to: name) }
            }
        }
        .alert("新建文件夹", isPresented: $creatingFolder) {
            TextField("文件夹名称", text: $nameInput)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let name = nameInput.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                run("正在创建…") { try await $0.createFolder(in: route.path, name: name) }
            }
        }
        .alert("压缩为 ZIP", isPresented: Binding(get: { compressPaths != nil }, set: { if !$0 { compressPaths = nil } })) {
            TextField("压缩包名称", text: $nameInput)
            Button("取消", role: .cancel) {}
            Button("压缩") {
                guard let paths = compressPaths else { return }
                var name = nameInput.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                if !name.lowercased().hasSuffix(".zip") { name += ".zip" }
                let target = "\(route.path)/\(name)"
                run("正在压缩…") { try await $0.compress(paths, into: target) }
            }
        }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    // MARK: Rows and menus

    @ViewBuilder
    private func row(for file: RemoteFile) -> some View {
        if file.isDirectory {
            NavigationLink(value: FolderRoute(path: file.path, name: file.name)) { FileRow(file: file) }
        } else {
            Button {
                guard editMode == .inactive else { return }
                RecentStore.shared.record(file, device: session.deviceID)
                preview = file
            } label: { FileRow(file: file) }
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func menu(for targets: [RemoteFile]) -> some View {
        let paths = targets.map(\.path)
        if targets.count == 1, let file = targets.first {
            if !file.isDirectory {
                Button { preview = file } label: { Label("打开", systemImage: "eye") }
                Button { download(file) } label: { Label("下载到手机", systemImage: "arrow.down.circle") }
            }
            Button { shareTarget = file } label: { Label("分享链接", systemImage: "link") }
            Button { beginRename(file) } label: { Label("重命名", systemImage: "pencil") }
            if file.kind == .archive {
                Button {
                    run("正在解压…") { try await $0.extract(file.path, to: route.path) }
                } label: { Label("解压到当前文件夹", systemImage: "archivebox") }
            }
        }
        Button { transfer = TransferRequest(paths: paths, move: false) } label: { Label("复制到…", systemImage: "doc.on.doc") }
        Button { transfer = TransferRequest(paths: paths, move: true) } label: { Label("移动到…", systemImage: "folder") }
        Button {
            nameInput = targets.count == 1 ? ((targets[0].name as NSString).deletingPathExtension) : route.name
            compressPaths = paths
        } label: { Label("压缩", systemImage: "doc.zipper") }
        Divider()
        Button(role: .destructive) { pendingDelete = targets } label: { Label("删除", systemImage: "trash") }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if editMode == .active {
                Button("完成") {
                    editMode = .inactive
                    selection.removeAll()
                }
            } else {
                Menu {
                    Button { importing = true } label: { Label("上传文件", systemImage: "doc.badge.plus") }
                    Button { pickingPhotos = true } label: { Label("上传照片和视频", systemImage: "photo.badge.plus") }
                    Button {
                        nameInput = ""
                        creatingFolder = true
                    } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "plus.circle")
                }
                Menu {
                    Picker("排序", selection: $sort) {
                        ForEach(FileSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("顺序", selection: $ascending) {
                        Text("升序").tag(true)
                        Text("降序").tag(false)
                    }
                    Divider()
                    Button { editMode = .active } label: { Label("选择", systemImage: "checkmark.circle") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        if editMode == .active {
            ToolbarItemGroup(placement: .bottomBar) {
                let targets = selectedFiles
                Button { transfer = TransferRequest(paths: targets.map(\.path), move: false) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(targets.isEmpty)
                Spacer()
                Button { transfer = TransferRequest(paths: targets.map(\.path), move: true) } label: {
                    Image(systemName: "folder")
                }
                .disabled(targets.isEmpty)
                Spacer()
                Button {
                    nameInput = route.name
                    compressPaths = targets.map(\.path)
                } label: { Image(systemName: "doc.zipper") }
                .disabled(targets.isEmpty)
                Spacer()
                Button(role: .destructive) { pendingDelete = targets } label: { Image(systemName: "trash") }
                    .disabled(targets.isEmpty)
            }
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

    private var deleteTitle: String {
        guard let items = pendingDelete else { return "" }
        return items.count == 1 ? "删除「\(items[0].name)」？" : "删除选中的 \(items.count) 项？"
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    // MARK: Actions

    private func load() async {
        guard let client = session.client else { return }
        do {
            files = try await client.listFolder(route.path, sort: sort, ascending: ascending).files
            loadError = nil
        } catch {
            loadError = error.userMessage
        }
        loaded = true
    }

    private func beginRename(_ file: RemoteFile) {
        nameInput = file.name
        renameTarget = file
    }

    /// Runs a change on the NAS with a progress banner, then reloads the folder.
    private func run(_ label: String, _ work: @escaping (DSMClient) async throws -> Void) {
        guard let client = session.client else { return }
        busy = label
        Task {
            do {
                try await work(client)
            } catch {
                alert = error.userMessage
            }
            busy = nil
            editMode = .inactive
            selection.removeAll()
            await load()
        }
    }

    private func download(_ file: RemoteFile) {
        guard let client = session.client else { return }
        busy = "正在下载 \(file.name)…"
        let transfer = TransferCenter.shared.begin(file.name, .download, device: session.deviceID)
        Task {
            do {
                let local = try await client.downloadFile(at: file.path)
                TransferCenter.shared.finish(transfer)
                export = ExportItem(items: [local])
            } catch {
                TransferCenter.shared.finish(transfer, error: error)
                alert = error.userMessage
            }
            busy = nil
        }
    }

    private func upload(_ urls: [URL], scoped: Bool) {
        guard let client = session.client, !urls.isEmpty else { return }
        let folder = route.path
        let device = session.deviceID
        let transfers = urls.map { TransferCenter.shared.begin($0.lastPathComponent, .upload, device: device) }
        Task {
            var failed: [String] = []
            for (index, url) in urls.enumerated() {
                busy = "正在上传 \(index + 1)/\(urls.count)：\(url.lastPathComponent)"
                let access = scoped && url.startAccessingSecurityScopedResource()
                do {
                    try await client.upload(fileAt: url, to: folder)
                    TransferCenter.shared.finish(transfers[index])
                } catch {
                    TransferCenter.shared.finish(transfers[index], error: error)
                    failed.append("\(url.lastPathComponent)：\(error.userMessage)")
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
        let items = photoItems
        guard !items.isEmpty else { return }
        photoItems = []
        busy = "正在读取照片…"
        Task {
            var urls: [URL] = []
            for item in items {
                if let picked = try? await item.loadTransferable(type: PickedFile.self) { urls.append(picked.url) }
            }
            busy = nil
            if urls.count < items.count { alert = "有 \(items.count - urls.count) 项无法读取（可能仍在 iCloud 中下载）。" }
            upload(urls, scoped: false)
        }
    }
}

/// Lets the user pick a destination folder on the NAS (for copy and move).
struct FolderPickerSheet: View {
    let title: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionManager.self) private var session
    @State private var shares: [RemoteFile] = []

    var body: some View {
        NavigationStack {
            List(shares) { share in
                NavigationLink(value: FolderRoute(path: share.path, name: share.name)) { FileRow(file: share) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FolderRoute.self) { route in
                PickerFolderList(route: route) { path in
                    dismiss()
                    onPick(path)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .task {
                guard let client = session.client else { return }
                shares = (try? await client.listSharedFolders()) ?? []
            }
        }
    }
}

private struct PickerFolderList: View {
    let route: FolderRoute
    let onPick: (String) -> Void
    @Environment(SessionManager.self) private var session
    @State private var folders: [RemoteFile] = []

    var body: some View {
        List(folders) { folder in
            NavigationLink(value: FolderRoute(path: folder.path, name: folder.name)) { FileRow(file: folder) }
        }
        .navigationTitle(route.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("选择此处") { onPick(route.path) } }
        }
        .task {
            guard let client = session.client else { return }
            folders = ((try? await client.listFolder(route.path).files) ?? []).filter(\.isDirectory)
        }
    }
}
