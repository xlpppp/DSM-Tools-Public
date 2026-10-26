import SwiftUI
import Combine
import DSMKit

/// "系统" module: device info plus DSM control-panel style management.
struct SystemHubView: View {
    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var gate = AdminGate.shared
    @State private var confirmLogout = false
    @AppStorage(AppSettings.Key.homeShowRecentPhotos) private var showRecentPhotos = AppSettings.defaultHomeShowRecentPhotos
    @AppStorage(AppSettings.Key.homeShowRecentFiles) private var showRecentFiles = AppSettings.defaultHomeShowRecentFiles

    var body: some View {
        List {
            Section {
                hubLink("设备信息与电源", "info.circle.fill", 0x64748B) { DeviceInfoView() }
            }
            Section {
                hubLink("网络", "network", 0x14B8A6) { NetworkView() }
                hubLink("套件中心", "shippingbox.fill", 0x6366F1) { PackagesView() }
            }
            Section {
                if gate.isUnlocked {
                    hubLink("用户与群组", "person.2.fill", 0x2563EB) { UsersView() }
                    hubLink("当前连接", "point.3.connected.trianglepath.dotted", 0x0EA5E9) { ConnectionsView() }
                    hubLink("文件服务", "server.rack", 0xF59E0B) { FileServicesView() }
                    hubLink("任务计划", "calendar.badge.clock", 0x8B5CF6) { TaskSchedulerView() }
                    hubLink("开关机计划", "power.circle.fill", 0x16A34A) { PowerScheduleView() }
                } else {
                    Button { Task { _ = await gate.unlock() } } label: {
                        Label("验证身份以解锁管理功能", systemImage: "lock.fill")
                    }
                }
            } header: {
                Text("管理功能")
            } footer: {
                Text("用户、连接、文件服务、任务计划、开关机计划需验证面容 ID / 触控 ID / 锁屏密码，解锁 5 分钟内有效。")
            }
            Section {
                hubLink("操作审计", "checklist", 0x475569) { AuditLogView() }
            } footer: {
                Text("记录本机对 NAS 做过的所有更改，密码等敏感参数已脱敏，只保存在本机。")
            }
            Section {
                hubLink("分享设置", "link", 0x0EA5E9) { ShareSettingsView() }
            } footer: {
                Text("新建分享链接的默认有效期和访问次数，查看或取消已分享的链接。")
            }
            Section {
                Toggle("最近浏览的照片", isOn: $showRecentPhotos)
                Toggle("最近浏览的文件", isOn: $showRecentFiles)
            } header: {
                Text("首页展示")
            } footer: {
                Text("关闭后首页不再显示对应区块。只保存在本机。")
            }
            Section {
                Button(role: .destructive) { confirmLogout = true } label: {
                    Text("退出登录").frame(maxWidth: .infinity)
                }
                .disabled(session.client == nil)
            }
        }
        .navigationTitle("系统")
        .confirmationDialog("退出当前 NAS 的登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                gate.lock()
                session.logOut()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机保存的密码会保留，回到首页点「重试」即可重新登录。")
        }
    }

    private func hubLink<D: View>(_ title: String, _ symbol: String, _ color: UInt32,
                                  @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color(hex: color).gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
            }
        }
    }
}

// MARK: Shared helpers

private struct LoadState: ViewModifier {
    let loaded: Bool
    let error: String?
    func body(content: Content) -> some View {
        content.overlay {
            if !loaded { ProgressView() }
        }
    }
}

