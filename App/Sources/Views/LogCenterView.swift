import SwiftUI
import DSMKit

/// Log Center plus the current health alerts for the connected NAS.
struct LogCenterView: View {
    @Environment(SessionManager.self) private var session
    @State private var alerts: [HealthAlert]?
    @State private var category: LogCategory = .system
    @State private var level: LogEntry.Level?
    @State private var keyword = ""
    @State private var entries: [LogEntry] = []
    @State private var total = 0
    @State private var counts: (warning: Int?, error: Int?) = (nil, nil)
    @State private var loading = false
    /// Bumped on every reload, so a slow answer for a tab the user already left is dropped.
    @State private var generation = 0
    @State private var error: String?
    @State private var notify = AlertNotifier.isEnabled
    @State private var notifyDenied = false

    var body: some View {
        List {
            alertSection
            Section {
                Picker("类别", selection: $category) {
                    ForEach(LogCategory.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                if let error {
                    Text(error).foregroundStyle(Theme.warning)
                }
                ForEach(entries) { entry in
                    LogRow(entry: entry)
                        .contextMenu {
                            Button { UIPasteboard.general.string = entry.message } label: {
                                Label("复制内容", systemImage: "doc.on.doc")
                            }
                        }
                        .onAppear { if entry == entries.last { Task { await loadMore() } } }
                }
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if entries.isEmpty && error == nil {
                    Text("没有日志").foregroundStyle(Theme.secondaryText)
                }
            } header: {
                HStack {
                    Text("共 \(total) 条")
                    Spacer()
                    if let w = counts.warning { StatusChip(text: "警告 \(w)", color: Theme.warning) }
                    if let e = counts.error { StatusChip(text: "错误 \(e)", color: Theme.danger) }
                }
            }
        }
        .navigationTitle("日志中心")
        .searchable(text: $keyword, prompt: "搜索日志内容")
        .onSubmit(of: .search) { Task { await reload() } }
        .onChange(of: keyword) { if keyword.isEmpty { Task { await reload() } } }
        .onChange(of: category) { Task { await reload() } }
        .onChange(of: level) { Task { await reload() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("级别", selection: $level) {
                        Text("全部级别").tag(LogEntry.Level?.none)
                        ForEach(LogEntry.Level.allCases, id: \.self) { Text($0.label).tag(LogEntry.Level?.some($0)) }
                    }
                } label: {
                    Image(systemName: level == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .task {
            await reload()
            await loadAlerts()
        }
        .refreshable {
            await reload()
            await loadAlerts()
        }
        .alert("通知权限被拒绝", isPresented: $notifyDenied) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请在 设置 › 通知 › NAS 助手 中允许通知。")
        }
    }

    @ViewBuilder
    private var alertSection: some View {
        Section {
            if let alerts {
                if alerts.isEmpty {
                    Label("硬盘、存储空间正常，近 24 小时无错误日志", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.good)
                        .font(.subheadline)
                }
                ForEach(alerts) { alert in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: alert.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(alert.severity == .critical ? Theme.danger : Theme.warning)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(alert.title).font(.subheadline.weight(.medium))
                            Text(alert.detail).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(3)
                        }
                    }
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            Toggle(isOn: Binding(get: { notify }, set: { on in
                Task {
                    let result = await AlertNotifier.setEnabled(on)
                    notify = result
                    notifyDenied = on && !result
                }
            })) {
                Label("后台检查并推送告警", systemImage: "bell.badge")
            }
        } header: {
            Text("当前告警")
        } footer: {
            Text("开启后，系统空闲时会定期检查所有已添加的 NAS（只读），发现硬盘故障、存储空间异常或新的错误日志时通知你。检查频率由 iOS 决定。")
        }
    }

    private func loadAlerts() async {
        guard let client = session.client else { return }
        alerts = await client.scanHealth(since: Date(timeIntervalSinceNow: -24 * 3600))
    }

    private func reload() async {
        generation += 1
        entries = []
        total = 0
        error = nil
        await fetch(offset: 0)
    }

    private func loadMore() async {
        guard !loading, entries.count < total else { return }
        await fetch(offset: entries.count)
    }

    private func fetch(offset: Int) async {
        guard let client = session.client else { return }
        let started = generation
        loading = true
        do {
            let page = try await client.logs(category: category, level: level,
                                             keyword: keyword.trimmingCharacters(in: .whitespaces), offset: offset)
            guard started == generation else { return }
            entries = offset == 0 ? page.entries : entries + page.entries
            total = page.total
            counts = (page.warningCount, page.errorCount)
            error = nil
        } catch is CancellationError {
            // Pull-to-refresh or leaving the screen; not worth an error line.
        } catch {
            guard started == generation else { return }
            self.error = error.userMessage
        }
        if started == generation { loading = false }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.message)
                    .font(.subheadline)
                    .lineLimit(4)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch entry.level {
        case .info: return Theme.accent
        case .warning: return Theme.warning
        case .error: return Theme.danger
        }
    }

    private var caption: String {
        let time = entry.time?.formatted(date: .numeric, time: .standard) ?? entry.rawTime
        return [time, entry.user, entry.level.label].compactMap { $0 }.joined(separator: " · ")
    }
}
