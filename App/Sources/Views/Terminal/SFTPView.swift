import SwiftUI
import UniformTypeIdentifiers
import DSMKit
import DSMSSH

struct SFTPScreen: View {
    var body: some View {
        SSHGate { session in SFTPBrowserView(session: session) }
            .navigationTitle("SFTP")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SFTPBrowserView: View {
    let session: SSHSession

    @State private var browser: SFTPBrowser?
    @State private var path = ""
    @State private var items: [SFTPItem] = []
    @State private var loading = false
    @State private var showHidden = false
    @State private var progress: (label: String, value: Double)?
    @State private var export: ExportItem?
    @State private var importing = false
    @State private var creatingFolder = false
    @State private var renameTarget: SFTPItem?
    @State private var nameInput = ""
    @State private var pendingDelete: SFTPItem?
    @State private var alert: String?

    private var visible: [SFTPItem] { showHidden ? items : items.filter { !$0.name.hasPrefix(".") } }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                            if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.secondaryText) }
                            Button(crumb.name) { Task { await open(crumb.path) } }
                                .font(.caption.monospaced())
                        }
                    }
                }
            }
            Section {
                if path != "/" && !path.isEmpty {
                    Button { Task { await open(parent(of: path)) } } label: {
                        Label("上一级", systemImage: "arrow.turn.left.up")
                    }
                }
                ForEach(visible) { item in row(item) }
            }
        }
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .overlay(alignment: .bottom) {
            if let progress {
                VStack(spacing: 6) {
                    Text(progress.label).font(.caption).lineLimit(1)
                    ProgressView(value: progress.value)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding()
            }
        }
        .refreshable { await open(path) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { importing = true } label: { Label("上传文件", systemImage: "doc.badge.plus") }
                    Button {
                        nameInput = ""
                        creatingFolder = true
                    } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                    Toggle("显示隐藏文件", isOn: $showHidden)
                    Button { Task { await open("/") } } label: { Label("根目录", systemImage: "externaldrive") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { upload(urls) }
        }
        .sheet(item: $export) { ActivityView(items: $0.items) }
        .alert("新建文件夹", isPresented: $creatingFolder) {
            TextField("名称", text: $nameInput)
            Button("取消", role: .cancel) {}
            Button("创建") { change { try await $0.createDirectory(join(path, nameInput)) } }
        }
        .alert("重命名", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("名称", text: $nameInput)
            Button("取消", role: .cancel) {}
            Button("确定") {
                guard let target = renameTarget, !nameInput.isEmpty else { return }
                let newPath = join(parent(of: target.path), nameInput)
                change { try await $0.rename(target.path, to: newPath) }
            }
        }
        .confirmationDialog("删除「\(pendingDelete?.name ?? "")」？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let item = pendingDelete else { return }
                change { try await $0.remove(item) }
            }
        } message: {
            Text("SFTP 删除不经过回收站，无法恢复。文件夹必须为空。")
        }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
        .task {
            do {
                let b = try await session.openSFTP()
                browser = b
                await open(try await b.home())
            } catch {
                alert = error.localizedDescription
            }
        }
        .onDisappear {
            let b = browser
            Task { await b?.close() }
        }
    }

    private var crumbs: [(name: String, path: String)] {
        var out: [(name: String, path: String)] = [("/", "/")]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            out.append((String(part), current))
        }
        return out
    }

    private func parent(of p: String) -> String {
        let parent = (p as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    private func open(_ newPath: String) async {
        guard let browser else { return }
        loading = true
        defer { loading = false }
        do {
            items = try await browser.list(newPath)
            path = newPath
        } catch {
            alert = "无法打开 \(newPath)：\(error.localizedDescription)"
        }
    }

    private func change(_ work: @escaping (SFTPBrowser) async throws -> Void) {
        guard let browser else { return }
        Task {
            do { try await work(browser) } catch { alert = error.localizedDescription }
            await open(path)
        }
    }

    private func subtitle(_ item: SFTPItem) -> String {
        var parts: [String] = []
        if let permissions = item.permissions { parts.append(permissions) }
        if !item.isDirectory, let size = item.size { parts.append(Format.bytes(size)) }
        if let modified = item.modified { parts.append(modified.formatted(date: .numeric, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    private func row(_ item: SFTPItem) -> some View {
        let kind: FileKind = item.isDirectory ? .folder : FileKind.of(name: item.name, isDirectory: false)
        return Button {
            if item.isDirectory || item.isSymlink { Task { await open(item.path) } } else { download(item) }
        } label: {
            HStack(spacing: 12) {
                FileIcon(kind: kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                    Text(subtitle(item))
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .contextMenu { rowMenu(item) }
        .swipeActions {
            Button(role: .destructive) { pendingDelete = item } label: { Label("删除", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func rowMenu(_ item: SFTPItem) -> some View {
        if !item.isDirectory {
            Button { download(item) } label: { Label("下载到手机", systemImage: "arrow.down.circle") }
        }
        Button {
            nameInput = item.name
            renameTarget = item
        } label: { Label("重命名", systemImage: "pencil") }
        Button { UIPasteboard.general.string = item.path } label: { Label("复制路径", systemImage: "doc.on.doc") }
        Button(role: .destructive) { pendingDelete = item } label: { Label("删除", systemImage: "trash") }
    }

    private func download(_ item: SFTPItem) {
        guard let browser else { return }
        Task {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let local = folder.appendingPathComponent(item.name)
            progress = ("下载 \(item.name)", 0)
            do {
                try await browser.download(item.path, to: local) { value in
                    Task { @MainActor in progress = ("下载 \(item.name)", value) }
                }
                export = ExportItem(items: [local])
            } catch {
                alert = error.localizedDescription
            }
            progress = nil
        }
    }

    private func upload(_ urls: [URL]) {
        guard let browser else { return }
        let dir = path
        Task {
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                progress = ("上传 \(url.lastPathComponent)", 0)
                do {
                    try await browser.upload(url, to: join(dir, url.lastPathComponent)) { value in
                        Task { @MainActor in progress = ("上传 \(url.lastPathComponent)", value) }
                    }
                } catch {
                    alert = error.localizedDescription
                }
                if access { url.stopAccessingSecurityScopedResource() }
            }
            progress = nil
            await open(dir)
        }
    }
}
