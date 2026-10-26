import Foundation
import LocalAuthentication
import Observation

/// Admin features (users, file services, task scheduler, container rebuilds) stay locked until the
/// phone's owner confirms with Face ID / Touch ID / passcode. Monitoring never needs it.
@MainActor
@Observable
final class AdminGate {
    static let shared = AdminGate()
    /// Unlocks last this long, so a session of admin work doesn't prompt on every screen.
    static let window: TimeInterval = 5 * 60

    private(set) var unlockedUntil: Date?

    var isUnlocked: Bool { (unlockedUntil ?? .distantPast) > Date() }

    func unlock() async -> Bool {
        if isUnlocked { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set on the device: nothing stronger to check against.
            unlockedUntil = Date().addingTimeInterval(Self.window)
            return true
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁 NAS 管理功能")
            if ok { unlockedUntil = Date().addingTimeInterval(Self.window) }
            return ok
        } catch {
            return false
        }
    }

    func lock() { unlockedUntil = nil }
}
