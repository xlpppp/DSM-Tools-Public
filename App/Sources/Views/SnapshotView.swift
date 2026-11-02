import SwiftUI
import DSMKit

/// Snapshot Replication: share snapshots, a schedule, replication plans, and the log.
struct SnapshotView: View {
    @Environment(SessionManager.self) private var session
    @State private var tab = 0
    @State private var shares: [RemoteFile] = []
    @State private var plans: [ReplicationPlan] = []
    @State private var logs: [LogEntry] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var creatingPlan = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("总览").tag(0)
                Text("复制").tag(1)
                Text("日志").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(16)
            Group {
                switch tab {
                case 1: plansList
                case 2: logsList
                default: shareList
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("快照复制")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert("无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .sheet(isPresented: $creatingPlan) {
            ReplicationEditor(shares: shares.map(\.name)) { source, host, port, user, password, dest, schedule in
                await createPlan(source: source, host: host, port: port, user: user, password: password, dest: dest, schedule: schedule)
            }
        }
    }

    private var shareList: some View {
        List {
            if loaded && shares.isEmpty {
                ContentUnavailableView("没有共享文件夹", systemImage: "externaldrive", description: Text("安装 Snapshot Replication 后，Btrfs 共享文件夹可以做快照。"))
            }
            ForEach(shares) { share in
                NavigationLink {
                    ShareSnapshotList(share: share.name)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(share.name).font(.body)
                        Text(share.path).font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
    }

    private var plansList: some View {
        List {
            if loaded && plans.isEmpty {
                Text("还没有复制任务").foregroundStyle(Theme.secondaryText)
            }
            ForEach(plans) { plan in
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.source).font(.body)
                    Text(plan.destination.isEmpty ? "目标未返回" : plan.destination)
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                    Text(plan.enabled ? "计划已启用" : "计划已停用").font(.caption2).foregroundStyle(Theme.secondaryText)
                    if let ok = plan.lastSuccess {
                        Text(ok ? "上次同步成功" : "上次同步失败").font(.caption2)
                            .foregroundStyle(ok ? Theme.secondaryText : Theme.warning)
                    }
                    Button("立即同步") { Task { await sync(plan) } }
                        .font(.footnote)
                }
                .padding(.vertical, 4)
            }
            Button("创建复制任务") { creatingPlan = true }
        }
    }

    private var logsList: some View {
        List {
            if loaded && logs.isEmpty { Text("没有快照日志").foregroundStyle(Theme.secondaryText) }
            ForEach(logs) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.message).font(.subheadline)
                    Text([entry.displayTime, entry.category].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            shares = try await client.listSharedFolders()
            plans = (try? await client.replicationPlans()) ?? []
            logs = (try? await client.snapshotLogs()) ?? []
            error = nil
        } catch {
            self.error = error.userMessage
        }
        loaded = true
    }

    private func sync(_ plan: ReplicationPlan) async {
        guard let client = session.client else { return }
        do {
            try await client.syncReplication(plan.id)
            plans = (try? await client.replicationPlans()) ?? plans
        } catch {
            self.error = error.userMessage
        }
    }

    private func createPlan(source: String, host: String, port: Int, user: String, password: String,
                            dest: String, schedule: SnapshotSchedule) async -> String? {
        guard let client = session.client else { return "未登录" }
        do {
            try await client.createReplication(sourceShare: source, host: host, port: port, username: user,
                                               password: password, destinationShare: dest, schedule: schedule)
            plans = (try? await client.replicationPlans()) ?? plans
            return nil
        } catch {
            return error.userMessage
        }
    }
}

private struct ShareSnapshotList: View {
    let share: String
    @Environment(SessionManager.self) private var session
    @State private var shots: [ShareSnapshot] = []
    @State private var error: String?
    @State private var busy = false
    @State private var restore: ShareSnapshot?
    @State private var scheduling = false

    var body: some View {
        List {
            Section {
                Button(busy ? "正在创建…" : "立即创建快照") { Task { await create() } }
                    .disabled(busy)
                Button("快照计划") { scheduling = true }
            }
            Section("已有快照 \(shots.count)") {
                if shots.isEmpty { Text("还没有快照").foregroundStyle(Theme.secondaryText) }
                ForEach(shots) { shot in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(shot.displayTime).font(.body)
                        if !shot.description.isEmpty {
                            Text(shot.description).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        HStack(spacing: 8) {
                            if shot.locked { Text("已锁定").font(.caption2).foregroundStyle(Theme.secondaryText) }
                            if shot.scheduled { Text("计划").font(.caption2).foregroundStyle(Theme.secondaryText) }
                        }
                        Button("还原") { restore = shot }
                            .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(share)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .sheet(isPresented: $scheduling) { ScheduleEditor(share: share) }
        .confirmationDialog("还原「\(share)」？", isPresented: Binding(get: { restore != nil }, set: { if !$0 { restore = nil } }), titleVisibility: .visible) {
            Button("还原", role: .destructive) {
                if let restore { Task { await restoreShot(restore) } }
            }
            Button("取消", role: .cancel) { restore = nil }
        } message: {
            Text("共享文件夹会回到 \(restore?.displayTime ?? "这张快照")。这之后新增或修改的文件会被覆盖。")
        }
        .alert("无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func reload() async {
        guard let client = session.client else { return }
        do { shots = try await client.shareSnapshots(share) } catch { self.error = error.userMessage }
    }

    private func create() async {
        guard let client = session.client else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.createShareSnapshot(share)
            await reload()
        } catch {
            self.error = error.userMessage
        }
    }

    private func restoreShot(_ shot: ShareSnapshot) async {
        guard let client = session.client else { return }
        restore = nil
        do {
            try await client.restoreShareSnapshot(share, time: shot.time)
            await reload()
        } catch {
            self.error = error.userMessage
        }
    }
}

private struct ScheduleEditor: View {
    let share: String
    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var hour = 3
    @State private var minute = 0
    @State private var repeatHours = 0
    @State private var keep = 256
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Stepper("每天 \(hour) 点", value: $hour, in: 0...23)
                Stepper("\(minute) 分", value: $minute, in: 0...59)
                Stepper(repeatHours == 0 ? "不重复" : "每 \(repeatHours) 小时再做一次", value: $repeatHours, in: 0...12)
                Stepper("最多保留 \(keep) 张", value: $keep, in: 1...1024)
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.warning) }
            }
            .navigationTitle("\(share) 的计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中" : "保存") { Task { await save() } }.disabled(saving)
                }
            }
        }
    }

    private func save() async {
        guard let client = session.client else { return }
        saving = true
        defer { saving = false }
        do {
            try await client.setSnapshotSchedule(share, SnapshotSchedule(hour: hour, minute: minute, repeatHours: repeatHours, keep: keep))
            dismiss()
        } catch {
            self.error = error.userMessage
        }
    }
}

