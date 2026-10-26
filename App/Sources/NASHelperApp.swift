import SwiftUI

@main
struct NASHelperApp: App {
    @State private var store = DeviceStore()
    @State private var session = SessionManager()
    @State private var player = MusicPlayer()
    @State private var services = ServiceStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(session)
                .environment(player)
                .environment(services)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { if scenePhase == .background { AlertNotifier.schedule() } }
        .backgroundTask(.appRefresh(AlertNotifier.taskID)) { await AlertNotifier.runBackgroundCheck() }
    }
}
