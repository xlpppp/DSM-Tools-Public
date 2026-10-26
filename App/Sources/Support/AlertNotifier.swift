import Foundation
import BackgroundTasks
import UserNotifications
import DSMKit

/// Periodically checks every saved NAS in the background and posts a local notification for new
/// problems (failing disks, degraded or nearly full volumes, new error logs). The check is read-only
/// and nothing leaves the phone except the requests to the user's own NAS.
enum AlertNotifier {
    static let taskID = "com.xlpppp.nashelper.alerts"
    private static let enabledKey = "alertsEnabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Returns whether alerts ended up on (notification permission can be refused).
    static func setEnabled(_ on: Bool) async -> Bool {
        guard on else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
            return false
        }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        UserDefaults.standard.set(granted, forKey: enabledKey)
        if granted { schedule() }
        return granted
    }

    /// iOS decides the actual timing; 30 minutes is only the earliest it may run.
    static func schedule() {
        guard isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func runBackgroundCheck() async {
        schedule()
        guard isEnabled else { return }
        for profile in DeviceStore.loadSaved() {
            if Task.isCancelled { return }
            await check(profile)
        }
    }

    private static func check(_ profile: DeviceProfile) async {
        guard let password = KeychainStore.get(KeychainStore.passwordKey(profile.id)) else { return }
        let defaults = UserDefaults.standard
        let lastKey = "alertLastCheck.\(profile.id.uuidString)"
        let seenKey = "alertSeen.\(profile.id.uuidString)"
        let since = (defaults.object(forKey: lastKey) as? Date) ?? Date(timeIntervalSinceNow: -24 * 3600)
        let started = Date()

        do {
            let resolution = try await EndpointResolver().resolve(profile.endpoints)
            let client = resolution.client
            // Accounts with two-step verification only work here after the phone was remembered once.
            let token = KeychainStore.get(KeychainStore.deviceTokenKey(profile.id))
            _ = try await client.login(account: profile.username, password: password, deviceToken: token)
            let alerts = await client.scanHealth(since: since)
            await client.logout()

            // Ongoing problems (a failing disk) notify once, until they clear and come back.
            let seen = Set(defaults.stringArray(forKey: seenKey) ?? [])
            for alert in alerts where !seen.contains(alert.id) {
                await post(alert, device: profile.name)
            }
            defaults.set(alerts.filter { !$0.id.hasPrefix("log-") }.map(\.id), forKey: seenKey)
            defaults.set(started, forKey: lastKey)
        } catch {
            // Unreachable or login refused: try again next time; never alert on our own connectivity.
        }
    }

    private static func post(_ alert: HealthAlert, device: String) async {
        let content = UNMutableNotificationContent()
        content.title = "\(device)：\(alert.title)"
        content.body = alert.detail
        content.sound = .default
        content.threadIdentifier = device
        let request = UNNotificationRequest(identifier: "\(device)-\(alert.id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