private extension View {
    func failureAlert(_ message: Binding<String?>) -> some View {
        alert("操作失败", isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

// MARK: Users

struct UsersView: View {
    enum Tab: String, CaseIterable { case users = "用户", groups = "群组" }

    @Environment(SessionManager.self) private var session
    @State private var tab: Tab = .users
    @State private var users: [NASUser] = []
    @State private var groups: [NASGroup] = []
    @State private var loaded = false
    @State private var adding = false
    @State private var pending: (user: NASUser, action: String)?
    @State private var alert: String?

    var body: some View {
        List {
            Section {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if tab == .users {
                Section {
                    ForEach(users) { user in
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(user.isDisabled ? Theme.secondaryText : Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name).font(.subheadline.weight(.medium))
                                if let sub = user.description ?? user.email {
                                    Text(sub).font(.caption).foregroundStyle(Theme.secondaryText)
                                }
                            }
                            Spacer()
                            if user.isDisabled { StatusChip(text: "已停用", color: Theme.secondaryText) }
                        }
                        .swipeActions {
                            if !user.isSystem {
                                Button(role: .destructive) { pending = (user, "delete") } label: { Label("删除", systemImage: "trash") }
                            }
                            Button { pending = (user, user.isDisabled ? "enable" : "disable") } label: {
                                Label(user.isDisabled ? "启用" : "停用", systemImage: user.isDisabled ? "person.fill.checkmark" : "person.fill.xmark")
                            }
                            .tint(user.isDisabled ? Theme.good : .orange)
                        }
                    }
                } footer: {
                    Text("左滑可停用、启用或删除用户。权限与配额请在 DSM 网页端设置。")
                }
            } else {
                Section {
                    ForEach(groups) { g in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name).font(.subheadline.weight(.medium))
                            if let d = g.description { Text(d).font(.caption).foregroundStyle(Theme.secondaryText) }
                        }
                    }
                }
            }
        }
        .modifier(LoadState(loaded: loaded, error: alert))
        .navigationTitle("用户与群组")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "person.badge.plus") }
            }
        }
        .sheet(isPresented: $adding) { NewUserSheet { await load() } }
        .confirmationDialog(pendingQuestion, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button(pendingVerb, role: .destructive) { Task { await perform() } }
        } message: {
            Text(pending?.action == "delete" ? "用户的个人文件夹（home）可能一并删除，且无法撤销。" : "停用后该用户会立即被登出，无法再登录。")
        }
        .failureAlert($alert)
        .task { await load() }
        .refreshable { await load() }
    }

    private var pendingVerb: String {
        switch pending?.action { case "delete": return "删除"; case "enable": return "启用"; default: return "停用" }
    }

    private var pendingQuestion: String { "确定要\(pendingVerb)用户 \(pending?.user.name ?? "") 吗？" }

    private func load() async {
        guard let client = session.client else { return }
        do {
            users = try await client.users()
            groups = (try? await client.groups()) ?? []
        } catch {
            alert = error.userMessage
        }
        loaded = true
    }

    private func perform() async {
        guard let client = session.client, let pending else { return }
        do {
            switch pending.action {
            case "delete": try await client.deleteUser(pending.user.name)
            case "enable": try await client.setUserDisabled(pending.user.name, false)
            default: try await client.setUserDisabled(pending.user.name, true)
            }
        } catch {
            alert = error.userMessage
        }
        await load()
    }
}

private struct NewUserSheet: View {
    let onDone: () async -> Void
    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var email = ""
    @State private var note = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("用户名", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password).textContentType(.newPassword)
                    SecureField("确认密码", text: $confirm).textContentType(.newPassword)
                }
                Section {
                    TextField("邮箱（可选）", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    TextField("描述（可选）", text: $note)
                } footer: {
                    Text("新用户默认属于 users 群组。共享文件夹权限请在 DSM 网页端分配。")
                }
                if let error { Text(error).foregroundStyle(Theme.warning) }
            }
            .navigationTitle("新增用户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { Task { await save() } }
                        .disabled(saving || name.isEmpty || password.isEmpty || password != confirm)
                }
            }
        }
    }

    private func save() async {
        guard let client = session.client else { return }
        saving = true
        defer { saving = false }
        do {
            try await client.createUser(name: name.trimmingCharacters(in: .whitespaces), password: password,
                                        description: note, email: email)
            await onDone()
            dismiss()
        } catch {
            self.error = error.userMessage
        }
    }
}

// MARK: Connections

struct ConnectionsView: View {
    @Environment(SessionManager.self) private var session
    @State private var items: [NASConnection] = []
    @State private var loaded = false
    @State private var kicking: NASConnection?
    @State private var alert: String?

