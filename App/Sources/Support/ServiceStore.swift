import Foundation
import Observation
import DSMKit
import MediaKit

/// Saved third-party media servers. Addresses go to a JSON file; passwords and API keys to the Keychain.
@MainActor
@Observable
final class ServiceStore {
    private(set) var accounts: [ServiceAccount] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("services.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([ServiceAccount].self, from: data) {
            accounts = saved
        }
        claimLegacyIfNeeded()
    }

    /// Accounts saved before device scoping are attached once to the NAS selected at upgrade.
    func claimLegacyIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "serviceDeviceClaimed") else { return }
        guard let raw = UserDefaults.standard.string(forKey: "selectedDevice"),
              let deviceID = UUID(uuidString: raw) else { return }
        var changed = false
        for index in accounts.indices where accounts[index].deviceID == nil {
            accounts[index].deviceID = deviceID
            changed = true
        }
        if changed { persist() }
        UserDefaults.standard.set(true, forKey: "serviceDeviceClaimed")
    }

    func accounts(for deviceID: UUID) -> [ServiceAccount] {
        accounts.filter { $0.deviceID == deviceID }
    }

    func delete(deviceID: UUID) {
        for account in accounts where account.deviceID == deviceID {
            KeychainStore.set(nil, for: Self.secretKey(account.id))
        }
        accounts.removeAll { $0.deviceID == deviceID }
        persist()
    }

    func save(_ account: ServiceAccount, secret: String?) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        if let secret { KeychainStore.set(secret, for: Self.secretKey(account.id)) }
        persist()
    }

    func delete(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        KeychainStore.set(nil, for: Self.secretKey(id))
        persist()
    }

    func secret(for id: UUID) -> String? { KeychainStore.get(Self.secretKey(id)) }

    static func secretKey(_ id: UUID) -> String { "service.\(id.uuidString)" }

    /// Stable per-install id that Jellyfin/Emby use to tell devices apart.
    nonisolated static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "mediaDeviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "mediaDeviceID")
        return id
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

/// A signed-in client for one account.
enum ConnectedService {
    case jellyfin(JellyfinClient)
    case navidrome(SubsonicClient)
    case immich(ImmichClient)

    static func connect(_ account: ServiceAccount, secret: String) async throws -> ConnectedService {
        let chosen = await ServiceAccount.preferredAddress(account) { host, port in
            await PortProbe.isOpen(host: host, port: port)
        }
        var resolved = account
        resolved.address = chosen
        let transport = URLSessionTransport(pinnedSHA256: resolved.pinnedCertificateSHA256, timeout: 15)
        switch resolved.kind {
        case .jellyfin, .emby:
            let client = try JellyfinClient(account: resolved, transport: transport, deviceID: ServiceStore.deviceID)
            try await client.login(username: resolved.username, password: secret)
            return .jellyfin(client)
        case .navidrome:
            let client = try SubsonicClient(account: resolved, password: secret, transport: transport)
            try await client.ping()
            return .navidrome(client)
        case .immich:
            let client = try ImmichClient(account: resolved, apiKey: secret, transport: transport)
            _ = try await client.me()
            return .immich(client)
        }
    }

    /// Fetches an image or file with whatever credentials this service needs.
    var fetch: @Sendable (URL) async throws -> Data {
        switch self {
        case .jellyfin(let c): return { try await c.fetch($0) }
        case .navidrome(let c): return { try await c.fetch($0) }
        case .immich(let c): return { try await c.fetch($0) }
        }
    }
}

extension Error {
    var serviceMessage: String { (self as? ServiceError)?.message ?? userMessage }
}
