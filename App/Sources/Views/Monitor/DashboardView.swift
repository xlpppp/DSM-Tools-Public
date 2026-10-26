import SwiftUI
import DSMKit

/// Live resources and storage on the home page. The home page calls this as
/// `DashboardView(client:)`; keep that signature stable.
struct DashboardView: View {
    let client: DSMClient

    @State private var monitor = ResourceMonitor()
    @State private var storage: StorageOverview?

    var body: some View {
        VStack(spacing: 14) {
            ResourceMonitorCard(client: client, monitor: monitor)
            storageCard
        }
        .task(id: ObjectIdentifier(client)) {
            storage = try? await client.storageOverview()
        }
    }

    @ViewBuilder
    private var storageCard: some View {
        if let storage, storage.totalBytes > 0 {
            NavigationLink(value: Module.storage) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("存储空间").font(.headline)
                        Spacer()
                        if !storage.unhealthyDisks.isEmpty {
                            StatusChip(text: "\(storage.unhealthyDisks.count) 块硬盘异常", color: Theme.warning)
                        }
                    }
                    ProgressView(value: Double(storage.usedBytes), total: Double(storage.totalBytes))
                        .tint(Theme.accent)
                    HStack {
                        Text("已用 \(Format.bytes(storage.usedBytes))")
                        Spacer()
                        Text("可用 \(Format.bytes(storage.totalBytes - storage.usedBytes))")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                }
                .card()
            }
            .buttonStyle(.plain)
        }
    }
}

/// Home card: CPU and memory rings, network and disk rates. Tapping opens the detail page.
struct ResourceMonitorCard: View {
    let client: DSMClient
    let monitor: ResourceMonitor

    var body: some View {
        NavigationLink {
            ResourceMonitorView(client: client, monitor: monitor)
        } label: {
            content
        }
        .buttonStyle(PressableCardStyle())
        .task(id: ObjectIdentifier(client)) { await monitor.run(client) }
    }

    private var u: Utilization? { monitor.latest }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                MonitorBadge(symbol: "waveform.path.ecg")
                Text("资源监控").font(.headline)
                Spacer()
                if monitor.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
                HStack(spacing: 2) {
                    Text("详情")
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            }

            HStack(spacing: 0) {
                ring(value: Double(u?.cpuPercent ?? 0), colors: [MonitorPalette.cpu, MonitorPalette.cpuEnd],
                     label: "CPU", caption: u?.load1.map { "负载 \(Format.load($0))" })
                ring(value: Double(u?.memoryPercent ?? 0), colors: [MonitorPalette.memory, MonitorPalette.memoryEnd],
                     label: "内存", caption: memoryCaption)
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

            if let error = monitor.lastError {
                Text(error).font(.caption).foregroundStyle(Theme.warning)
            }
        }
        .foregroundStyle(.primary)
        .card(padding: 18)
    }

    private var memoryCaption: String? {
        guard let u, u.memorySizeKB > 0 else { return nil }
        return "\(Format.kilobytes(u.memoryUsedKB)) / \(Format.kilobytes(u.memorySizeKB))"
    }

    private func ring(value: Double, colors: [Color], label: String, caption: String?) -> some View {
        VStack(spacing: 6) {
            GradientRing(value: value, colors: colors, size: 96)
            Text(label).font(.subheadline.weight(.medium))
            Text(caption ?? " ").font(.caption2).foregroundStyle(Theme.secondaryText).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(Int(value))%")
    }
}

/// Slight press-down feedback for tappable cards.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
