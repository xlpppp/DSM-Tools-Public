import SwiftUI
import Charts

/// Colours of the resource monitor, matched to DSM's Resource Monitor.
enum MonitorPalette {
    static let cpu = Color(hex: 0x3B82F6)
    static let cpuEnd = Color(hex: 0x22D3EE)
    static let memory = Color(hex: 0x8B5CF6)
    static let memoryEnd = Color(hex: 0xEC4899)
    static let upload = Color(hex: 0x3B82F6)
    static let download = Color(hex: 0x14B8A6)
    static let read = Color(hex: 0xEC4899)
    static let write = Color(hex: 0xF59E0B)
    static let receive = Color(hex: 0xC026D3)
    static let transmit = Color(hex: 0xF97316)
    static let user = Color(hex: 0x3B82F6)
    static let system = Color(hex: 0xA855F7)
    static let ioWait = Color(hex: 0xF59E0B)
    static let reserved = Color(hex: 0x94A3B8)
    static let used = Color(hex: 0xFACC15)
    static let buffer = Color(hex: 0x3B82F6)
    static let cached = Color(hex: 0x7DD3FC)
    static let free = Color(hex: 0x22C55E)
}

/// Ring with a gradient stroke and the value in the middle.
struct GradientRing: View {
    let value: Double
    let colors: [Color]
    var size: CGFloat = 92
    var lineWidth: CGFloat = 10

    private var fraction: Double { min(max(value, 0), 100) / 100 }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.subtle, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(fraction, 0.01))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[0].opacity(0.35), radius: 4)
                .animation(.easeOut(duration: 0.5), value: fraction)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int(value.rounded()))")
                    .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("%").font(.system(size: size * 0.13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
            }
            .monospacedDigit()
        }
        .frame(width: size, height: size)
    }
}

/// Small rounded square holding an SF Symbol, used as a section mark.
struct MonitorBadge: View {
    let symbol: String
    var colors: [Color] = [MonitorPalette.cpu, MonitorPalette.cpuEnd]
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// Two-line rate tile: "网络 ↑ 16 KB/s / ↓ 10 KB/s".
struct RateTile: View {
    struct Line {
        let mark: String
        let color: Color
        let value: Int?
    }

    let title: String
    let lines: [Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(lines.indices, id: \.self) { i in
                let line = lines[i]
                HStack(spacing: 8) {
                    Text(line.mark)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(line.color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(line.value.map(Format.rate) ?? "—")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(line.color)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Live area chart over the monitor's history.
struct MetricChart: View {
    let title: String
    let current: String
    let points: [ChartPoint]
    let color: Color
    let axisLabel: (Double) -> String
    /// Fixed top of the scale (e.g. 100 for percentages); nil scales to the data.
    var ceiling: Double?
    var height: CGFloat = 170

    private var top: Double {
        if let ceiling { return ceiling }
        let peak = points.map(\.value).max() ?? 0
        return peak > 0 ? peak * 1.15 : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(current)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
            }
            if points.count < 2 {
                ProgressView().frame(maxWidth: .infinity, minHeight: height)
            } else {
                Chart(points) { p in
                    AreaMark(x: .value("时间", p.date), y: .value(title, p.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.45), color.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("时间", p.date), y: .value(title, p.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .chartYScale(domain: 0...top)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            .foregroundStyle(Theme.secondaryText.opacity(0.35))
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(axisLabel(d)).font(.caption2).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                }
                .frame(height: height)
                .animation(.easeOut(duration: 0.3), value: points.count)
            }
        }
        .card()
    }
}

/// Pill segmented control with a sliding highlight.
struct PillPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if selected {
                                Capsule().fill(Theme.card)
                                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.subtle, in: Capsule())
    }
}

/// Horizontal bar split into coloured parts.
struct SegmentedBar: View {
    struct Part: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    let parts: [Part]
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let total = max(parts.reduce(0) { $0 + $1.value }, 1)
            HStack(spacing: 2) {
                ForEach(parts.filter { $0.value > 0 }) { part in
                    Rectangle()
                        .fill(part.color.gradient)
                        .frame(width: max(2, (geo.size.width - CGFloat(parts.count) * 2) * part.value / total))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .background(Theme.subtle, in: Capsule())
        .animation(.easeOut(duration: 0.4), value: parts.map(\.value))
    }
}

/// Legend cell with a coloured bar on the left: "已用 / 13.5 GB".
struct LegendValue: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(color).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(Theme.secondaryText)
                Text(value).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
