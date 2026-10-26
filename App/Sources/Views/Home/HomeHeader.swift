import SwiftUI
import DSMKit

/// Screens pushed from the home screen's top bar and recent cards.
enum HomeRoute: Hashable {
    case search, transfers, alerts, recentPhotos, recentFiles
}

/// Search field plus transfer, alert and web-DSM buttons, like the original app's top row.
struct HomeTopBar: View {
    let runningTransfers: Int
    let alertCount: Int
    let onWeb: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink(value: HomeRoute.search) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("搜索")
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(Theme.card, in: Capsule())
            }
            .buttonStyle(.plain)

            NavigationLink(value: HomeRoute.transfers) {
                TopBarIcon(symbol: "arrow.up.arrow.down", badge: runningTransfers > 0 ? "\(runningTransfers)" : nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("传输任务")

            NavigationLink(value: HomeRoute.alerts) {
                TopBarIcon(symbol: alertCount > 0 ? "bell.badge" : "bell", dot: alertCount > 0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(alertCount > 0 ? "告警，\(alertCount) 条" : "告警")

            Button(action: onWeb) { TopBarIcon(symbol: "globe") }
                .buttonStyle(.plain)
                .accessibilityLabel("网页版 DSM")
        }
    }
}

private struct TopBarIcon: View {
    let symbol: String
    var badge: String?
    var dot = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 42, height: 42)
            .background(Theme.card, in: Circle())
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Theme.accent, in: Capsule())
                        .offset(x: 3, y: -3)
                } else if dot {
                    Circle().fill(Theme.danger).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                        .offset(x: -6, y: 6)
                }
            }
    }
}

/// Device name, connection kind and account. The address is deliberately not shown,
/// so a screenshot of the home screen doesn't leak where the NAS lives.
struct HomeDeviceHeader: View {
    let device: DeviceProfile
    /// nil while not connected.
    let connection: Endpoint.Kind?
    let onSwitch: () -> Void

    @AppStorage("home.hideUsername") private var hideUsername = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ConnectionTag(kind: connection)
                    Rectangle().fill(Theme.secondaryText.opacity(0.35)).frame(width: 1, height: 14)
                    Text(hideUsername ? "••••••" : device.username)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { hideUsername.toggle() }
                    } label: {
                        Image(systemName: hideUsername ? "eye.slash" : "eye")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hideUsername ? "显示用户名" : "隐藏用户名")
                }
                Button(action: onSwitch) {
                    HStack(spacing: 6) {
                        Text(device.name)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("切换设备")
            }
            Spacer(minLength: 8)
            NASModelBadge()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }
}

private struct ConnectionTag: View {
    let kind: Endpoint.Kind?

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(color.opacity(0.55), lineWidth: 1))
    }

    private var text: String {
        switch kind {
        case .lan: return "局域网连接"
        case .wan: return "外网连接"
        case .quickConnect: return "QuickConnect"
        case nil: return "未连接"
        }
    }

    private var color: Color {
        switch kind {
        case .lan: return Theme.good
        case .wan, .quickConnect: return Theme.accent
        case nil: return Theme.secondaryText
        }
    }
}

/// Home grid tile: tinted rounded square with a gradient glyph.
struct HomeModuleTile: View {
    let module: Module

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: module.symbol)
                .font(.system(size: 24, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(module.color.gradient)
                .frame(width: 56, height: 56)
                .background(module.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(module.color.opacity(0.18), lineWidth: 0.5)
                )
            Text(module.title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// Section title used by the home cards: icon, title, optional subtitle, trailing accessory.
struct HomeCardTitle<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

enum RecentTime {
    private static let time: DateFormatter = make("HH:mm")
    private static let weekday: DateFormatter = make("EEEE HH:mm")
    private static let date: DateFormatter = make("M月d日 HH:mm")

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        return f
    }

    /// "今天 14:45", "昨天 09:10", "星期一 14:45", or "10月3日 14:45".
    static func string(_ value: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(value) { return "今天 " + time.string(from: value) }
        if cal.isDateInYesterday(value) { return "昨天 " + time.string(from: value) }
        if let days = cal.dateComponents([.day], from: value, to: Date()).day, days < 7 {
            return weekday.string(from: value)
        }
        return date.string(from: value)
    }
}

/// Page background with a soft accent glow behind the header.
struct HomeBackground: View {
    var body: some View {
        Theme.background
            .overlay(alignment: .top) {
                LinearGradient(colors: [Theme.accent.opacity(0.14), Theme.accent.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 320)
            }
            .ignoresSafeArea()
    }
}
