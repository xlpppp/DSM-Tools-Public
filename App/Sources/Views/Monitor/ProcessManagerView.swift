import SwiftUI
import DSMKit

/// Services (per package / system service) and raw processes, refreshed every 5 seconds.
struct ProcessManagerView: View {
    let client: DSMClient

    enum Tab: String, CaseIterable { case services = "服务", processes = "进程" }
    enum Sort: String, CaseIterable { case cpu = "按 CPU", memory = "按内存", name = "按名称" }

    @State private var tab = Tab.services
    @State private var sort = Sort.cpu
    @State private var query = ""
    @State private var services: [ServiceUsage]?
    @State private var processes: [SystemProcess]?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                PillPicker(options: Tab.allCases, selection: $tab) { $0.rawValue }
                toolbar
                if let error, currentIsEmpty {
                    ContentUnavailableView("无法读取\(tab.rawValue)", systemImage: "exclamationmark.triangle", description: Text(error))
                        .padding(.top, 40)
                } else {
                    switch tab {
                    case .services: serviceTable
                    case .processes: processTable
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .task(id: tab) {
            error = nil
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var currentIsEmpty: Bool {
        tab == .services ? (services ?? []).isEmpty : (processes ?? []).isEmpty
    }

    private func load() async {
        do {
            switch tab {
            case .services: services = try await client.serviceUsage()
            case .processes: processes = try await client.processes()
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.userMessage
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
                TextField(tab == .services ? "搜索服务" : "搜索进程名或 PID", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.card, in: Capsule())
            Menu {
                Picker("排序", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(Theme.card, in: Circle())
            }
        }
    }

    // MARK: Services

    private var visibleServices: [ServiceUsage] {
        let rows = (services ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .cpu: return rows
        case .memory: return rows.sorted { $0.memoryKB > $1.memoryKB }
        case .name: return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    @ViewBuilder
    private var serviceTable: some View {
        if services == nil {
            ProgressView().padding(.top, 40)
        } else {
            VStack(spacing: 0) {
                header([("服务名称", .leading, nil), ("CPU", .trailing, 52), ("CPU 时间", .trailing, 76), ("内存", .trailing, 70)])
                ForEach(visibleServices) { s in
                    HStack(spacing: 8) {
                        ServiceIcon(name: s.name)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.subheadline).lineLimit(2)
                            if s.processCount > 0 {
                                Text("\(s.processCount) 个进程").font(.caption2).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        Spacer(minLength: 4)
                        cpuText(s.cpuPercent).frame(width: 52, alignment: .trailing)
                        Text(Format.cpuTime(s.cpuTimeSeconds)).frame(width: 76, alignment: .trailing)
                        Text(Format.kilobytes(s.memoryKB)).foregroundStyle(Theme.secondaryText).frame(width: 70, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                    .padding(.vertical, 10)
                    if s.id != visibleServices.last?.id { Divider().padding(.leading, 40) }
                }
            }
            .card(padding: 14)
        }
    }

    // MARK: Processes

    private var visibleProcesses: [SystemProcess] {
        let rows = (processes ?? []).filter {
            query.isEmpty || $0.command.localizedCaseInsensitiveContains(query) || String($0.pid) == query
        }
        switch sort {
        case .cpu: return rows
        case .memory: return rows.sorted { $0.privateMemoryKB > $1.privateMemoryKB }
        case .name: return rows.sorted { $0.command.localizedStandardCompare($1.command) == .orderedAscending }
        }
    }

    @ViewBuilder
    private var processTable: some View {
        if processes == nil {
            ProgressView().padding(.top, 40)
        } else {
            VStack(spacing: 0) {
                header([("进程名称", .leading, nil), ("CPU", .trailing, 48), ("私有", .trailing, 66), ("共享", .trailing, 66)])
                ForEach(visibleProcesses) { p in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.command).font(.subheadline).lineLimit(2).truncationMode(.middle)
                            HStack(spacing: 6) {
                                Text("PID \(p.pid)")
                                Text(p.statusLabel)
                                    .foregroundStyle(p.statusLabel == "运行中" ? Theme.good : Theme.warning)
                            }
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer(minLength: 4)
                        cpuText(p.cpuPercent).frame(width: 48, alignment: .trailing)
                        Text(Format.kilobytes(p.privateMemoryKB)).frame(width: 66, alignment: .trailing)
                        Text(Format.kilobytes(p.sharedMemoryKB)).foregroundStyle(Theme.secondaryText).frame(width: 66, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                    .padding(.vertical, 9)
                    if p.id != visibleProcesses.last?.id { Divider() }
                }
            }
            .card(padding: 14)
        }
    }

    // MARK: Pieces

    private func header(_ columns: [(String, Alignment, CGFloat?)]) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(columns.indices, id: \.self) { i in
                    let c = columns[i]
                    if let width = c.2 {
                        Text(c.0).frame(width: width, alignment: c.1)
                    } else {
                        Text(c.0).frame(maxWidth: .infinity, alignment: c.1)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
            Divider()
        }
    }

    private func cpuText(_ value: Double) -> some View {
        Text(String(format: "%.1f", value))
            .fontWeight(value >= 10 ? .bold : .regular)
            .foregroundStyle(value >= 50 ? Theme.danger : value >= 10 ? Theme.warning : Color.primary)
    }
}

/// Coloured initial for a service, so rows scan easily without package artwork.
private struct ServiceIcon: View {
    let name: String

    private static let colors: [UInt32] = [0x3B82F6, 0x8B5CF6, 0x14B8A6, 0xF59E0B, 0xEC4899, 0x0EA5E9, 0x22C55E, 0xF97316]

    var body: some View {
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let color = Color(hex: Self.colors[hash % Self.colors.count])
        Text(String(name.first ?? "?").uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