private struct ReplicationEditor: View {
    let shares: [String]
    let save: (String, String, Int, String, String, String, SnapshotSchedule) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var host = ""
    @State private var port = "5001"
    @State private var user = ""
    @State private var password = ""
    @State private var dest = ""
    @State private var hour = 1
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("来源共享文件夹", selection: $source) {
                    Text("请选择").tag("")
                    ForEach(shares, id: \.self) { Text($0).tag($0) }
                }
                TextField("目标主机", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("端口", text: $port).keyboardType(.numberPad)
                TextField("目标账号", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("目标密码", text: $password)
                TextField("目标共享文件夹", text: $dest).textInputAutocapitalization(.never).autocorrectionDisabled()
                Stepper("每天 \(hour) 点同步", value: $hour, in: 0...23)
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.warning) }
            }
            .navigationTitle("复制任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "创建中" : "创建") { Task { await submit() } }.disabled(saving || source.isEmpty)
                }
            }
        }
        .onAppear { if source.isEmpty { source = shares.first ?? "" } }
    }

    private func submit() async {
        saving = true
        defer { saving = false }
        let message = await save(source, host.trimmingCharacters(in: .whitespaces), Int(port) ?? 22,
                                 user, password, dest.trimmingCharacters(in: .whitespaces),
                                 SnapshotSchedule(hour: hour))
        if let message { error = message } else { dismiss() }
    }
}

private extension LogEntry {
    var displayTime: String? {
        guard let time else { return rawTime.isEmpty ? nil : rawTime }
        return time.formatted(date: .numeric, time: .shortened)
    }
}
