import Foundation

/// UserDefaults keys for app-level preferences, shared by the settings screens and the views
/// that honour them. Read with `@AppStorage(AppSettings.Key.x)`; defaults live here too.
enum AppSettings {
    enum Key {
        /// Bool, default true: show the "recently viewed photos" block on the home screen.
        static let homeShowRecentPhotos = "home.showRecentPhotos"
        /// Bool, default true: show the "recently viewed files" block on the home screen.
        static let homeShowRecentFiles = "home.showRecentFiles"
        /// Int days, default 7; 0 = never expires.
        static let shareDefaultExpiryDays = "share.defaultExpiryDays"
        /// Int, default 0 = unlimited accesses.
        static let shareDefaultAccessLimit = "share.defaultAccessLimit"
    }

    static let defaultHomeShowRecentPhotos = true
    static let defaultHomeShowRecentFiles = true
    static let defaultShareExpiryDays = 7
    static let defaultShareAccessLimit = 0

    static let shareExpiryChoices = [1, 3, 7, 30, 90, 0]
    static let shareAccessChoices = [1, 5, 10, 50, 100, 0]

    static func expiryLabel(_ days: Int) -> String { days == 0 ? "永久有效" : "\(days) 天" }
    static func accessLabel(_ count: Int) -> String { count == 0 ? "不限次数" : "\(count) 次" }
}
