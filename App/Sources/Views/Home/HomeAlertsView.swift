import SwiftUI
import DSMKit

/// Recent alerts for the connected NAS: failing disks, volume problems and new error logs
/// from the last 24 hours (the same read-only scan the background check uses).
struct HomeAlertsView: View {
    let alerts: [HealthAlert]?
    let onRefresh: () async -> Void

    var body: some View {
        List {
            if let alerts {
                if alerts.isEmpty {
                    Section {
                        Label("一切正常，近 24 小时没有告警", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.good)
                    }
                } else {
                    Section("近 24 小时") {
                        ForEach(alerts.sorted { $0.severity > $1.severity }) { alert in
                            AlertRow(alert: alert)
                        }
                    }
                }
            }
            Section {
                NavigationLink(value: Module.logs) {
                    Label("打开日志中心", systemImage: Module.logs.symbol)
                }
                NavigationLink(value: Module.storage) {
                    Label("查看存储管理器", systemImage: Module.storage.symbol)
                }
            }
        }
        .overlay { if alerts == nil { ProgressView() } }
        .navigationTitle("告警")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await onRefresh() }
    }
}

private struct AlertRow: View {
    let alert: HealthAlert

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: alert.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(alert.severity == .critical ? Theme.danger : Theme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.title).font(.subheadline.weight(.medium))
                if !alert.detail.isEmpty {
                    Text(alert.detail).font(.caption).foregroundStyle(Theme.secondaryText)
                }
                if let date = alert.date {
                    Text(RecentTime.string(date)).font(.caption2).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
