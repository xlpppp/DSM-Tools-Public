import SwiftUI

struct RingGauge: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Theme.subtle, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(value, 0), 100)) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
                Text("\(value)%")
                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
                    .contentTransition(.numericText())
            }
            .frame(width: 72, height: 72)
            Text(label).font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)%")
    }
}

struct AppTile: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// Simple NAS drawing for the device header, so no product imagery is needed.
struct NASIllustration: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x1E293B))
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: 0x0F172A))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(hex: 0x475569), lineWidth: 1))
                }
            }
            .padding(EdgeInsets(top: 14, leading: 8, bottom: 8, trailing: 22))
            VStack(spacing: 5) {
                Circle().fill(Theme.good).frame(width: 4, height: 4)
                Circle().fill(Color(hex: 0x38BDF8)).frame(width: 4, height: 4)
            }
            .padding(.top, 16)
            .padding(.trailing, 8)
        }
        .frame(width: 112, height: 64)
        .accessibilityHidden(true)
    }
}

struct InfoRow: View {
    let label: String
    let value: String?

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(value ?? "—").multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

/// Shown for modules scheduled in later phases.
struct ComingSoonView: View {
    let title: String
    let phase: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "hammer")
        } description: {
            Text("该模块计划在 \(phase) 提供")
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
