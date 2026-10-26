import SwiftUI
import UIKit
import DSMKit

enum Theme {
    static let accent = Color(hex: 0x2563EB)
    static let background = Color(light: 0xEEF2F7, dark: 0x0B1220)
    static let card = Color(light: 0xFFFFFF, dark: 0x162033)
    static let subtle = Color(light: 0xF1F5F9, dark: 0x1E293B)
    static let secondaryText = Color(light: 0x64748B, dark: 0x94A3B8)
    static let good = Color(hex: 0x16A34A)
    static let warning = Color(hex: 0xC2410C)
    static let danger = Color(hex: 0xDC2626)
    static let memory = Color(hex: 0x8B5CF6)

    static let cardRadius: CGFloat = 22
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// White rounded card used across the app.
struct CardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    static func rate(_ bytesPerSecond: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
    }
}

extension Error {
    /// Chinese message for DSM errors, system text otherwise.
    var userMessage: String { (self as? DSMError)?.message ?? localizedDescription }
}
