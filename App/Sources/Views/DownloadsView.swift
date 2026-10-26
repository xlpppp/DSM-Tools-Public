import SwiftUI
import UniformTypeIdentifiers
import DSMKit

struct DownloadsView: View {
    enum Filter: String, CaseIterable {
        case all = "全部", active = "进行中", done = "已完成", failed = "出错"
    }

    @Environment(SessionManager.self) private var session
    @State private var tasks: [DownloadTask] = []
    @State private var stats: DownloadStats?
    @State private var loaded = false
    @State private var unavailable = false
    @State private var filter: Filter = .all
    @State private var adding = false
    @State private var importingTorrent = false
    @State private var pendingDelete: DownloadTask?
    @State private var alert: String?

    private var visible: [DownloadTask] {
        switch filter {
        case .all: return tasks
        case .active: return tasks.filter { $0.status.isActive || $0.status == .paused }
        case .done: return tasks.filter(\.status.isDone)
        case .failed: return tasks.filter { $0.status == .error }
        }
    }

    var body: some View {
        List {
            if unavailable {
                ContentUnavailableView("未安装 Download Station", systemImage: "arrow.down.circle",
                                       description: Text("请先在套件中心安装 Download Station。"))
            } else {
                Section {
                    speedHeader
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    Picker("筛选", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    ForEach(visible) { task in
                        DownloadRow(task: task)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { pendingDelete = task } label: { Label("删除", systemImage: "trash") }
                                if task.status == .paused || task.status == .error {
                                    Button { act { try await $0.resumeDownloads([task.id]) } } label: {
                                        Label("继续", systemImage: "play.fill")
                                    }
                                    .tint(Theme.good)
                                } else if task.status.isActive {
                                    Button { act { try await $0.pauseDownloads([task.id]) } } label: {
                                        Label("暂停", systemImage: "pause.fill")
                                    }
                                    .tint(.orange)
                                }
                            }
                            .contextMenu {
                                if let uri = task.uri {
                                    Button { UIPasteboard.general.string = uri } label: { Label("复制下载链接", systemImage: "link") }
                                }
                            }
                    }
                    if loaded && visible.isEmpty {
                        Text("没有任务").foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .navigationTitle("下载")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { adding = true } label: { Label("添加链接", systemImage: "link.badge.plus") }
                    Button { importingTorrent = true } label: { Label("添加种子文件", systemImage: "doc.badge.plus") }
                    Divider()
                    Button {
                        let ids = tasks.filter(\.status.isActive).map(\.id)
                        if !ids.isEmpty { act { try await $0.pauseDownloads(ids) } }
                    } label: { Label("全部暂停", systemImage: "pause.circle") }
                    Button {
                        let ids = tasks.filter { $0.status == .paused }.map(\.id)
                        if !ids.isEmpty { act { try await $0.resumeDownloads(ids) } }
                    } label: { Label("全部继续", systemImage: "play.circle") }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .disabled(unavailable)
            }
        }
        .sheet(isPresented: $adding) {
            AddDownloadSheet { links, destination in
                act { try await $0.addDownloads(links, destination: destination) }
            }
        }
        .fileImporter(isPresented: $importingTorrent,
                      allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data, UTType(filenameExtension: "nzb") ?? .data]) { result in
            guard case .success(let url) = result else { return }
            act { client in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try await client.addDownload(torrentAt: url)
            }
        }
        .confirmationDialog("删除「\(pendingDelete?.title ?? "")」？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除任务，保留已下载文件", role: .destructive) { delete(keepFiles: true) }
            Button("删除任务和未完成的数据", role: .destructive) { delete(keepFiles: false) }
        }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
        .task { await poll() }
    }

    private var speedHeader: some View {
        HStack(spacing: 12) {
            speedTile("下载", value: stats?.downloadSpeed ?? 0, symbol: "arrow.down", color: Theme.accent)
            speedTile("上传", value: stats?.uploadSpeed ?? 0, symbol: "arrow.up", color: Theme.good)
        }
        .padding(.bottom, 8)
    }

    private func speedTile(_ title: String, value: Int, symbol: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(color.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(Theme.secondaryText)
                Text(Format.rate(value)).font(.headline.monospacedDigit())
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
    }

    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func refresh() async {
        guard let client = session.client else { return }
        guard await client.hasDownloadStation else {
            unavailable = true
            loaded = true
            return
        }
        do {
            tasks = try await client.downloadTasks()
            stats = try? await client.downloadStats()
        } catch {
            if !loaded { alert = error.userMessage }
        }
        loaded = true
    }

    private func act(_ work: @escaping (DSMClient) async throws -> Void) {
        guard let client = session.client else { return }
        Task {
            do { try await work(client) } catch { alert = error.userMessage }
            await refresh()
        }
    }

    private func delete(keepFiles: Bool) {
        guard let task = pendingDelete else { return }
        pendingDelete = nil
        act { try await $0.deleteDownloads([task.id], keepFiles: keepFiles) }
    }
}

private struct DownloadRow: View {
    let task: DownloadTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(task.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer()
                Text(task.status.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }
            ProgressView(value: task.progress)
                .tint(statusColor)
            HStack {
                Text("\(Format.bytes(task.downloaded)) / \(Format.bytes(task.size))")
                Spacer()
                if task.status == .downloading {
                    Text("↓ \(Format.rate(task.downloadSpeed))")
                    if let remaining = task.remaining {
                        Text("剩余 \(Duration.seconds(remaining).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))")
                    }
                } else if task.status == .seeding {
                    Text("↑ \(Format.rate(task.uploadSpeed))")
                } else if task.status == .error, let detail = task.errorDetail {
                    Text(detail).foregroundStyle(Theme.danger)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch task.status {
        case .error: return Theme.danger
        case .paused: return Theme.secondaryText
        case .finished, .seeding: return Theme.good
        default: return Theme.accent
        }
    }
}

private struct AddDownloadSheet: View {
    let onAdd: ([String], String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var destination: String?
    @State private var choosingFolder = false

    private var links: [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        if let s = UIPasteboard.general.string { text = text.isEmpty ? s : text + "\n" + s }
                    } label: { Label("从剪贴板粘贴", systemImage: "doc.on.clipboard") }
                } header: {
                    Text("下载链接")
                } footer: {
                    Text("每行一个，支持 HTTP/HTTPS、FTP、磁力链接、ed2k。")
                }
                Section("保存位置") {
                    Button {
                        choosingFolder = true
                    } label: {
                        HStack {
                            Text(destination ?? "Download Station 默认位置")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
            .navigationTitle("添加下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        onAdd(links, destination)
                        dismiss()
                    }
                    .disabled(links.isEmpty)
                }
            }
            .sheet(isPresented: $choosingFolder) {
                FolderPickerSheet(title: "保存到") { destination = $0 }
            }
        }
    }
}