    var body: some View {
        List {
            Section {
                ForEach(items) { c in
                    HStack(spacing: 12) {
                        Image(systemName: icon(c.type)).foregroundStyle(Theme.accent).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.who).font(.subheadline.weight(.medium))
                            Text("\(c.type) · \(c.from)").font(.caption).foregroundStyle(Theme.secondaryText)
                            if let d = c.description { Text(d).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1) }
                        }
                        Spacer()
                        Text(c.time).font(.caption2).foregroundStyle(Theme.secondaryText)
                    }
                    .swipeActions {
                        if c.canKick {
                            Button(role: .destructive) { kicking = c } label: { Label("断开", systemImage: "xmark.circle") }
                        }
                    }
                }
                if loaded && items.isEmpty { Text("没有连接").foregroundStyle(Theme.secondaryText) }
            } header: {
                Text("共 \(items.count) 个连接")
            } footer: {
                Text("左滑可断开连接。断开自己的网页会话不会影响本 App。")
            }
        }
        .modifier(LoadState(loaded: loaded, error: alert))
        .navigationTitle("当前连接")
        .confirmationDialog("断开 \(kicking?.who ?? "") 的连接？", isPresented: Binding(get: { kicking != nil }, set: { if !$0 { kicking = nil } }),
                            titleVisibility: .visible) {
            Button("断开", role: .destructive) { Task { await kick() } }
        } message: {
            Text("来自 \(kicking?.from ?? "") 的 \(kicking?.type ?? "") 会话会立即断开，未保存的传输可能中断。")
        }
        .failureAlert($alert)
        .task { await load() }
        .refreshable { await load() }
    }

    private func icon(_ type: String) -> String {
        let t = type.uppercased()
        if t.contains("SMB") || t.contains("CIFS") || t.contains("AFP") { return "externaldrive.connected.to.line.below" }
        if t.contains("FTP") { return "arrow.up.arrow.down" }
        if t.contains("SSH") || t.contains("TELNET") { return "terminal" }
        return "globe"
    }

    private func load() async {
        guard let client = session.client else { return }
        do { items = try await client.connections() } catch { alert = error.userMessage }
        loaded = true
    }

    private func kick() async {
        guard let client = session.client, let kicking else { return }
        do { try await client.kick(kicking) } catch { alert = error.userMessage }
        await load()
    }
}

// MARK: Network

struct NetworkView: View {
    @Environment(SessionManager.self) private var session
    @State private var net: NetworkSummary?
    @State private var loaded = false
    @State private var alert: String?

    var body: some View {
        List {
            if let net {
                Section("常规") {
                    InfoRow(label: "主机名", value: net.hostname)
                    InfoRow(label: "默认网关", value: net.gateway)
                    InfoRow(label: "DNS", value: net.dns)
                    if let wg = net.workgroup { InfoRow(label: "工作组", value: wg) }
                    if let ep = session.endpoint { InfoRow(label: "本机正在使用", value: ep.host) }
                }
                ForEach(net.interfaces) { nif in
                    Section(nif.id) {
                        InfoRow(label: "IPv4", value: nif.address.isEmpty ? "未连接" : "\(nif.address) / \(nif.mask)")
                        InfoRow(label: "MAC", value: nif.mac)
                        ForEach(nif.ipv6, id: \.self) { InfoRow(label: "IPv6", value: $0) }
                    }
                }
            }
        }
        .modifier(LoadState(loaded: loaded, error: alert))
        .navigationTitle("网络")
        .failureAlert($alert)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do { net = try await client.network() } catch { alert = error.userMessage }
        loaded = true
    }
}

// MARK: File services

struct FileServicesView: View {
    @Environment(SessionManager.self) private var session
    @State private var states: [FileServiceState] = []
    @State private var loaded = false
    @State private var pending: (service: FileService, enable: Bool)?
    @State private var working: FileService?
    @State private var alert: String?

    var body: some View {
        List {
            Section {
                ForEach(states) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(s.service.title).font(.subheadline.weight(.semibold))
                                if let port = s.port { Text("端口 \(String(port))").font(.caption2).foregroundStyle(Theme.secondaryText) }
                            }
                            Text(s.detail ?? s.service.summary).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        if working == s.service {
                            ProgressView()
                        } else {
                            Toggle("", isOn: Binding(get: { s.enabled }, set: { pending = (s.service, $0) }))
                                .labelsHidden()
                        }
                    }
                }
                if loaded && states.isEmpty { Text("无法读取文件服务设置（需要管理员账号）").foregroundStyle(Theme.secondaryText) }
            } footer: {
                Text("只提供开关。共享权限、端口、加密等详细设置请在 DSM 网页端「控制面板 › 文件服务」修改。")
            }
        }
        .modifier(LoadState(loaded: loaded, error: alert))
        .navigationTitle("文件服务")
        .confirmationDialog(question, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button(pending?.enable == true ? "启用" : "停用", role: pending?.enable == true ? nil : .destructive) {
                Task { await apply() }
            }
        } message: {
            Text(pending?.enable == true
                 ? (pending?.service == .ftp ? "FTP 不加密，账号密码会明文传输，建议只在局域网使用或改用 FTPS/SFTP。" : "启用后局域网内的设备即可通过该协议访问共享文件夹。")
                 : "正在使用该协议的连接会被断开。")
        }
        .failureAlert($alert)
        .task { await load() }
        .refreshable { await load() }
    }

    private var question: String {
        guard let pending else { return "" }
        return "\(pending.enable ? "启用" : "停用") \(pending.service.title)？"
    }

    private func load() async {
        guard let client = session.client else { return }
        do { states = try await client.fileServices() } catch { alert = error.userMessage }
        loaded = true
    }

    private func apply() async {
        guard let client = session.client, let pending else { return }
        working = pending.service
        defer { working = nil }
        do { try await client.setFileService(pending.service, enabled: pending.enable) } catch { alert = error.userMessage }
        await load()
    }
}

