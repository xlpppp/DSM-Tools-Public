import SwiftUI
import DSMKit

/// Resource monitor detail: "运行状态" (overview, CPU, memory, network) and
/// "进程管理" (services, processes), switched by a floating bar at the bottom.
struct ResourceMonitorView: View {
    let client: DSMClient
    let monitor: ResourceMonitor

    enum Page { case status, processes }

    enum StatusTab: String, CaseIterable {
        case overview = "总览", cpu = "CPU", memory = "内存", network = "网络"
    }

    @State private var page = Page.status
    @State private var tab = StatusTab.overview
    @State private var info: SystemInfo?

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch page {
                case .status: status
                case .processes: ProcessManagerView(client: client)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            pageBar
        }
        .background(Theme.background)
        .navigationTitle(page == .status ? "资源监控" : "进程管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: ObjectIdentifier(client)) { await monitor.run(client) }
        .task(id: ObjectIdentifier(client)) { info = try? await client.systemInfo() }
    }

    private var u: Utilization? { monitor.latest }

    // MARK: Status

    private var status: some View {
        ScrollView {
            VStack(spacing: 14) {
                PillPicker(options: StatusTab.allCases, selection: $tab) { $0.rawValue }
                if let error = monitor.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                switch tab {
                case .overview: overview
                case .cpu: cpu
                case .memory: memory
                case .network: network
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
    }

    private var overview: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    MonitorBadge(symbol: "waveform.path.ecg")
                    Text("资源监控").font(.headline)
                }
                HStack(spacing: 0) {
                    overviewRing(Double(u?.cpuPercent ?? 0), [MonitorPalette.cpu, MonitorPalette.cpuEnd], "CPU") { tab = .cpu }
                    overviewRing(Double(u?.memoryPercent ?? 0), [MonitorPalette.memory, MonitorPalette.memoryEnd], "内存") { tab = .memory }
                }
                HStack(spacing: 10) {
                    RateTile(title: "网络", lines: [
                        .init(mark: "↑", color: MonitorPalette.upload, value: u?.networkTxBytesPerSec),
                        .init(mark: "↓", color: MonitorPalette.download, value: u?.networkRxBytesPerSec),
                    ])
                    RateTile(title: "磁盘", lines: [
                        .init(mark: "R", color: MonitorPalette.read, value: u?.diskReadBytesPerSec),
                        .init(mark: "W", color: MonitorPalette.write, value: u?.diskWriteBytesPerSec),
                    ])
                }
            }
            .card(padding: 18)

            VStack(spacing: 12) {
                factRow("平均负载", "\(Format.load(u?.load1)) · \(Format.load(u?.load5)) · \(Format.load(u?.load15))")
                Divider()
                factRow("物理内存", u.map { Format.kilobytes($0.memorySizeKB) } ?? "—")
                Divider()
                factRow("交换空间", u.map { $0.swapTotalKB > 0 ? "\($0.swapPercent)% / \(Format.kilobytes($0.swapTotalKB))" : "未启用" } ?? "—")
                Divider()
                factRow("磁盘利用率", u?.diskUtilization.map { "\($0)%" } ?? "—")
                if let cpuName {
                    Divider()
                    factRow("处理器", cpuName)
                }
            }
            .card()

            MetricChart(title: "CPU", current: "\(u?.cpuPercent ?? 0)%",
                        points: monitor.series { Double($0.cpuPercent) },
                        color: MonitorPalette.cpu, axisLabel: { "\(Int($0))%" }, height: 110)
        }
    }

    private func overviewRing(_ value: Double, _ colors: [Color], _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation { action() } }) {
            VStack(spacing: 8) {
                GradientRing(value: value, colors: colors, size: 108, lineWidth: 11)
                Text(label).font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private var cpuName: String? {
        guard let info else { return nil }
        var parts = [[info.cpuVendor, info.cpuSeries].compactMap { $0 }.joined(separator: " ")]
        if let cores = info.cpuCores { parts.append("\(cores) 核") }
        if let mhz = info.cpuClockMHz { parts.append(String(format: "%.1f GHz", Double(mhz) / 1000)) }
        let text = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    // MARK: CPU

    private var cpu: some View {
        VStack(spacing: 14) {
            MetricChart(title: "CPU 使用率", current: "\(u?.cpuPercent ?? 0)%",
                        points: monitor.series { Double($0.cpuPercent) },
                        color: MonitorPalette.cpu, axisLabel: { "\(Int($0))%" })

            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("利用率", color: Theme.warning)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(u?.cpuPercent ?? 0)").font(.system(size: 40, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("%").font(.title3.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    Spacer()
                }
                .monospacedDigit()
                SegmentedBar(parts: [
                    .init(id: "user", value: Double(u?.cpuUser ?? 0), color: MonitorPalette.user),
                    .init(id: "system", value: Double(u?.cpuSystem ?? 0), color: MonitorPalette.system),
                    .init(id: "io", value: Double(u?.cpuOther ?? 0), color: MonitorPalette.ioWait),
                    .init(id: "idle", value: Double(100 - (u?.cpuPercent ?? 0)), color: .clear),
                ], height: 10)
                HStack {
                    LegendValue(label: "用户", value: "\(u?.cpuUser ?? 0)%", color: MonitorPalette.user)
                    LegendValue(label: "系统", value: "\(u?.cpuSystem ?? 0)%", color: MonitorPalette.system)
                    LegendValue(label: "I/O 等待", value: "\(u?.cpuOther ?? 0)%", color: MonitorPalette.ioWait)
                }
            }
            .card(padding: 18)

            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("平均负载", color: Theme.secondaryText)
                HStack {
                    loadCell(u?.load1, "1 分钟")
                    loadCell(u?.load5, "5 分钟")
                    loadCell(u?.load15, "15 分钟")
                }
                if let cores = info?.cpuCores, let load = u?.load1 {
                    Text(load > Double(cores) ? "负载高于核心数（\(cores) 核），任务在排队" : "\(cores) 核处理器，负载正常")
                        .font(.caption)
                        .foregroundStyle(load > Double(cores) ? Theme.warning : Theme.secondaryText)
                }
            }
            .card(padding: 18)
        }
    }

    private func sectionTitle(_ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(color).frame(width: 4, height: 18)
            Text(text).font(.headline)
        }
    }

    private func loadCell(_ value: Double?, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.load(value)).font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Memory

    private var memory: some View {
        VStack(spacing: 14) {
            MetricChart(title: "内存使用率", current: "\(u?.memoryPercent ?? 0)%",
                        points: monitor.series { Double($0.memoryPercent) },
                        color: MonitorPalette.free, axisLabel: { "\(Int($0))%" }, ceiling: 100)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    sectionTitle("内存结构", color: MonitorPalette.used)
                    Spacer()
                    Text("总计 ").foregroundColor(Theme.secondaryText)
                        + Text(u.map { Format.kilobytes($0.memorySizeKB) } ?? "—").bold()
                }
                .font(.subheadline)
                SegmentedBar(parts: memoryParts, height: 14)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], alignment: .leading, spacing: 16) {
                    ForEach(memoryParts) { part in
                        LegendValue(label: part.id, value: Format.kilobytes(Int(part.value)), color: part.color)
                    }
                }
                if let u, u.swapTotalKB > 0 {
                    Divider()
                    factRow("交换空间", "\(u.swapPercent)% / \(Format.kilobytes(u.swapTotalKB))")
                }
            }
            .card(padding: 18)
        }
    }

    private var memoryParts: [SegmentedBar.Part] {
        guard let u else { return [] }
        return [
            .init(id: "已保留", value: Double(u.memoryReservedKB), color: MonitorPalette.reserved),
            .init(id: "已用", value: Double(u.memoryUsedKB), color: MonitorPalette.used),
            .init(id: "缓冲", value: Double(u.memoryBufferKB), color: MonitorPalette.buffer),
            .init(id: "缓存", value: Double(u.memoryCachedKB), color: MonitorPalette.cached),
            .init(id: "可用", value: Double(u.memoryAvailableKB), color: MonitorPalette.free),
        ]
    }

    // MARK: Network

    private var network: some View {
        VStack(spacing: 14) {
            MetricChart(title: "接收", current: u.map { Format.rate($0.networkRxBytesPerSec) } ?? "—",
                        points: monitor.series { Double($0.networkRxBytesPerSec) },
                        color: MonitorPalette.receive, axisLabel: { Format.rate(Int($0)) })
            MetricChart(title: "发送", current: u.map { Format.rate($0.networkTxBytesPerSec) } ?? "—",
                        points: monitor.series { Double($0.networkTxBytesPerSec) },
                        color: MonitorPalette.transmit, axisLabel: { Format.rate(Int($0)) })
            if let interfaces = u?.interfaces, !interfaces.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("网络接口", color: MonitorPalette.receive)
                    ForEach(interfaces) { nic in
                        HStack {
                            Image(systemName: "network").foregroundStyle(Theme.secondaryText)
                            Text(nic.device).font(.subheadline.weight(.medium))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("↓ \(Format.rate(nic.rxBytesPerSec))").foregroundStyle(MonitorPalette.receive)
                                Text("↑ \(Format.rate(nic.txBytesPerSec))").foregroundStyle(MonitorPalette.transmit)
                            }
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                        }
                        if nic.id != interfaces.last?.id { Divider() }
                    }
                }
                .card(padding: 18)
            }
        }
    }

    // MARK: Bottom bar

    private var pageBar: some View {
        HStack(spacing: 4) {
            pageButton(.status, "运行状态", "chart.xyaxis.line")
            pageButton(.processes, "进程管理", "square.stack.3d.up.fill")
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.bottom, 12)
    }

    private func pageButton(_ target: Page, _ title: String, _ symbol: String) -> some View {
        let selected = page == target
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { page = target }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                Text(title).font(.caption2.weight(.medium))
            }
            .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
            .frame(width: 96, height: 52)
            .background(selected ? Theme.accent.opacity(0.14) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
