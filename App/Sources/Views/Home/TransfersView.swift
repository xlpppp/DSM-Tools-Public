import SwiftUI
import DSMKit

/// Uploads and downloads between this phone and the NAS, plus a way into Download Station.
struct TransfersView: View {
    @Environment(SessionManager.self) private var session

    private var items: [TransferCenter.Item] { TransferCenter.shared.items(for: session.deviceID) }

    var body: some View {
        List {
            Section {
                NavigationLink(value: Module.download) {
                    HStack(spacing: 12) {
                        Image(systemName: Module.download.symbol)
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Module.download.color.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Download Station").font(.subheadline.weight(.medium))
                            Text("NAS 上的离线下载任务").font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
            Section {
                ForEach(items) { item in
                    TransferRow(item: item)
                }
            } header: {
                HStack {
                    Text("本机传输")
                    Spacer()
                    let up = TransferCenter.shared.running(.upload, device: session.deviceID)
                    let down = TransferCenter.shared.running(.download, device: session.deviceID)
                    if up > 0 { StatusChip(text: "上传中 \(up)", color: Theme.accent) }
                    if down > 0 { StatusChip(text: "下载中 \(down)", color: Theme.good) }
                }
            } footer: {
                if items.isEmpty {
                    Text("在文件中上传或下载后，任务会显示在这里。记录只保留到 App 退出。")
                }
            }
        }
        .navigationTitle("传输任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清除已完成") { TransferCenter.shared.clearFinished(device: session.deviceID) }
                    .disabled(!items.contains { $0.state != .running })
            }
        }
    }
}

private struct TransferRow: View {
    let item: TransferCenter.Item

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.direction == .upload ? "arrow.up" : "arrow.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background((item.direction == .upload ? Theme.accent : Theme.good).gradient, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.subheadline).lineLimit(1)
                status
            }
            Spacer(minLength: 0)
            if item.state == .running { ProgressView() }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .running:
            Text(item.direction == .upload ? "正在上传…" : "正在下载…")
                .font(.caption).foregroundStyle(Theme.secondaryText)
        case .done:
            Text("已完成 · \(RecentTime.string(item.finished ?? item.started))")
                .font(.caption).foregroundStyle(Theme.secondaryText)
        case .failed(let message):
            Text("失败：\(message)").font(.caption).foregroundStyle(Theme.danger).lineLimit(2)
        }
    }
}
