import SwiftUI
import DSMKit

struct DeviceListView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(ServiceStore.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var editing: DeviceProfile?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.devices) { device in
                    HStack {
                        Button {
                            store.select(device.id)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    Text(device.endpoints.map(\.host).joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if device.id == store.selectedID {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Button { editing = device } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(Theme.accent)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("编辑 \(device.name)")
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            services.delete(deviceID: device.id)
                            store.delete(device.id)
                        }
                        Button("编辑") { editing = device }.tint(Theme.accent)
                    }
                    .contextMenu {
                        Button("编辑") { editing = device }
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            .navigationTitle("我的设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("添加设备")
                }
            }
            .sheet(item: $editing) { DeviceEditorView(profile: $0) }
            .sheet(isPresented: $adding) { DeviceEditorView(profile: nil) }
        }
    }
}

/// Add or edit a NAS: name, account, any number of addresses, and separate SSH settings.
struct DeviceEditorView: View {
    let profile: DeviceProfile?

    @Environment(DeviceStore.self) private var store
    @Environment(SessionManager.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var endpoints: [Endpoint] = []
    @State private var ssh = SSHSettings()
    @State private var sshLanPortText = "22"
    @State private var sshWanPortText = "22"
    @State private var sshPassword = ""
    @State private var showsSSH = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    deviceCard
                    accountCard
                    addressSection
                    sshCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { saveBar }
            .navigationTitle(profile == nil ? "添加群晖" : "编辑设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 10) {
            Image("BrandMark")
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.35), radius: 16, y: 8)
            Text(profile == nil ? "连接你的群晖" : "编辑 \(profile?.name ?? "设备")")
                .font(.title3.bold())
            Text("填写 DSM 账号和访问地址，局域网与外网会自动切换。")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var deviceCard: some View {
        EditorCard(title: "设备", symbol: "externaldrive.fill", tint: Theme.accent) {
            FieldRow(symbol: "tag", placeholder: "名称，如 家庭 NAS", text: $name)
        }
    }

