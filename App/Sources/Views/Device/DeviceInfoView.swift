import SwiftUI
import DSMKit

/// Device page: large product drawing with live drive LEDs, power actions, basic/hardware facts,
/// per-bay disk status and a ticking system clock / uptime.
struct DeviceInfoView: View {
    @Environment(SessionManager.self) private var session
    @Environment(DeviceStore.self) private var store
    @State private var gate = AdminGate.shared
    @State private var info: SystemInfo?
    @State private var identity = ServerIdentity()
    @State private var storage: StorageOverview?
    @State private var storageError: String?
    @State private var activity: DiskActivity?
    /// When `info` was fetched, so clock and uptime can tick locally.
    @State private var fetchedAt = Date()
    @State private var error: String?
    @State private var pendingAction: PowerAction?
    @State private var actionResult: String?

    enum PowerAction: String, Identifiable {
        case reboot = "重启", shutdown = "关机"
        var id: String { rawValue }
    }

    private var spec: NASModelSpec { NASModelSpec.lookup(info?.model) }

    private var bays: [DriveBay]? {
        storage.map { DriveBay.layout(spec: spec, disks: $0.disks) }
    }

    private var m2Disks: [StorageOverview.Disk] { storage?.disks.filter(\.isM2) ?? [] }

    /// Slot → activity level for the LEDs.
    private var activityBySlot: [Int: Double] {
        guard let activity, let bays else { return [:] }
        var out: [Int: Double] = [:]
        for bay in bays {
            if let id = bay.disk?.id, let level = activity.level(for: id) { out[bay.slot] = level }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                powerButtons
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.warning).frame(maxWidth: .infinity, alignment: .leading).card()
                }
                if let actionResult {
                    Text(actionResult).font(.footnote).frame(maxWidth: .infinity, alignment: .leading).card()
                }
                basicSection
                hardwareSection
                diskSection
                timeSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationTitle("设备信息")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .task(id: session.client.map { ObjectIdentifier($0) }) { await pollActivity() }
        .confirmationDialog(pendingAction.map { "确定要\($0.rawValue)这台 NAS 吗？" } ?? "",
                            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                            titleVisibility: .visible, presenting: pendingAction) { action in
            Button(action.rawValue, role: .destructive) { Task { await run(action) } }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("正在运行的任务和连接都会中断。")
        }
    }

    // MARK: Sections

    private var hero: some View {
        VStack(spacing: 10) {
            NASModelView(model: info?.model, bays: bays, style: .hero, activity: activityBySlot)
                .frame(maxWidth: 320)
                .frame(height: 190)
            HStack(spacing: 8) {
                Text(info?.model ?? " ").font(.headline)
                if let bays {
                    let used = bays.filter { $0.state != .empty }.count
                    StatusChip(text: "\(used)/\(bays.count) 盘位", color: Theme.accent)
                    let bad = bays.filter { $0.state == .warning || $0.state == .critical }.count
                    if bad > 0 { StatusChip(text: "\(bad) 块异常", color: Theme.danger) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var powerButtons: some View {
        HStack(spacing: 12) {
            powerButton(.reboot, symbol: "arrow.clockwise", color: Theme.accent)
            powerButton(.shutdown, symbol: "power", color: Color(hex: 0xF59E0B))
        }
    }

    private func powerButton(_ action: PowerAction, symbol: String, color: Color) -> some View {
        Button {
            Task {
                // One tap from the home screen, so require the owner like other admin actions.
                if await gate.unlock() { pendingAction = action }
            }
        } label: {
            Label(action.rawValue, systemImage: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var basicSection: some View {
        InfoCard(title: "基础信息", symbol: "info.square") {
            InfoRow(label: "服务器名称", value: identity.serverName ?? store.selected?.name)
            InfoRow(label: "DSM 版本", value: info?.firmwareVersion)
            if let qc = identity.quickConnectID {
                InfoRow(label: "QuickConnect ID", value: qc)
            }
        }
    }

    private var hardwareSection: some View {
        InfoCard(title: "硬件信息", symbol: "cpu") {
            InfoRow(label: "产品型号", value: info?.model)
            InfoRow(label: "序列号", value: info?.serial)
            InfoRow(label: "CPU", value: [info?.cpuVendor, info?.cpuSeries].compactMap { $0 }.joined(separator: " ").nilIfEmpty)
            InfoRow(label: "CPU 时钟频率", value: info?.cpuClockMHz.map(Self.clock))
            InfoRow(label: "CPU 内核数", value: info?.cpuCores.map { "\($0)" })
            InfoRow(label: "物理内存大小", value: info?.ramMB.map { "\($0) MB" })
            HStack {
                Text("系统温度").foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(info?.temperature.map { "\($0) °C" } ?? "—")
                    .foregroundStyle(info?.temperatureWarning == true ? Theme.danger : Theme.good)
            }
            .font(.subheadline)
        }
    }

    private var diskSection: some View {
        InfoCard(title: "硬盘状态", symbol: "internaldrive") {
            if let bays {
                ForEach(bays) { bay in bayRow(bay) }
                ForEach(Array(m2Disks.enumerated()), id: \.element.id) { index, disk in
                    diskRow(title: "M.2 \(index + 1)", disk: disk, state: DriveBay.state(of: disk))
                }
            } else if let storageError {
                Text(storageError).font(.footnote).foregroundStyle(Theme.secondaryText)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func bayRow(_ bay: DriveBay) -> some View {
        if let disk = bay.disk {
            diskRow(title: "盘位 \(bay.slot)", disk: disk, state: bay.state)
        } else {
            HStack(spacing: 10) {
                LEDDot(color: Theme.secondaryText.opacity(0.3), blinking: false)
                Text("盘位 \(bay.slot)").font(.subheadline)
                Spacer()
                Text("空").font(.subheadline).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func diskRow(title: String, disk: StorageOverview.Disk, state: DriveBay.State) -> some View {
        HStack(spacing: 10) {
            LEDDot(color: Self.color(state), blinking: state == .critical)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text([disk.vendor, disk.model, disk.sizeBytes > 0 ? Format.bytes(disk.sizeBytes) : nil]
                    .compactMap { $0 }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(state.label).font(.subheadline.weight(.medium)).foregroundStyle(Self.color(state))
                if let t = disk.temperature, t > 0 {
                    Text("\(t) °C").font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private var timeSection: some View {
        InfoCard(title: "时间信息", symbol: "clock") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(fetchedAt))
                VStack(spacing: 12) {
                    InfoRow(label: "系统时间", value: info?.systemWallClock.map {
                        SystemInfo.formatWallClock($0.addingTimeInterval(elapsed))
                    } ?? info?.systemTime)
                    InfoRow(label: "运行时间", value: info?.upTimeSeconds.map {
                        SystemInfo.formatUptime($0 + Int(elapsed))
                    })
                }
                .monospacedDigit()
            }
        }
    }

    // MARK: Loading

    private func load() async {
        guard let client = session.client else { return }
        do {
            info = try await client.systemInfo()
            fetchedAt = Date()
            error = nil
        } catch {
            self.error = error.userMessage
        }
        identity = await client.serverIdentity()
        do {
            storage = try await client.storageOverview()
            storageError = nil
        } catch {
            storageError = "读取硬盘状态失败：\(error.userMessage)（需要管理员账号）"
        }
    }

    /// Per-disk throughput drives the LED flicker while the page is open.
    private func pollActivity() async {
        guard let client = session.client else { return }
        while !Task.isCancelled {
            if let sample = try? await client.diskActivity() { activity = sample }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func run(_ action: PowerAction) async {
        guard let client = session.client else { return }
        do {
            switch action {
            case .reboot: try await client.reboot()
            case .shutdown: try await client.shutdown()
            }
            actionResult = "已发送\(action.rawValue)指令"
        } catch {
            self.error = error.userMessage
        }
    }

    // MARK: Helpers

    static func clock(_ mhz: Int) -> String {
        mhz >= 1000 ? String(format: "%.1f GHz", Double(mhz) / 1000) : "\(mhz) MHz"
    }

    static func color(_ state: DriveBay.State) -> Color {
        switch state {
        case .empty: return Theme.secondaryText
        case .normal: return Theme.good
        case .unused: return Theme.accent
        case .warning: return Color(hex: 0xF59E0B)
        case .critical: return Theme.danger
        }
    }
}

/// Card with an icon + title header and a divider, as on the device page.
struct InfoCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            Divider()
            content
        }
        .card(padding: 18)
    }
}

/// Small status LED; critical disks blink.
struct LEDDot: View {
    let color: Color
    let blinking: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.7), radius: 3)
            .opacity(dim ? 0.25 : 1)
            .onAppear {
                guard blinking else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
