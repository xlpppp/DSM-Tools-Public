import SwiftUI
import DSMKit

/// Cloud Sync connections with their state; pause/resume per connection or for all.
/// Creating connections stays on the NAS (it needs the provider's OAuth page).
struct CloudSyncView: View {
    @Environment(SessionManager.self) private var session
    @State private var overview: CloudSyncOverview?
    @State private var loaded = false
    @State private var unavailable = false
    @State private var alert: String?

    private var connections: [CloudSyncConnection] { overview?.connections ?? [] }

    var body: some View {
        List {
            if unavailable {
                ContentUnavailableView("未安装 Cloud Sync", systemImage: "icloud.slash",
                                       description: Text("请先在套件中心安装 Cloud Sync。"))
            } else {
                Section {
                    summary
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    ForEach(connections) { conn in
                        NavigationLink { CloudSyncConnectionView(connection: conn) } label: {
                            CloudSyncConnectionRow(connection: conn)
                        }
                        .swipeActions(edge: .trailing) {
                            if conn.status == .paused {
                                Button { act { try await $0.resumeCloudSync(connection: conn.id) } } label: {
                                    Label("继续", systemImage: "play.fill")
                                }
                                .tint(Theme.good)
                            } else if conn.linked {
                                Button { act { try await $0.pauseCloudSync(connection: conn.id) } } label: {
                                    Label("暂停", systemImage: "pause.fill")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                    if loaded && connections.isEmpty {
                        Text("没有云端连接，请在 NAS 的 Cloud Sync 中添加。").foregroundStyle(Theme.secondaryText)
                    }
                } header: {
                    Text("连接")
                }
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .navigationTitle("Cloud Sync")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let overview, !connections.isEmpty {
                    Button {
                        let resume = overview.isPaused
                        act { client in
                            if resume { try await client.resumeCloudSync() } else { try await client.pauseCloudSync() }
                        }
                    } label: {
                        Image(systemName: overview.isPaused ? "play.circle" : "pause.circle")
                    }
                    .accessibilityLabel(overview.isPaused ? "全部继续" : "全部暂停")
                }
            }
        }
        .refreshable { await refresh() }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
        .task { await poll() }
    }

    private var summary: some View {
        let syncing = connections.filter { $0.status == .syncing || $0.status == .preparing }.count
        let problems = connections.filter { $0.status == .error || $0.status == .unlinked }.count
        let pending = connections.reduce(0) { $0 + $1.unfinishedFiles }
        return HStack(spacing: 12) {
            summaryTile("连接", value: "\(connections.count)", symbol: "link", color: Theme.accent)
            summaryTile(overview?.isPaused == true ? "已全部暂停" : "同步中", value: "\(syncing)",
                        symbol: overview?.isPaused == true ? "pause.fill" : "arrow.triangle.2.circlepath",
                        color: overview?.isPaused == true ? Theme.secondaryText : Theme.good)
            summaryTile(problems > 0 ? "异常" : "待同步", value: problems > 0 ? "\(problems)" : "\(pending)",
                        symbol: problems > 0 ? "exclamationmark.triangle.fill" : "clock",
                        color: problems > 0 ? Theme.danger : Theme.memory)
        }
        .padding(.bottom, 8)
    }

    private func summaryTile(_ title: String, value: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color.gradient, in: Circle())
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }

    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func refresh() async {
        guard let client = session.client else { return }
        guard await client.hasCloudSync else {
            unavailable = true
            loaded = true
            return
        }
        do {
            overview = try await client.cloudSyncOverview()
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
}

extension CloudSyncStatus {
    var color: Color {
        switch self {
        case .uptodate: return Theme.good
        case .syncing, .preparing: return Theme.accent
        case .paused, .unknown: return Theme.secondaryText
        case .error, .unlinked: return Theme.danger
        }
    }

    var symbol: String {
        switch self {
        case .uptodate: return "checkmark.icloud.fill"
        case .syncing, .preparing: return "arrow.triangle.2.circlepath.icloud.fill"
        case .paused: return "pause.circle.fill"
        case .error, .unlinked: return "exclamationmark.icloud.fill"
        case .unknown: return "icloud.fill"
        }
    }
}

private struct CloudSyncConnectionRow: View {
    let connection: CloudSyncConnection

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: connection.status.symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(connection.status.color.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.name).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(connection.provider)
                    if let user = connection.userName, !user.isEmpty { Text("· \(user)") }
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                StatusChip(text: connection.status.label, color: connection.status.color)
                if connection.unfinishedFiles > 0 {
                    Text("剩余 \(connection.unfinishedFiles) 个文件")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Tasks and recent log of one connection.
struct CloudSyncConnectionView: View {
    let connection: CloudSyncConnection

    enum Pane: String, CaseIterable { case tasks = "同步任务", logs = "最近日志" }
    enum LevelFilter: String, CaseIterable { case all = "全部", warning = "警告", error = "错误" }

    @Environment(SessionManager.self) private var session
    @State private var tab: Pane = .tasks
    @State private var tasks: [CloudSyncTask] = []
    @State private var logs: [CloudSyncLogEntry] = []
    @State private var level: LevelFilter = .all
    @State private var loading = true
    @State private var error: String?
    @State private var paused: Bool
    @State private var alert: String?

    init(connection: CloudSyncConnection) {
        self.connection = connection
        _paused = State(initialValue: connection.status == .paused)
    }

    private var visibleLogs: [CloudSyncLogEntry] {
        switch level {
        case .all: return logs
        case .warning: return logs.filter { $0.level == .warning }
        case .error: return logs.filter { $0.level == .error }
        }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("云服务", value: connection.provider)
                if let user = connection.userName, !user.isEmpty { LabeledContent("账号", value: user) }
                LabeledContent("状态") { StatusChip(text: paused ? CloudSyncStatus.paused.label : connection.status.label,
                                                  color: paused ? CloudSyncStatus.paused.color : connection.status.color) }
                if !connection.linked {
                    Text("授权已失效，请在 NAS 的 Cloud Sync 中重新登录该云端账号。")
                        .font(.caption).foregroundStyle(Theme.danger)
                }
            }
            Section {
                Picker("视图", selection: $tab) {
                    ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let error {
                Section { Text(error).foregroundStyle(Theme.warning) }
            }
            switch tab {
            case .tasks: taskSection
            case .logs: logSection
            }
        }
        .navigationTitle(connection.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if connection.linked {
                    Button { togglePause() } label: {
                        Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
                    }
                }
            }
        }
        .refreshable { await load() }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
        .task { await load() }
    }

    @ViewBuilder private var taskSection: some View {
        Section {
            ForEach(tasks) { task in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(task.direction.label, systemImage: directionSymbol(task.direction))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                        Spacer()
                        StatusChip(text: task.status.label, color: task.status.color)
                    }
                    pathLine("internaldrive", task.localPath)
                    pathLine("cloud", task.remotePath)
                    if let desc = task.errorDescription {
                        Text(desc).font(.caption).foregroundStyle(Theme.danger)
                    }
                }
                .padding(.vertical, 4)
            }
            if !loading && tasks.isEmpty && error == nil {
                Text("没有同步任务").foregroundStyle(Theme.secondaryText)
            }
            if loading && tasks.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
    }

    @ViewBuilder private var logSection: some View {
        Section {
            ForEach(visibleLogs) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(color(entry.level)).frame(width: 8, height: 8).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.actionLabel).font(.caption.weight(.medium))
                            Spacer()
                            Text(entry.time.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Text(entry.fileName).font(.subheadline).lineLimit(2)
                        Text(entry.path).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
                        if entry.errorCode != 0 {
                            Text("错误码 \(entry.errorCode)").font(.caption2).foregroundStyle(Theme.danger)
                        }
                    }
                }
                .contextMenu {
                    Button { UIPasteboard.general.string = entry.path } label: { Label("复制路径", systemImage: "doc.on.doc") }
                }
            }
            if !loading && visibleLogs.isEmpty && error == nil {
                Text("没有日志").foregroundStyle(Theme.secondaryText)
            }
        } header: {
            Picker("级别", selection: $level) {
                ForEach(LevelFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .textCase(nil)
        }
    }

    private func pathLine(_ symbol: String, _ path: String) -> some View {
        Label(path.isEmpty ? "—" : path, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func directionSymbol(_ d: CloudSyncTask.Direction) -> String {
        switch d {
        case .both: return "arrow.up.arrow.down"
        case .uploadOnly: return "arrow.up"
        case .downloadOnly: return "arrow.down"
        case .unknown: return "questionmark"
        }
    }

    private func color(_ level: CloudSyncLogEntry.Level) -> Color {
        switch level {
        case .info: return Theme.good
        case .warning: return Theme.warning
        case .error: return Theme.danger
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        loading = true
        defer { loading = false }
        do {
            async let t = client.cloudSyncTasks(connection: connection.id)
            async let l = client.cloudSyncLogs(connection: connection.id)
            tasks = try await t
            logs = (try? await l) ?? []
            error = nil
        } catch {
            self.error = error.userMessage
        }
    }

    private func togglePause() {
        guard let client = session.client else { return }
        let resume = paused
        Task {
            do {
                if resume { try await client.resumeCloudSync(connection: connection.id) }
                else { try await client.pauseCloudSync(connection: connection.id) }
                paused = !resume
            } catch {
                alert = error.userMessage
            }
            await load()
        }
    }
}
