import SwiftUI
import UIKit
import DSMKit

// MARK: Create a link

/// Options for a new sharing link, pre-filled from 设置 › 分享设置, then the resulting link.
struct ShareCreateSheet: View {
    let name: String
    let path: String

    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.Key.shareDefaultExpiryDays) private var defaultExpiry = AppSettings.defaultShareExpiryDays
    @AppStorage(AppSettings.Key.shareDefaultAccessLimit) private var defaultAccess = AppSettings.defaultShareAccessLimit

    @State private var expiryDays: Int?
    @State private var accessLimit: Int?
    @State private var password = ""
    @State private var creating = false
    @State private var error: String?
    @State private var link: SharingLink?

    var body: some View {
        NavigationStack {
            Group {
                if let link {
                    ShareLinkResult(name: name, link: link, expiryDays: expiryDays ?? 0, accessLimit: accessLimit ?? 0)
                } else {
                    form
                }
            }
            .navigationTitle("分享链接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if link == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("生成") { Task { await create() } }.disabled(creating)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if expiryDays == nil { expiryDays = defaultExpiry }
            if accessLimit == nil { accessLimit = defaultAccess }
        }
    }

    private var form: some View {
        Form {
            Section {
                Label(name, systemImage: "doc").lineLimit(2)
            }
            Section {
                Picker("有效期", selection: Binding(get: { expiryDays ?? defaultExpiry }, set: { expiryDays = $0 })) {
                    ForEach(AppSettings.shareExpiryChoices, id: \.self) { Text(AppSettings.expiryLabel($0)).tag($0) }
                }
                Picker("访问次数", selection: Binding(get: { accessLimit ?? defaultAccess }, set: { accessLimit = $0 })) {
                    ForEach(AppSettings.shareAccessChoices, id: \.self) { Text(AppSettings.accessLabel($0)).tag($0) }
                }
                SecureField("访问密码（可选）", text: $password)
            } footer: {
                Text("默认值可在 系统 › 分享设置 中修改。访问次数限制需要 DSM 7 支持。")
            }
            if creating {
                Section { HStack { ProgressView(); Text("正在生成…") } }
            }
            if let error {
                Section { Text(error).foregroundStyle(Theme.warning) }
            }
        }
    }

    private func create() async {
        guard let client = session.client else { return }
        creating = true
        error = nil
        let days = expiryDays ?? defaultExpiry
        let expires = days > 0 ? Calendar.current.date(byAdding: .day, value: days, to: Date()) : nil
        do {
            link = try await client.createShareLink(for: path, password: password, expires: expires,
                                                    accessLimit: accessLimit ?? defaultAccess)
        } catch {
            self.error = error.userMessage
        }
        creating = false
    }
}

private struct ShareLinkResult: View {
    let name: String
    let link: SharingLink
    let expiryDays: Int
    let accessLimit: Int
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(Theme.accent)
            Text(name).font(.headline).multilineTextAlignment(.center)
            Text(link.url)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 8) {
                StatusChip(text: AppSettings.expiryLabel(expiryDays), color: Theme.accent)
                StatusChip(text: AppSettings.accessLabel(accessLimit), color: Theme.secondaryText)
            }
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = link.url
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制链接", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                if let url = URL(string: link.url) {
                    ShareLink(item: url) {
                        Label("发送", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Text("任何拿到链接的人都能访问。可在 系统 › 分享设置 › 已分享的链接 中取消。")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(20)
    }
}

// MARK: Settings

/// 系统 › 分享设置: defaults for new links plus the list of existing ones.
struct ShareSettingsView: View {
    @AppStorage(AppSettings.Key.shareDefaultExpiryDays) private var defaultExpiry = AppSettings.defaultShareExpiryDays
    @AppStorage(AppSettings.Key.shareDefaultAccessLimit) private var defaultAccess = AppSettings.defaultShareAccessLimit

