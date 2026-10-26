import SwiftUI
import DSMKit

enum Module: String, CaseIterable, Identifiable, Hashable {
    case files, drive, photos, audio, video, download, cloudSync, packages, docker, vm, storage, logs, terminal, services, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "文件"
        case .drive: return "Drive"
        case .photos: return "相册"
        case .audio: return "音乐"
        case .video: return "视频"
        case .download: return "下载"
        case .cloudSync: return "Cloud Sync"
        case .packages: return "套件中心"
        case .docker: return "Docker"
        case .vm: return "虚拟机"
        case .storage: return "存储"
        case .logs: return "日志"
        case .terminal: return "终端"
        case .services: return "影音服务"
        case .system: return "系统"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "folder.fill"
        case .drive: return "externaldrive.badge.icloud"
        case .photos: return "photo.on.rectangle.angled"
        case .audio: return "music.note"
        case .video: return "play.rectangle.fill"
        case .download: return "arrow.down.circle.fill"
        case .cloudSync: return "arrow.triangle.2.circlepath.icloud.fill"
        case .packages: return "shippingbox.fill"
        case .docker: return "cube.box.fill"
        case .vm: return "desktopcomputer"
        case .storage: return "internaldrive.fill"
        case .logs: return "list.bullet.rectangle.fill"
        case .terminal: return "terminal.fill"
        case .services: return "play.tv.fill"
        case .system: return "gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .files: return Color(hex: 0xF59E0B)
        case .drive: return Color(hex: 0x0891B2)
        case .photos: return Color(hex: 0xEC4899)
        case .audio: return Color(hex: 0x22C55E)
        case .video: return Color(hex: 0xEF4444)
        case .download: return Color(hex: 0xF97316)
        case .cloudSync: return Color(hex: 0x06B6D4)
        case .packages: return Color(hex: 0x6366F1)
        case .docker: return Color(hex: 0x0EA5E9)
        case .vm: return Color(hex: 0x14B8A6)
        case .storage: return Color(hex: 0x475569)
        case .logs: return Color(hex: 0x2563EB)
        case .terminal: return Color(hex: 0x0F172A)
        case .services: return Color(hex: 0x7C3AED)
        case .system: return Color(hex: 0x64748B)
        }
    }

    /// Phase in the plan where the module lands; nil = available now.
    var phase: String? { nil }
}

struct HomeView: View {
    let device: DeviceProfile

    @Environment(DeviceStore.self) private var store
    @Environment(SessionManager.self) private var session
    @State private var switchingDevice = false
    @State private var editingDevice = false
    @State private var otpCode = ""
    @State private var alerts: [HealthAlert]?
    @State private var webEndpoint: Endpoint?
    @AppStorage(AppSettings.Key.homeShowRecentPhotos) private var showRecentPhotos = AppSettings.defaultHomeShowRecentPhotos
    @AppStorage(AppSettings.Key.homeShowRecentFiles) private var showRecentFiles = AppSettings.defaultHomeShowRecentFiles

    private var isConnected: Bool { session.state == .connected || (session.client != nil && session.state == .connecting) }

