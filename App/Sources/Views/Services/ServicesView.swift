import SwiftUI
import DSMKit
import MediaKit

extension ServiceKind {
    var symbol: String {
        switch self {
        case .jellyfin: return "play.tv.fill"
        case .emby: return "tv.fill"
        case .immich: return "photo.stack.fill"
        case .navidrome: return "music.quarternote.3"
        }
    }

    var color: Color {
        switch self {
        case .jellyfin: return Color(hex: 0x7C3AED)
        case .emby: return Color(hex: 0x16A34A)
        case .immich: return Color(hex: 0x4F46E5)
        case .navidrome: return Color(hex: 0x0EA5E9)
        }
    }
}

/// Emby, Jellyfin, Immich and Navidrome accounts, each opened in its own browser.
struct ServicesView: View {
    @Environment(ServiceStore.self) private var store
    @Environment(DeviceStore.self) private var devices
    @State private var editing: ServiceAccount?
    @State private var adding = false

    private var visible: [ServiceAccount] {
        guard let id = devices.selectedID else { return [] }
        return store.accounts(for: id)
    }

    var body: some View {
        List {
            if visible.isEmpty {
                ContentUnavailableView {
                    Label("还没有添加影音服务", systemImage: "play.tv")
                } description: {
                    Text("支持 Emby、Jellyfin、Immich、Navidrome。使用各服务自己的账号，不会发送群晖的账号密码。")
                } actions: {
                    Button("添加服务") { adding = true }.buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            }
            ForEach(visible) { account in
                NavigationLink { ServiceHomeView(account: account) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: account.kind.symbol)
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(account.kind.color.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name).font(.subheadline.weight(.medium))
                            Text("\(account.kind.title) · \(account.summaryAddress)").font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { store.delete(account.id) } label: { Label("删除", systemImage: "trash") }
                    Button { editing = account } label: { Label("编辑", systemImage: "pencil") }.tint(.orange)
                }
            }
        }
        .navigationTitle("影音服务")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus.circle") }
            }
        }
        .sheet(isPresented: $adding) { ServiceEditorView(account: nil) }
        .sheet(item: $editing) { ServiceEditorView(account: $0) }
    }
}

struct ServiceEditorView: View {
    let account: ServiceAccount?

    @Environment(ServiceStore.self) private var store
    @Environment(DeviceStore.self) private var devices
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ServiceKind = .jellyfin
    @State private var name = ""
    @State private var lanAddress = ""
    @State private var wanAddress = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var pinned: String?
    @State private var testing = false
    @State private var result: String?
    @State private var untrusted: (host: String, fingerprint: String)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类型", selection: $kind) {
                        ForEach(ServiceKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(account != nil)
                    TextField("名称（可选）", text: $name)
                    TextField("局域网地址，如 192.0.2.10:\(String(kind.defaultPort))", text: $lanAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("外网地址，可留空", text: $wanAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("两个地址都填时，端口能连通的局域网地址优先，不因为证书失败就改走外网。")
                }
                Section {
                    if !kind.usesAPIKey {
                        TextField("用户名", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    SecureField(kind.usesAPIKey ? "API Key" : (account == nil ? "密码" : "密码（留空则不修改）"), text: $secret)
                } header: {
                    Text("账号")
                } footer: {
                    Text(kind.usesAPIKey
                         ? "在 Immich 网页的 账户设置 › API 密钥 中创建。只保存在本机钥匙串。"
                         : "只保存在本机钥匙串，不会使用群晖的账号密码。")
                }
                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("测试连接")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing || (lanAddress.isEmpty && wanAddress.isEmpty))
                    if let result { Text(result).font(.footnote) }
                    if pinned != nil {
                        Label("已信任该服务的自签证书", systemImage: "checkmark.shield").font(.footnote).foregroundStyle(Theme.good)
                    }
                }
            }
            .navigationTitle(account == nil ? "添加影音服务" : "编辑服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.save(draft, secret: secret.isEmpty ? nil : secret)
                        dismiss()
                    }
                    .disabled((lanAddress.isEmpty && wanAddress.isEmpty) || (account == nil && secret.isEmpty))
                }
            }
            .alert("信任自签证书？", isPresented: Binding(get: { untrusted != nil }, set: { if !$0 { untrusted = nil } })) {
                Button("取消", role: .cancel) {}
                Button("信任") {
                    pinned = untrusted?.fingerprint
                    Task { await test() }
                }
            } message: {
                Text("\(untrusted?.host ?? "") 的证书指纹（SHA-256）：\n\(untrusted?.fingerprint ?? "")\n\n请确认与服务器上的证书一致。")
            }
            .onAppear {
                guard let account, name.isEmpty else { return }
                kind = account.kind
                name = account.name
                lanAddress = account.lanAddress.isEmpty && account.wanAddress.isEmpty ? account.address : account.lanAddress
                wanAddress = account.wanAddress
                username = account.username
                pinned = account.pinnedCertificateSHA256
            }
        }
    }

    private var draft: ServiceAccount {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let lan = lanAddress.trimmingCharacters(in: .whitespaces)
        let wan = wanAddress.trimmingCharacters(in: .whitespaces)
        return ServiceAccount(id: account?.id ?? UUID(), kind: kind, name: trimmed.isEmpty ? kind.title : trimmed,
                              address: lan.isEmpty ? wan : lan,
                              username: username.trimmingCharacters(in: .whitespaces), pinnedCertificateSHA256: pinned,
                              lanAddress: lan, wanAddress: wan,
                              deviceID: account?.deviceID ?? devices.selectedID)
    }

    private func test() async {
        let key = secret.isEmpty ? (account.flatMap { store.secret(for: $0.id) } ?? "") : secret
        testing = true
        defer { testing = false }
        do {
            _ = try await ConnectedService.connect(draft, secret: key)
            result = "✅ 连接成功"
        } catch DSMError.untrustedCertificate(let host, let fingerprint?) {
            untrusted = (host, fingerprint)
            result = nil
        } catch {
            result = "❌ " + error.serviceMessage
        }
    }
}

/// Connects to the account, then shows the browser for its kind.
struct ServiceHomeView: View {
    let account: ServiceAccount
    @Environment(ServiceStore.self) private var store
    @State private var connected: ConnectedService?
    @State private var error: String?

    var body: some View {
        Group {
            if let connected {
                switch connected {
                case .jellyfin(let client): JellyfinLibrariesView(client: client, account: account)
                case .navidrome(let client): NavidromeView(client: client, account: account)
                case .immich(let client): ImmichView(client: client)
                }
            } else if let error {
                ContentUnavailableView {
                    Label("无法连接", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await connect() } }.buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("正在连接 \(account.name)…")
            }
        }
        .navigationTitle(account.name)
        .task { await connect() }
    }

    private func connect() async {
        error = nil
        guard let secret = store.secret(for: account.id) else {
            error = "没有保存密码或 API Key，请编辑该服务"
            return
        }
        do {
            connected = try await ConnectedService.connect(account, secret: secret)
        } catch {
            self.error = error.serviceMessage
        }
    }
}
