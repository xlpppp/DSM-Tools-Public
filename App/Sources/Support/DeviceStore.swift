import Foundation
import Observation
import SwiftUI
import DSMKit

/// Saved NAS list. Profiles go to a JSON file; passwords go to the Keychain.
@MainActor
@Observable
final class DeviceStore {
    private(set) var devices: [DeviceProfile] = []
    private(set) var selectedID: UUID?

    /// Also read by the background alert check, which may run while the phone is locked.
    nonisolated static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("devices.json")
    }()

    init() {
        devices = Self.loadSaved()
        if let raw = UserDefaults.standard.string(forKey: "selectedDevice"), let id = UUID(uuidString: raw),
           devices.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = devices.first?.id
        }
    }

    var selected: DeviceProfile? { devices.first { $0.id == selectedID } }

    func select(_ id: UUID?) {
        selectedID = id
        UserDefaults.standard.set(id?.uuidString, forKey: "selectedDevice")
    }

    func save(_ profile: DeviceProfile, password: String?) {
        if let i = devices.firstIndex(where: { $0.id == profile.id }) {
            devices[i] = profile
        } else {
            devices.append(profile)
        }
        if let password { KeychainStore.set(password, for: KeychainStore.passwordKey(profile.id)) }
        if selectedID == nil { select(profile.id) }
        persist()
    }

    func delete(_ id: UUID) {
        KeychainStore.set(nil, for: KeychainStore.sshPasswordKey(id))
        devices.removeAll { $0.id == id }
        KeychainStore.set(nil, for: KeychainStore.passwordKey(id))
        KeychainStore.set(nil, for: KeychainStore.deviceTokenKey(id))
        RecentStore.shared.forget(id)
        if selectedID == id { select(devices.first?.id) }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        devices.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func password(for id: UUID) -> String? { KeychainStore.get(KeychainStore.passwordKey(id)) }

    /// Records the certificate fingerprint the user chose to trust for one address.
    func trust(fingerprint: String, endpointID: UUID, deviceID: UUID) {
        guard let d = devices.firstIndex(where: { $0.id == deviceID }),
              let e = devices[d].endpoints.firstIndex(where: { $0.id == endpointID }) else { return }
        devices[d].endpoints[e].pinnedCertificateSHA256 = fingerprint
        persist()
    }

    /// Records the SSH host key fingerprint the user confirmed.
    func trustSSH(fingerprint: String, deviceID: UUID) {
        guard let d = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[d].ssh.trustedHostKeySHA256 = fingerprint
        persist()
    }

    nonisolated static func loadSaved() -> [DeviceProfile] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([DeviceProfile].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        // No secrets in this file (passwords are in the Keychain), so it stays readable after first unlock
        // for background alert checks.
        try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