    @ViewBuilder
    private var connectedHome: some View {
        moduleGrid
        if let client = session.client {
            DashboardView(client: client)
        }
        if showRecentPhotos { HomeRecentPhotosCard(deviceID: device.id) }
        if showRecentFiles { HomeRecentFilesCard(deviceID: device.id) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HomeTopBar(runningTransfers: runningTransfers, alertCount: alerts?.count ?? 0, onWeb: openWeb)
                    .padding(.top, 8)
                HomeDeviceHeader(device: device, connection: isConnected ? session.endpoint?.kind : nil) {
                    switchingDevice = true
                }
                switch session.state {
                case .connected:
                    connectedHome
                case .connecting where session.client != nil:
                    connectedHome
                case .connecting, .idle:
                    ProgressView("正在连接…").frame(maxWidth: .infinity).card(padding: 32)
                case .failed(let message):
                    failure(message)
                case .needsOTP, .untrustedCertificate:
                    ProgressView().frame(maxWidth: .infinity).card(padding: 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(HomeBackground())
        .navigationDestination(for: Module.self) { module in
            switch module {
            case .files: FilesRootView()
            case .drive: DriveHomeView()
            case .logs: LogCenterView()
            case .download: DownloadsView()
            case .cloudSync: CloudSyncView()
            case .packages: PackagesView()
            case .docker: DockerView()
            case .terminal: SSHHubView()
            case .services: ServicesView()
            case .vm: VirtualMachinesView()
            case .photos: PhotosView()
            case .audio: MusicView()
            case .video: VideoLibraryView()
            case .storage: StorageView()
            case .system: SystemHubView()
            }
        }
        .navigationDestination(for: HomeRoute.self) { route in
            switch route {
            case .search: HomeSearchView()
            case .transfers: TransfersView()
            case .alerts: HomeAlertsView(alerts: alerts) { await loadAlerts() }
            case .recentPhotos: RecentPhotosView()
            case .recentFiles: RecentFilesView()
            }
        }
        .task(id: isConnected) { if isConnected { await loadAlerts() } else { alerts = nil } }
        .fullScreenCover(item: $webEndpoint) { WebDSMView(device: device, endpoint: $0) }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $switchingDevice) { DeviceListView() }
        .sheet(isPresented: $editingDevice) { DeviceEditorView(profile: device) }
        .alert("输入二次验证码", isPresented: otpBinding) {
            TextField("6 位验证码", text: $otpCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            Button("取消", role: .cancel) { session.disconnect() }
            Button("登录") {
                let code = otpCode
                otpCode = ""
                Task { await session.connect(to: device, store: store, otp: code) }
            }
        } message: {
            Text("该账号开启了两步验证。验证通过后，本机下次登录无需再输入。")
        }
        .alert("证书不受信任", isPresented: trustBinding, presenting: pendingTrust) { pending in
            Button("取消", role: .cancel) { session.disconnect() }
            Button("信任此证书") {
                store.trust(fingerprint: pending.fingerprint, endpointID: pending.endpointID, deviceID: device.id)
                if let updated = store.selected {
                    Task { await session.connect(to: updated, store: store) }
                }
            }
        } message: { pending in
            Text("\(pending.host) 使用的证书无法被系统验证（常见于自签名证书）。请核对 DSM 中的证书指纹后再信任：\n\n\(pending.fingerprint)")
        }
    }

    // MARK: Pieces

    private var runningTransfers: Int {
        TransferCenter.shared.running(.upload, device: device.id) + TransferCenter.shared.running(.download, device: device.id)
    }

    private func loadAlerts() async {
        guard let client = session.client else { return }
        alerts = await client.scanHealth(since: Date(timeIntervalSinceNow: -24 * 3600))
    }

    /// The web desktop has full admin power, so it sits behind the same Face ID gate as admin features.
    private func openWeb() {
        guard isConnected, let endpoint = session.endpoint else { return }
        Task { if await AdminGate.shared.unlock() { webEndpoint = endpoint } }
    }

    private var moduleGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 18) {
            ForEach(Module.allCases) { module in
                NavigationLink(value: module) {
                    HomeModuleTile(module: module)
                }
                .buttonStyle(.plain)
            }
        }
        .card(padding: 18)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(Theme.warning)
            Text(message).font(.subheadline).multilineTextAlignment(.center)
            HStack {
                Button("编辑设备") { editingDevice = true }.buttonStyle(.bordered)
                Button("重试") { Task { await session.connect(to: device, store: store) } }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 24)
    }

    // MARK: Alert bindings

    struct PendingTrust { let host: String; let fingerprint: String; let endpointID: UUID }

    private var pendingTrust: PendingTrust? {
        if case .untrustedCertificate(let host, let fp, let id) = session.state {
            return PendingTrust(host: host, fingerprint: fp, endpointID: id)
        }
        return nil
    }

    private var otpBinding: Binding<Bool> {
        Binding(get: { session.state == .needsOTP }, set: { _ in })
    }

    private var trustBinding: Binding<Bool> {
        Binding(get: { pendingTrust != nil }, set: { _ in })
    }
}
