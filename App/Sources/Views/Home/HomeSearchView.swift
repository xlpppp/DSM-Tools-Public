import SwiftUI
import DSMKit

/// Home search: features by name, recently viewed files, and file names across the NAS's shared folders.
struct HomeSearchView: View {
    @Environment(SessionManager.self) private var session
    @State private var query = ""
    @State private var results: [RemoteFile]?
    @State private var searching = false
    @State private var error: String?
    @State private var preview: RemoteFile?
    @State private var searchTask: Task<Void, Never>?

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var modules: [Module] {
        guard !trimmed.isEmpty else { return [] }
        return Module.allCases.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    private var recents: [RecentStore.RecentFile] {
        let all = RecentStore.shared.files(for: session.deviceID)
        guard !trimmed.isEmpty else { return Array(all.prefix(8)) }
        return all.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        List {
            if !modules.isEmpty {
                Section("功能") {
                    ForEach(modules) { module in
                        NavigationLink(value: module) {
                            Label {
                                Text(module.title)
                            } icon: {
                                Image(systemName: module.symbol).foregroundStyle(module.color)
                            }
                        }
                    }
                }
            }
            if !recents.isEmpty {
                Section(trimmed.isEmpty ? "最近查看" : "最近查看中的匹配") {
                    ForEach(recents) { recent in
                        Button { open(recent.remote) } label: { FileRow(file: recent.remote) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if !trimmed.isEmpty {
                Section {
                    if searching {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在 NAS 中搜索…").foregroundStyle(Theme.secondaryText)
                        }
                    } else if let error {
                        Text(error).foregroundStyle(Theme.warning)
                    } else if let results {
                        if results.isEmpty {
                            Text("没有找到文件").foregroundStyle(Theme.secondaryText)
                        }
                        ForEach(results) { file in
                            if file.isDirectory {
                                NavigationLink {
                                    FolderView(route: FolderRoute(path: file.path, name: file.name))
                                } label: {
                                    FileRow(file: file)
                                }
                            } else {
                                Button { open(file) } label: { FileRow(file: file) }
                                    .buttonStyle(.plain)
                            }
                        }
                    } else {
                        Button("在 NAS 中搜索“\(trimmed)”") { runSearch() }
                    }
                } header: {
                    Text("NAS 文件")
                } footer: {
                    if let results, results.count >= 200 { Text("只显示前 200 条结果，请输入更具体的关键词。") }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索功能或文件名")
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: query) {
            searchTask?.cancel()
            searching = false
            results = nil
            error = nil
        }
        .onDisappear { searchTask?.cancel() }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $preview) { FilePreviewView(file: $0) }
    }

    private func open(_ file: RemoteFile) {
        RecentStore.shared.record(file, device: session.deviceID)
        preview = file
    }

    private func runSearch() {
        let keyword = trimmed
        guard let client = session.client, !keyword.isEmpty else { return }
        searchTask?.cancel()
        searching = true
        error = nil
        searchTask = Task {
            do {
                let shares = try await client.listSharedFolders().map(\.path)
                let found = try await client.searchFiles(keyword, in: shares)
                guard !Task.isCancelled else { return }
                results = found
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.userMessage
            }
            searching = false
        }
    }
}
