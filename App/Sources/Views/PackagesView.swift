import SwiftUI
import DSMKit

struct PackagesView: View {
    enum Tab: String, CaseIterable {
        case installed = "已安装", updates = "可更新", available = "可安装"
    }

    @Environment(SessionManager.self) private var session
    @State private var tab: Tab = .installed
    @State private var installed: [InstalledPackage] = []
    @State private var catalog: [String: CatalogPackage] = [:]
    @State private var loaded = false
    @State private var search = ""
    @State private var pendingStop: InstalledPackage?
    @State private var working: Set<String> = []
    @State private var alert: String?

    private var updates: [InstalledPackage] {
        installed.filter { p in catalog[p.id].map { isNewerVersion($0.version, than: p.version) } ?? false }
    }

    private var notInstalled: [CatalogPackage] {
        let ids = Set(installed.map(\.id))
        return catalog.values.filter { !ids.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func matches(_ name: String) -> Bool {
        search.isEmpty || name.localizedCaseInsensitiveContains(search)
    }

    var body: some View {
        List {
            Section {
                Picker("分类", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Text(t == .updates && !updates.isEmpty ? "\(t.rawValue) \(updates.count)" : t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                switch tab {
                case .installed:
                    ForEach(installed.filter { matches($0.name) }) { installedRow($0) }
                case .updates:
                    ForEach(updates.filter { matches($0.name) }) { installedRow($0) }
                    if loaded && updates.isEmpty { Text("所有套件都是最新版本").foregroundStyle(Theme.secondaryText) }
                case .available:
                    ForEach(notInstalled.filter { matches($0.name) }) { availableRow($0) }
                }
            } footer: {
                if tab != .installed {
                    Text("安装和更新暂需在 DSM 网页版的套件中心完成，App 内安装将在接口验证后加入。")
                }
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .searchable(text: $search, prompt: "搜索套件")
        .navigationTitle("套件中心")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("停止「\(pendingStop?.name ?? "")」？", isPresented: Binding(
            get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }), titleVisibility: .visible) {
            Button("停止", role: .destructive) {
                if let p = pendingStop { toggle(p) }
                pendingStop = nil
            }
        } message: {
            Text("依赖这个套件的服务也会停止。")
        }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    private func installedRow(_ p: InstalledPackage) -> some View {
        HStack(spacing: 12) {
            PackageIcon(url: catalog[p.id]?.iconURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(p.version)
                    if let newer = catalog[p.id], isNewerVersion(newer.version, than: p.version) {
                        Text("可更新到 \(newer.version)").foregroundStyle(Theme.accent)
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if working.contains(p.id) {
                ProgressView()
            } else if p.startable {
                Button {
                    if p.isRunning { pendingStop = p } else { toggle(p) }
                } label: {
                    Text(p.isRunning ? "停止" : "启动")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background((p.isRunning ? Theme.danger : Theme.good).opacity(0.12), in: Capsule())
                        .foregroundStyle(p.isRunning ? Theme.danger : Theme.good)
                }
                .buttonStyle(.plain)
            } else {
                StatusChip(text: p.statusLabel, color: p.isRunning ? Theme.good : Theme.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }

    private func availableRow(_ p: CatalogPackage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PackageIcon(url: p.iconURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.subheadline.weight(.medium))
                if let summary = p.summary {
                    Text(summary).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(3)
                }
                Text(p.version).font(.caption2).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            installed = try await client.installedPackages()
        } catch {
            alert = error.userMessage
        }
        // The catalog needs the NAS to reach Synology's server; the list works without it.
        if let list = try? await client.packageCatalog() {
            catalog = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        loaded = true
    }

    private func toggle(_ p: InstalledPackage) {
        guard let client = session.client else { return }
        working.insert(p.id)
        Task {
            do {
                if p.isRunning { try await client.stopPackage(p.id) } else { try await client.startPackage(p.id) }
            } catch {
                alert = error.userMessage
            }
            if let list = try? await client.installedPackages() { installed = list }
            working.remove(p.id)
        }
    }
}

private struct PackageIcon: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: "shippingbox.fill")
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Color(hex: 0x6366F1).gradient)
    }
}
