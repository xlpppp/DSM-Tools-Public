import Foundation
import Network
import Observation
import DSMKit

/// Holds the live connection to the selected NAS and keeps it on the best address
/// as the phone moves between Wi-Fi and cellular.
@MainActor
@Observable
final class SessionManager {
    enum State: Equatable {
        case idle
        case connecting
        case needsOTP
        case untrustedCertificate(host: String, fingerprint: String, endpointID: UUID)
        case failed(String)
        case connected
    }

    private(set) var state: State = .idle
    private(set) var client: DSMClient?
    private(set) var endpoint: Endpoint?
    private(set) var deviceID: UUID?
    /// Set by `logOut()`; stops network changes from signing back in until the user retries.
    private(set) var loggedOut = false

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var lastPathSignature: String?
    @ObservationIgnored private weak var store: DeviceStore?

    func connect(to profile: DeviceProfile, store: DeviceStore, otp: String? = nil) async {
        // Same device, already on screen: a path flicker must not replace the home with "正在连接…".
        let quiet = otp == nil && state == .connected && client != nil && deviceID == profile.id
        self.store = store
        deviceID = profile.id
        loggedOut = false
        if !quiet { state = .connecting }
        startMonitoring()

        guard let password = store.password(for: profile.id) else {
            state = .failed("没有保存密码，请编辑设备后重试")
            return
        }
        do {
            let resolution = try await EndpointResolver().resolve(profile.endpoints)
            let token = KeychainStore.get(KeychainStore.deviceTokenKey(profile.id))
            let result = try await resolution.client.login(account: profile.username, password: password,
                                                           otpCode: otp, deviceToken: token)
            if let did = result.deviceToken {
                KeychainStore.set(did, for: KeychainStore.deviceTokenKey(profile.id))
            }
            guard deviceID == profile.id else { return }
            let deviceName = profile.name
            let id = profile.id
            await resolution.client.setAuditHandler { event in
                AuditLog.shared.append(event, deviceID: id, deviceName: deviceName)
            }
            client = resolution.client
            endpoint = resolution.endpoint
            state = .connected
        } catch let error as DSMError {
            guard deviceID == profile.id else { return }
            if quiet, client != nil { return }
            client = nil
            switch error {
            case .otpRequired:
                state = .needsOTP
            case .untrustedCertificate(let host, let fingerprint):
                if let fingerprint, let ep = profile.endpoints.first(where: { $0.host == host }) {
                    state = .untrustedCertificate(host: host, fingerprint: fingerprint, endpointID: ep.id)
                } else if let fingerprint, profile.endpoints.filter(\.isQuickConnectID).count == 1,
                          let qc = profile.endpoints.first(where: \.isQuickConnectID) {
                    // The pin stays on the QuickConnect entry and is applied only to its LAN addresses.
                    state = .untrustedCertificate(host: host, fingerprint: fingerprint, endpointID: qc.id)
                } else {
                    state = .failed("\(host) 的证书无法验证")
                }
            default:
                state = .failed(error.message)
            }
        } catch {
            if quiet, client != nil { return }
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        let old = client
        client = nil
        endpoint = nil
        state = .idle
        Task { await old?.logout() }
    }

    /// Signs out of DSM and stays signed out; the home screen offers 重试 to sign back in.
    /// Saved password and device token are kept.
    func logOut() {
        loggedOut = true
        let old = client
        client = nil
        endpoint = nil
        state = .failed("已退出登录")
        Task { await old?.logout() }
    }

    /// Re-runs address selection after a network change, e.g. leaving home Wi-Fi.
    private func reconnectIfNeeded() {
        guard !loggedOut, state == .connected || {
            if case .failed = state { return true } else { return false }
        }(), let store, let id = deviceID, let profile = store.devices.first(where: { $0.id == id }) else { return }
        Task { await connect(to: profile, store: store) }
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let signature = Self.pathSignature(path)
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let changed = self.lastPathSignature != nil && self.lastPathSignature != signature
                self.lastPathSignature = signature
                if changed && satisfied { self.reconnectIfNeeded() }
            }
        }
        m.start(queue: DispatchQueue(label: "nashelper.path"))
        monitor = m
    }

    /// Interface names, not merely "still online". Duplicate satisfied callbacks must not reconnect.
    nonisolated private static func pathSignature(_ path: NWPath) -> String {
        let names = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
        return "\(path.status == .satisfied ? 1 : 0)|\(path.isExpensive ? 1 : 0)|\(names)"
    }
}