    private var accountCard: some View {
        EditorCard(title: "DSM 账号", symbol: "person.crop.circle.fill", tint: Theme.memory,
                   footer: "密码只保存在本机钥匙串中。监控和管理功能需要管理员账号。") {
            FieldRow(symbol: "person", placeholder: "账号", text: $username, contentType: .username)
            FieldDivider()
            SecureFieldRow(symbol: "lock", placeholder: profile == nil ? "密码" : "密码（留空则不修改）",
                           text: $password)
        }
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "连接地址", symbol: "network", tint: Theme.good)
            ForEach($endpoints) { $endpoint in
                let index = endpoints.firstIndex { $0.id == endpoint.id } ?? 0
                EndpointEditor(endpoint: $endpoint,
                               order: index + 1,
                               canMoveUp: index > 0,
                               canDelete: endpoints.count > 1,
                               moveUp: { endpoints.swapAt(index, index - 1) },
                               delete: { endpoints.removeAll { $0.id == endpoint.id } })
            }
            Button {
                withAnimation(.snappy) {
                    endpoints.append(Endpoint(kind: endpoints.isEmpty ? .lan : .wan, host: ""))
                }
            } label: {
                Label("添加地址", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .foregroundStyle(Theme.accent)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    )
            }
            Text("按顺序使用端口能连通的地址，不访问网页，所以自签证书不会把局域网判成不可用。建议把局域网放在最前。")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 4)
        }
    }

    private var sshCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { showsSSH.toggle() }
            } label: {
                HStack(spacing: 12) {
                    IconBadge(symbol: "terminal.fill", tint: Color(hex: 0x0EA5E9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SSH").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(sshSummary).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .rotationEffect(.degrees(showsSSH ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsSSH {
                VStack(spacing: 0) {
                    FieldDivider().padding(.top, 14)
                    sshSide("局域网", host: $ssh.lanHost, portText: $sshLanPortText)
                    FieldDivider()
                    sshSide("外网", host: $ssh.wanHost, portText: $sshWanPortText)
                    FieldDivider()
                    FieldRow(symbol: "person", placeholder: "SSH 账号（留空沿用 DSM 账号）", text: $ssh.username)
                    FieldDivider()
                    SecureFieldRow(symbol: "key", placeholder: "SSH 密码（留空沿用 DSM 密码）", text: $sshPassword)
                    if ssh.trustedHostKeySHA256 != nil {
                        FieldDivider()
                        Button("清除已信任的主机指纹", role: .destructive) { ssh.trustedHostKeySHA256 = nil }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    }
                    Text("局域网和外网可以各填一个地址。留空的一侧会跳过。这里填写的端口会原样使用，包括 22；只有两边都留空、沿用 DSM 地址时，才会改用 DSM 报告的 SSH 端口。先探测端口再连接。")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .card()
    }

    private var saveBar: some View {
        Button(action: save) {
            Text(profile == nil ? "保存并连接" : "保存")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    LinearGradient(colors: [Color(hex: 0x3B82F6), Theme.accent, Color(hex: 0x1D4ED8)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .shadow(color: Theme.accent.opacity(isValid ? 0.35 : 0), radius: 12, y: 6)
                .opacity(isValid ? 1 : 0.45)
        }
        .disabled(!isValid)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private func sshSide(_ title: String, host: Binding<String>, portText: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText).frame(width: 44, alignment: .leading)
            FieldRow(symbol: "server.rack", placeholder: "地址，可留空", text: host, keyboard: .URL)
            TextField("22", text: portText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.subheadline.monospacedDigit())
                .frame(width: 64, height: 34)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var sshSummary: String {
        let lan = ssh.lanHost.trimmingCharacters(in: .whitespaces)
        let wan = ssh.wanHost.trimmingCharacters(in: .whitespaces)
        if lan.isEmpty && wan.isEmpty { return "沿用连接地址" }
        return [lan.isEmpty ? nil : "局域网 \(lan)", wan.isEmpty ? nil : "外网 \(wan)"].compactMap { $0 }.joined(separator: " · ")
    }

    private func sshPort(_ text: String) -> Int {
        Int(text.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil } ?? 22
    }

    // MARK: Logic

    private var isValid: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && endpoints.contains { !$0.host.trimmingCharacters(in: .whitespaces).isEmpty }
            && (profile != nil || !password.isEmpty)
    }

    private func load() {
        guard endpoints.isEmpty else { return }
        if let profile {
            name = profile.name
            username = profile.username
            endpoints = profile.endpoints
            ssh = profile.ssh
            if ssh.lanHost.isEmpty && ssh.wanHost.isEmpty && !ssh.host.isEmpty {
                let parsed = SSHTarget.parse(ssh.host)
                ssh.lanHost = parsed.host
                ssh.lanPort = parsed.port ?? ssh.port
            }
            sshLanPortText = String(ssh.lanPort)
            sshWanPortText = String(ssh.wanPort)
            showsSSH = !ssh.lanHost.isEmpty || !ssh.wanHost.isEmpty || !profile.ssh.host.isEmpty
                || profile.ssh.port != 22 || !ssh.username.isEmpty
        } else {
            endpoints = [Endpoint(kind: .lan, host: "")]
        }
    }

    private func save() {
        ssh.lanHost = ssh.lanHost.trimmingCharacters(in: .whitespaces)
        ssh.wanHost = ssh.wanHost.trimmingCharacters(in: .whitespaces)
        ssh.lanPort = sshPort(sshLanPortText)
        ssh.wanPort = sshPort(sshWanPortText)
        ssh.host = ""
        ssh.port = 22
        let cleaned = endpoints
            .map { Endpoint(id: $0.id, kind: $0.kind, host: $0.host, port: $0.port, useHTTPS: $0.useHTTPS,
                            pinnedCertificateSHA256: $0.pinnedCertificateSHA256) }
            .filter { !$0.host.isEmpty }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let updated = DeviceProfile(id: profile?.id ?? UUID(),
                                    name: trimmedName.isEmpty ? (cleaned.first?.host ?? "群晖") : trimmedName,
                                    endpoints: cleaned,
                                    username: username.trimmingCharacters(in: .whitespaces),
                                    ssh: ssh)
        store.save(updated, password: password.isEmpty ? nil : password)
        if !sshPassword.isEmpty { KeychainStore.set(sshPassword, for: KeychainStore.sshPasswordKey(updated.id)) }
        if store.selectedID == updated.id {
            Task { await session.connect(to: updated, store: store) }
        }
        dismiss()
    }
}

/// One connection address shown as its own card.
struct EndpointEditor: View {
    @Binding var endpoint: Endpoint
    var order = 1
    var canMoveUp = false
    var canDelete = false
    var moveUp: () -> Void = {}
    var delete: () -> Void = {}

    @State private var portText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(order)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(kindColor, in: Circle())
                KindPicker(selection: $endpoint.kind)
                Spacer(minLength: 0)
                Menu {
                    if canMoveUp { Button("上移优先级", systemImage: "arrow.up", action: moveUp) }
                    if canDelete { Button("删除地址", systemImage: "trash", role: .destructive, action: delete) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 32, height: 32)
                        .background(Theme.subtle, in: Circle())
                }
                .disabled(!canMoveUp && !canDelete)
            }

            FieldRow(symbol: endpoint.kind == .quickConnect ? "bolt.horizontal" : "link",
                     placeholder: endpoint.kind == .quickConnect ? "QuickConnect ID，如 mynas"
                                                                 : "地址，如 192.0.2.10 或 nas.example.com",
                     text: $endpoint.host, keyboard: .URL)
                .padding(.horizontal, 12)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 10) {
                Toggle(isOn: $endpoint.useHTTPS) {
                    Label("HTTPS", systemImage: endpoint.useHTTPS ? "lock.fill" : "lock.open")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .fixedSize()
                .onChange(of: endpoint.useHTTPS) { _, https in
                    // Follow DSM's default ports unless the user typed a custom one.
                    if endpoint.port == 5000 || endpoint.port == 5001 {
                        endpoint.port = https ? 5001 : 5000
                        portText = String(endpoint.port)
                    }
                }
                Spacer(minLength: 0)
                if endpoint.kind != .quickConnect {
                    HStack(spacing: 6) {
                        Text("端口").font(.subheadline).foregroundStyle(Theme.secondaryText)
                        TextField("5001", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .font(.subheadline.monospacedDigit())
                            .frame(width: 64, height: 34)
                            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .onChange(of: portText) { _, text in
                                if let p = Int(text) { endpoint.port = p }
                            }
                    }
                }
            }

            if endpoint.kind == .quickConnect {
                Text("会向群晖 QuickConnect 服务器查询该 ID 的内网、外网和中转地址，自动选可用的。只发送 ID，不发送账号密码。中转速度较慢。")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            if endpoint.pinnedCertificateSHA256 != nil {
                Label("已信任此地址的自签名证书", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(Theme.good)
            }
        }
        .card()
        .onAppear { portText = String(endpoint.port) }
    }

    private var kindColor: Color {
        switch endpoint.kind {
        case .lan: return Theme.good
        case .wan: return Theme.accent
        case .quickConnect: return Theme.memory
        }
    }
}

// MARK: - Editor building blocks

private struct KindPicker: View {
    @Binding var selection: Endpoint.Kind
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Endpoint.Kind.allCases, id: \.self) { kind in
                Button {
                    withAnimation(.snappy) { selection = kind }
                } label: {
                    Text(kind == .quickConnect ? "QC" : kind.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selection == kind ? .white : Theme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background {
                            if selection == kind {
                                Capsule().fill(Theme.accent).matchedGeometryEffect(id: "kind", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind.label)
            }
        }
        .padding(2)
        .background(Theme.subtle, in: Capsule())
    }
}

private struct EditorCard<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: title, symbol: symbol, tint: tint)
            VStack(spacing: 0) { content }.card(padding: 4)
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct SectionLabel: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            IconBadge(symbol: symbol, tint: tint, size: 22)
            Text(title).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 4)
    }
}

private struct IconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct FieldRow: View {
    let symbol: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 22)
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textContentType(contentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
    }
}

private struct SecureFieldRow: View {
    let symbol: String
    let placeholder: String
    @Binding var text: String
    @State private var reveals = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 22)
            Group {
                if reveals {
                    TextField(placeholder, text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textContentType(.password)
            Button {
                reveals.toggle()
            } label: {
                Image(systemName: reveals ? "eye.slash" : "eye")
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reveals ? "隐藏密码" : "显示密码")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
    }
}

private struct FieldDivider: View {
    var body: some View {
        Divider().padding(.leading, 46)
    }
}