    var body: some View {
        List {
            Section {
                Picker("默认有效期", selection: $defaultExpiry) {
                    ForEach(AppSettings.shareExpiryChoices, id: \.self) { Text(AppSettings.expiryLabel($0)).tag($0) }
                }
                Picker("默认访问次数", selection: $defaultAccess) {
                    ForEach(AppSettings.shareAccessChoices, id: \.self) { Text(AppSettings.accessLabel($0)).tag($0) }
                }
            } header: {
                Text("新建链接的默认值")
            } footer: {
                Text("在文件里长按 › 分享链接 时自动填入，生成前仍可单独修改。只保存在本机。")
            }
            Section {
                NavigationLink {
                    SharedLinksView()
                } label: {
                    Label("已分享的链接", systemImage: "link")
                }
            }
        }
        .navigationTitle("分享设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Every sharing link on the NAS, with copy and cancel.
struct SharedLinksView: View {
    @Environment(SessionManager.self) private var session
    @State private var links: [SharingLink] = []
    @State private var loaded = false
    @State private var pendingDelete: SharingLink?
    @State private var confirmClear = false
    @State private var alert: String?
    @State private var copiedID: String?

    var body: some View {
        List {
            if loaded && links.isEmpty {
                Text("还没有分享过链接").foregroundStyle(Theme.secondaryText)
            }
            ForEach(links) { link in
                row(link)
                    .swipeActions {
                        Button("取消分享", role: .destructive) { pendingDelete = link }
                    }
                    .contextMenu {
                        Button { copy(link) } label: { Label("复制链接", systemImage: "doc.on.doc") }
                        if let url = URL(string: link.url) {
                            ShareLink(item: url) { Label("发送", systemImage: "square.and.arrow.up") }
                        }
                        Button(role: .destructive) { pendingDelete = link } label: { Label("取消分享", systemImage: "trash") }
                    }
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .navigationTitle("已分享的链接")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("清理失效") { confirmClear = true }.disabled(!links.contains { !$0.isValid })
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("取消这个分享链接？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { link in
            Button("取消分享", role: .destructive) { Task { await delete(link) } }
            Button("保留", role: .cancel) {}
        } message: { link in
            Text("\(link.name ?? link.url)\n已经拿到链接的人将无法再访问。")
        }
        .confirmationDialog("删除所有已过期或失效的链接？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清理", role: .destructive) { Task { await clearInvalid() } }
            Button("取消", role: .cancel) {}
        }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    private func row(_ link: SharingLink) -> some View {
        HStack(spacing: 12) {
            Image(systemName: link.isFolder ? "folder.fill" : "doc.fill")
                .font(.title3)
                .foregroundStyle(link.isValid ? Theme.accent : Theme.secondaryText)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(link.name ?? link.path ?? link.url).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(link.url).font(.caption.monospaced()).foregroundStyle(Theme.secondaryText).lineLimit(1)
                HStack(spacing: 6) {
                    StatusChip(text: link.isValid ? "有效" : "已失效", color: link.isValid ? Theme.good : Theme.secondaryText)
                    Text(link.dateExpired.map { "到期 \($0)" } ?? "永久有效")
                    if let n = link.accessLimit, n > 0 { Text("· 剩 \(n) 次") }
                    if link.hasPassword { Image(systemName: "lock.fill") }
                }
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            Button { copy(link) } label: {
                Image(systemName: copiedID == link.id ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
    }

    private func copy(_ link: SharingLink) {
        UIPasteboard.general.string = link.url
        copiedID = link.id
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            links = try await client.shareLinks()
        } catch {
            alert = error.userMessage
        }
        loaded = true
    }

    private func delete(_ link: SharingLink) async {
        guard let client = session.client else { return }
        do {
            try await client.deleteShareLinks([link.id])
            links.removeAll { $0.id == link.id }
        } catch {
            alert = error.userMessage
        }
    }

    private func clearInvalid() async {
        guard let client = session.client else { return }
        do {
            try await client.clearInvalidShareLinks()
        } catch {
            alert = error.userMessage
        }
        await load()
    }
}
