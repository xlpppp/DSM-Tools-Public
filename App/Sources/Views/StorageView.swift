import SwiftUI
import DSMKit

/// Storage Manager: capacity, pools, volumes and per-disk health. Read-only.
struct StorageView: View {
    @Environment(SessionManager.self) private var session
    @State private var overview: StorageOverview?
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Section { Text(error).foregroundStyle(Theme.warning) }
            }
            if let overview {
                summary(overview)
                if !overview.unhealthyDisks.isEmpty || overview.volumes.contains(where: { !isNormal($0.status) })
                    || overview.pools.contains(where: { !isNormal($0.status) }) {
                    warnings(overview)
                }
                if !overview.pools.isEmpty {
                    Section("存储池") {
                        ForEach(overview.pools) { pool in poolRow(pool, disks: overview.disks) }
                    }
                }
                Section("存储空间") {
                    ForEach(overview.volumes) { volumeRow($0) }
                }
                Section("硬盘") {
                    ForEach(overview.disks) { disk in
                        NavigationLink {
                            DiskDetailView(disk: disk, pool: overview.pools.first { $0.id == disk.poolID })
                        } label: {
                            diskRow(disk)
                        }
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("存储管理器")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func summary(_ o: StorageOverview) -> some View {
        Section {
            HStack(spacing: 20) {
                RingGauge(value: o.totalBytes > 0 ? Int(Double(o.usedBytes) / Double(o.totalBytes) * 100) : 0,
                          label: "已用", color: usageColor(o.usedBytes, o.totalBytes))
                VStack(alignment: .leading, spacing: 6) {
                    Text(Format.bytes(o.totalBytes - o.usedBytes) + " 可用")
                        .font(.title3.weight(.semibold))
                    Text("已用 \(Format.bytes(o.usedBytes)) / 共 \(Format.bytes(o.totalBytes))")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    HStack(spacing: 8) {
                        StatusChip(text: "\(o.disks.count) 块硬盘", color: Theme.accent)
                        if o.unhealthyDisks.isEmpty {
                            StatusChip(text: "全部良好", color: Theme.good)
                        } else {
                            StatusChip(text: "\(o.unhealthyDisks.count) 块异常", color: Theme.danger)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
    }

    private func warnings(_ o: StorageOverview) -> some View {
        Section {
            ForEach(o.unhealthyDisks) { disk in
                Label("\(disk.name ?? disk.id)：状态 \(statusLabel(disk.status))，S.M.A.R.T. \(statusLabel(disk.smartStatus))",
                      systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(Theme.danger)
            }
            ForEach(o.pools.filter { !isNormal($0.status) }) { pool in
                Label("\(pool.name)：\(statusLabel(pool.status))", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            }
            ForEach(o.volumes.filter { !isNormal($0.status) }) { volume in
                Label("\(StorageStatus.volumeName(volume.name))：\(statusLabel(volume.status))", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            }
        } header: {
            Text("需要注意")
        } footer: {
            Text("硬盘异常时请尽快备份数据，并在 DSM 存储管理器中查看详情或更换硬盘。")
        }
        .font(.subheadline)
    }

    private func poolRow(_ pool: StorageOverview.Pool, disks: [StorageOverview.Disk]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(pool.name).font(.subheadline.weight(.medium))
                Text(pool.raidLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(Theme.accent)
                Spacer()
                Text(statusLabel(pool.status))
                    .font(.caption)
                    .foregroundStyle(isNormal(pool.status) ? Theme.good : Theme.warning)
            }
            if pool.totalBytes > 0 {
                ProgressView(value: Double(pool.usedBytes), total: Double(pool.totalBytes))
                    .tint(usageColor(pool.usedBytes, pool.totalBytes))
            }
            let members = pool.diskIDs.compactMap { id in disks.first { $0.id == id }?.name ?? id }
            Text([Format.bytes(pool.totalBytes), members.isEmpty ? nil : members.joined(separator: "、")]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, 4)
    }

    private func volumeRow(_ volume: StorageOverview.Volume) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "externaldrive.fill").foregroundStyle(Theme.accent)
                Text(StorageStatus.volumeName(volume.name)).font(.subheadline.weight(.medium))
                Spacer()
                Text(statusLabel(volume.status))
                    .font(.caption)
                    .foregroundStyle(isNormal(volume.status) ? Theme.good : Theme.warning)
            }
            ProgressView(value: Double(volume.usedBytes), total: Double(max(volume.totalBytes, 1)))
                .tint(usageColor(volume.usedBytes, volume.totalBytes))
            HStack {
                Text("已用 \(Format.bytes(volume.usedBytes)) / \(Format.bytes(volume.totalBytes))")
                Spacer()
                Text("可用 \(Format.bytes(max(volume.totalBytes - volume.usedBytes, 0)))")
            }
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, 4)
    }

    private func diskRow(_ disk: StorageOverview.Disk) -> some View {
        HStack(spacing: 12) {
            Image(systemName: disk.diskType?.uppercased().contains("NVME") == true || disk.diskType == "SSD" ? "memorychip" : "internaldrive")
                .font(.title3)
                .foregroundStyle(disk.isHealthy ? Theme.good : Theme.danger)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(disk.name ?? disk.id).font(.subheadline)
                Text([disk.vendor, disk.model, Format.bytes(disk.sizeBytes)].compactMap { $0 }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(disk.isHealthy ? "良好" : "异常")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(disk.isHealthy ? Theme.good : Theme.danger)
                if let t = disk.temperature {
                    Text("\(t) ℃")
                        .font(.caption)
                        .foregroundStyle(t >= 55 ? Theme.warning : Theme.secondaryText)
                }
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            overview = try await client.storageOverview()
            error = nil
        } catch {
            self.error = error.userMessage
        }
    }
}

private func isNormal(_ status: String?) -> Bool { StorageStatus.isNormal(status) }

private func statusLabel(_ status: String?) -> String { StorageStatus.label(status) }

private func usageColor(_ used: Int64, _ total: Int64) -> Color {
    guard total > 0 else { return Theme.accent }
    let ratio = Double(used) / Double(total)
    return ratio >= 0.9 ? Theme.danger : ratio >= 0.8 ? Theme.warning : Theme.accent
}

private struct DiskDetailView: View {
    let disk: StorageOverview.Disk
    let pool: StorageOverview.Pool?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "internaldrive.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background((disk.isHealthy ? Theme.good : Theme.danger).gradient,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(disk.name ?? disk.id).font(.headline)
                        Text(disk.isHealthy ? "健康状况良好" : "需要注意")
                            .font(.subheadline)
                            .foregroundStyle(disk.isHealthy ? Theme.good : Theme.danger)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("健康") {
                InfoRow(label: "状态", value: statusLabel(disk.status))
                InfoRow(label: "S.M.A.R.T.", value: disk.smartStatus.map { $0 == "normal" ? "正常" : statusLabel($0) })
                InfoRow(label: "温度", value: disk.temperature.map { "\($0) ℃" })
                if let bad = disk.badSectors {
                    HStack {
                        Text("坏扇区").foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Text("\(bad)").foregroundStyle(bad > 0 ? Theme.warning : .primary)
                    }
                    .font(.subheadline)
                }
                if let life = disk.remainingLife {
                    InfoRow(label: "剩余寿命", value: "\(life)%")
                }
            }
            Section("信息") {
                InfoRow(label: "品牌", value: disk.vendor)
                InfoRow(label: "型号", value: disk.model)
                InfoRow(label: "序列号", value: disk.serial)
                InfoRow(label: "固件", value: disk.firmware)
                InfoRow(label: "类型", value: disk.diskType)
                InfoRow(label: "容量", value: Format.bytes(disk.sizeBytes))
                InfoRow(label: "所属存储池", value: pool.map { "\($0.name)（\($0.raidLabel)）" })
            }
        }
        .navigationTitle(disk.name ?? disk.id)
        .navigationBarTitleDisplayMode(.inline)
    }
}