// MARK: Task scheduler

struct TaskSchedulerView: View {
    @Environment(SessionManager.self) private var session
    @State private var tasks: [ScheduledTask] = []
    @State private var loaded = false
    @State private var running: ScheduledTask?
    @State private var message: String?
    @State private var alert: String?

    var body: some View {
        List {
            if let message {
                Section { Label(message, systemImage: "checkmark.circle").foregroundStyle(Theme.good) }
            }
            Section {
                ForEach(tasks) { task in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.name).font(.subheadline.weight(.medium))
                            Text("\(task.typeLabel) · \(task.owner)").font(.caption).foregroundStyle(Theme.secondaryText)
                            if let next = task.nextRun, task.enabled {
                                Text("下次运行：\(next)").font(.caption2).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { task.enabled }, set: { v in Task { await setEnabled(task, v) } }))
                            .labelsHidden()
                    }
                    .swipeActions {
                        Button { running = task } label: { Label("运行", systemImage: "play.fill") }.tint(Theme.accent)
                    }
                }
                if loaded && tasks.isEmpty { Text("没有计划任务").foregroundStyle(Theme.secondaryText) }
            } footer: {
                Text("左滑可立即运行。脚本内容和计划请在 DSM 网页端编辑。")
            }
        }
        .modifier(LoadState(loaded: loaded, error: alert))
        .navigationTitle("任务计划")
        .confirmationDialog("立即运行「\(running?.name ?? "")」？", isPresented: Binding(get: { running != nil }, set: { if !$0 { running = nil } }),
                            titleVisibility: .visible) {
            Button("运行") { Task { await run() } }
        } message: {
            Text("任务会以 \(running?.owner ?? "") 身份在 NAS 上执行。")
        }
        .failureAlert($alert)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do { tasks = try await client.scheduledTasks() } catch { alert = error.userMessage }
        loaded = true
    }

    private func run() async {
        guard let client = session.client, let running else { return }
        do {
            try await client.runTask(running)
            message = "已开始运行「\(running.name)」"
        } catch {
            alert = error.userMessage
        }
    }

    private func setEnabled(_ task: ScheduledTask, _ enabled: Bool) async {
        guard let client = session.client else { return }
        do { try await client.setTaskEnabled(task, enabled) } catch { alert = error.userMessage }
        await load()
    }
}

// MARK: Audit log

struct AuditLogView: View {
    @Environment(SessionManager.self) private var session
    @State private var records: [AuditRecord] = []
    @State private var onlyThisDevice = false
    @State private var onlyFailures = false
    @State private var export: ExportItem?
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                Toggle("只看当前 NAS", isOn: $onlyThisDevice)
                Toggle("只看失败", isOn: $onlyFailures)
            }
            Section {
                ForEach(filtered) { r in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: r.event.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(r.event.succeeded ? Theme.good : Theme.danger)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(r.title).font(.subheadline.weight(.medium))
                                Spacer()
                                Text(r.event.date.formatted(date: .numeric, time: .shortened))
                                    .font(.caption2).foregroundStyle(Theme.secondaryText)
                            }
                            Text(r.deviceName + (r.event.errorCode.map { " · 错误码 \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(Theme.secondaryText)
                            Text(r.detail).font(.caption2.monospaced()).foregroundStyle(Theme.secondaryText).lineLimit(3)
                        }
                    }
                }
                if filtered.isEmpty { Text("没有记录").foregroundStyle(Theme.secondaryText) }
            } header: {
                Text("\(filtered.count) 条（最多保留 \(AuditLog.limit) 条）")
            }
        }
        .navigationTitle("操作审计")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { if let url = AuditLog.shared.exportCSV() { export = ExportItem(items: [url]) } } label: {
                        Label("导出 CSV", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { confirmClear = true } label: { Label("清空", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $export) { ActivityView(items: $0.items) }
        .confirmationDialog("清空所有审计记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                AuditLog.shared.clear()
                records = []
            }
        }
        .onAppear { records = AuditLog.shared.records() }
        .onReceive(NotificationCenter.default.publisher(for: .auditLogChanged).receive(on: RunLoop.main)) { _ in
            records = AuditLog.shared.records()
        }
    }

    private var filtered: [AuditRecord] {
        records.filter { r in
            (!onlyThisDevice || r.deviceID == session.deviceID) && (!onlyFailures || !r.event.succeeded)
        }
    }
}
