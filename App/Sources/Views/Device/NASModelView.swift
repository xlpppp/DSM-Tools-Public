import SwiftUI
import DSMKit

/// Drawn product view of a NAS: enclosure picked from the model name, one tray per bay,
/// and per-bay LEDs that flicker with disk activity. Everything is vector-drawn, no product photos.
///
/// Stable interface (the home header uses `NASModelBadge`, which wraps this):
/// `NASModelView(model:bays:style:activity:)`.
struct NASModelView: View {
    enum Style { case compact, hero }

    let model: String?
    /// nil = disk layout unknown (e.g. non-admin account): all bays drawn as filled, LEDs idle.
    let bays: [DriveBay]?
    var style: Style = .compact
    /// Slot number → 0...1 activity. Missing slots get a gentle idle flicker.
    var activity: [Int: Double] = [:]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: String?, bays: [DriveBay]? = nil, style: Style = .compact, activity: [Int: Double] = [:]) {
        self.model = model
        self.bays = bays
        self.style = style
        self.activity = activity
    }

    private var renderer: NASRenderer {
        NASRenderer(spec: NASModelSpec.lookup(model), bays: bays, style: style, activity: activity)
    }

    var body: some View {
        let renderer = renderer
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                renderer.draw(in: &context, size: size,
                              time: timeline.date.timeIntervalSinceReferenceDate, animate: !reduceMotion)
            }
        }
        .aspectRatio(renderer.designSize.width / renderer.designSize.height, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let spec = NASModelSpec.lookup(model)
        let name = spec.model.isEmpty ? "NAS" : spec.model
        guard let bays else { return "\(name)，\(spec.bays) 盘位" }
        let used = bays.filter { $0.state != .empty }.count
        let bad = bays.filter { $0.state == .warning || $0.state == .critical }.count
        return "\(name)，\(bays.count) 盘位，已装 \(used) 块硬盘" + (bad > 0 ? "，\(bad) 块异常" : "")
    }
}

/// Header badge: loads model and disk layout for the current session and opens the device page.
struct NASModelBadge: View {
    @Environment(SessionManager.self) private var session
    @State private var model: String?
    @State private var bays: [DriveBay]?

    var body: some View {
        NavigationLink {
            DeviceInfoView()
        } label: {
            NASModelView(model: model, bays: bays, style: .compact)
                .frame(width: 120, height: 72)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看设备信息")
        .task(id: session.client.map { ObjectIdentifier($0) }) {
            guard let client = session.client else { return }
            while !Task.isCancelled {
                if model == nil { model = try? await client.systemInfo().model }
                if let storage = try? await client.storageOverview() {
                    bays = DriveBay.layout(spec: NASModelSpec.lookup(model), disks: storage.disks)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

// MARK: - Drawing

/// Geometry is laid out in "design points" and scaled to fit the canvas.
struct NASRenderer {
    let spec: NASModelSpec
    let bays: [DriveBay]?
    let style: NASModelView.Style
    let activity: [Int: Double]

    // Front face size and the oblique offset of the back edge (3/4 view).
    let front: CGSize
    let depth: CGVector
    let shadowRoom: CGFloat

    init(spec: NASModelSpec, bays: [DriveBay]?, style: NASModelView.Style, activity: [Int: Double]) {
        self.spec = spec
        self.bays = bays
        self.style = style
        self.activity = activity
        let count = max(bays?.count ?? spec.bays, 1)
        let columns = spec.form == .compact ? count : min(count, max(spec.columns, 1))
        let rows = max(1, (count + columns - 1) / columns)
        let factor: CGFloat = style == .hero ? 1 : 0.45
        switch spec.form {
        case .desktop:
            let w = 2 * Self.margin + CGFloat(columns) * Self.trayWidth + CGFloat(columns - 1) * Self.gap
            let trayH = rows == 1 ? 72 : 36
            front = CGSize(width: w, height: Self.topStrip + CGFloat(rows) * CGFloat(trayH) + CGFloat(rows - 1) * Self.gap + 12)
            depth = CGVector(dx: w * 0.24 * factor, dy: -w * 0.14 * factor)
        case .compact:
            front = CGSize(width: count > 1 ? 66 : 56, height: 104)
            depth = CGVector(dx: 50 * factor, dy: -24 * factor)
        case .rack:
            let side: CGFloat = 16
            let slot: CGFloat = 44
            let seam: CGFloat = 3
            let rowHeight: CGFloat = 13
            let w = side * 2 + slot * 4 + seam * 3
            let h = side * 0.75 + CGFloat(rows) * rowHeight + CGFloat(rows - 1) * seam
            front = CGSize(width: w, height: h)
            depth = CGVector(dx: w * 0.16 * factor, dy: -w * 0.08 * factor)
        }
        shadowRoom = style == .hero ? 10 : 2
    }

    static let margin: CGFloat = 12
    static let trayWidth: CGFloat = 26
    static let gap: CGFloat = 4
    static let topStrip: CGFloat = 16

    var designSize: CGSize {
        CGSize(width: front.width + depth.dx, height: front.height - depth.dy + shadowRoom)
    }

    var dark: Bool { spec.form != .compact }

    func draw(in context: inout GraphicsContext, size: CGSize, time: Double, animate: Bool) {
        let scale = min(size.width / designSize.width, size.height / designSize.height)
        context.translateBy(x: (size.width - designSize.width * scale) / 2, y: (size.height - designSize.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)

        let oy = -depth.dy
        let frontRect = CGRect(x: 0, y: oy, width: front.width, height: front.height)

        if style == .hero {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 6))
                let shadow = CGRect(x: front.width * 0.04, y: frontRect.maxY - 3, width: front.width + depth.dx * 0.9, height: 9)
                layer.fill(Path(ellipseIn: shadow), with: .color(.black.opacity(0.45)))
            }
        }
        drawBody(&context, frontRect)
        switch spec.form {
        case .desktop: drawDesktopFront(&context, frontRect, time: time, animate: animate)
        case .compact: drawCompactFront(&context, frontRect, time: time, animate: animate)
        case .rack: drawRackFront(&context, frontRect, time: time, animate: animate)
        }
    }

    // MARK: Enclosure

    private func drawBody(_ context: inout GraphicsContext, _ f: CGRect) {
        let d = depth
        var top = Path()
        top.move(to: CGPoint(x: f.minX + 3, y: f.minY))
        top.addLine(to: CGPoint(x: f.minX + 3 + d.dx, y: f.minY + d.dy))
        top.addLine(to: CGPoint(x: f.maxX + d.dx - 2, y: f.minY + d.dy))
        top.addLine(to: CGPoint(x: f.maxX - 2, y: f.minY))
        top.closeSubpath()

        var side = Path()
        side.move(to: CGPoint(x: f.maxX - 2, y: f.minY))
        side.addLine(to: CGPoint(x: f.maxX + d.dx - 2, y: f.minY + d.dy))
        side.addLine(to: CGPoint(x: f.maxX + d.dx - 2, y: f.maxY + d.dy - 2))
        side.addLine(to: CGPoint(x: f.maxX - 2, y: f.maxY - 1))
        side.closeSubpath()

        let topColors: [Color] = dark ? [Color(hex: 0x3A3F47), Color(hex: 0x2A2E34)] : [Color(hex: 0xF8F9FA), Color(hex: 0xE3E6EA)]
        let sideColors: [Color] = dark ? [Color(hex: 0x202328), Color(hex: 0x0E0F12)] : [Color(hex: 0xD4D8DD), Color(hex: 0xB3B9C1)]
        context.fill(top, with: .linearGradient(Gradient(colors: topColors),
                                                startPoint: CGPoint(x: f.minX, y: f.minY + d.dy), endPoint: CGPoint(x: f.maxX, y: f.minY)))
        context.fill(side, with: .linearGradient(Gradient(colors: sideColors),
                                                 startPoint: CGPoint(x: f.maxX, y: f.midY), endPoint: CGPoint(x: f.maxX + d.dx, y: f.midY)))
        if style == .hero && spec.form == .desktop {
            // Side vent slots.
            for i in 0..<5 {
                let t = 0.25 + CGFloat(i) * 0.11
                var vent = Path()
                let x = f.maxX + d.dx * t
                vent.move(to: CGPoint(x: x, y: f.minY + d.dy * t + f.height * 0.3))
                vent.addLine(to: CGPoint(x: x, y: f.minY + d.dy * t + f.height * 0.75))
                context.stroke(vent, with: .color(.black.opacity(0.35)), lineWidth: 1.4)
            }
        }

        let frontShape = Path(roundedRect: f, cornerRadius: spec.form == .rack ? 2 : 5, style: .continuous)
        let frontColors: [Color] = dark ? [Color(hex: 0x2B2F35), Color(hex: 0x16181C)] : [Color(hex: 0xFFFFFF), Color(hex: 0xE4E7EB)]
        context.fill(frontShape, with: .linearGradient(Gradient(colors: frontColors),
                                                       startPoint: CGPoint(x: f.midX, y: f.minY), endPoint: CGPoint(x: f.midX, y: f.maxY)))
        context.stroke(frontShape, with: .color(dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)), lineWidth: 0.6)
    }

    // MARK: Desktop

    private func drawDesktopFront(_ context: inout GraphicsContext, _ f: CGRect, time: Double, animate: Bool) {
        let count = max(bays?.count ?? spec.bays, 1)
        let columns = min(count, max(spec.columns, 1))
        let rows = max(1, (count + columns - 1) / columns)
        let trayH: CGFloat = rows == 1 ? 72 : 36

        // Status, LAN LEDs and power button along the top strip.
        let stripY = f.minY + Self.topStrip / 2
        led(&context, at: CGPoint(x: f.minX + Self.margin + 2, y: stripY), color: Self.green, brightness: 1)
        led(&context, at: CGPoint(x: f.minX + Self.margin + 9, y: stripY), color: Self.green,
            brightness: blink(seed: 900, level: 0.35, time: time, animate: animate))
        led(&context, at: CGPoint(x: f.minX + Self.margin + 16, y: stripY), color: Self.green,
            brightness: blink(seed: 901, level: 0.2, time: time, animate: animate))
        powerButton(&context, at: CGPoint(x: f.maxX - Self.margin - 3, y: stripY), radius: 3.2)

        // Recess behind the trays.
        let recess = CGRect(x: f.minX + Self.margin - 3, y: f.minY + Self.topStrip - 3,
                            width: f.width - 2 * Self.margin + 6,
                            height: CGFloat(rows) * trayH + CGFloat(rows - 1) * Self.gap + 6)
        context.fill(Path(roundedRect: recess, cornerRadius: 3), with: .color(Color(hex: 0x0A0B0D)))

        for index in 0..<count {
            let col = index % columns, row = index / columns
            let rect = CGRect(x: f.minX + Self.margin + CGFloat(col) * (Self.trayWidth + Self.gap),
                              y: f.minY + Self.topStrip + CGFloat(row) * (trayH + Self.gap),
                              width: Self.trayWidth, height: trayH)
            let bay = bays?[safe: index]
            if bay?.state == .empty {
                emptyTray(&context, rect)
            } else {
                tray(&context, rect, vertical: true)
                let slot = bay?.slot ?? index + 1
                let (color, brightness) = ledState(bay, slot: slot, time: time, animate: animate)
                led(&context, at: CGPoint(x: rect.minX + 5, y: rect.minY + 5), color: color, brightness: brightness)
            }
        }

        // USB port and model label along the bottom.
        let usb = CGRect(x: f.maxX - Self.margin - 8, y: f.maxY - 8, width: 7, height: 2.6)
        context.fill(Path(roundedRect: usb, cornerRadius: 0.8), with: .color(Color(hex: 0x050506)))
        context.stroke(Path(roundedRect: usb, cornerRadius: 0.8), with: .color(Color(hex: 0x2563EB).opacity(0.8)), lineWidth: 0.5)
        if style == .hero, !spec.model.isEmpty {
            context.draw(Text(spec.model).font(.system(size: 4.2, weight: .semibold)).foregroundColor(Color.white.opacity(0.45)),
                         at: CGPoint(x: f.maxX - Self.margin - 11, y: f.maxY - 6.6), anchor: .trailing)
        }
    }

    private func tray(_ context: inout GraphicsContext, _ rect: CGRect, vertical: Bool) {
        let shape = Path(roundedRect: rect, cornerRadius: 2.5)
        context.fill(shape, with: .linearGradient(Gradient(colors: [Color(hex: 0x3A3E45), Color(hex: 0x24272C)]),
                                                  startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        context.stroke(shape, with: .color(Color(hex: 0x050607)), lineWidth: 0.7)
        // Edge highlight.
        var hl = Path()
        hl.move(to: CGPoint(x: rect.minX + 1, y: rect.maxY - 2))
        hl.addLine(to: CGPoint(x: rect.minX + 1, y: rect.minY + 2))
        hl.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 1))
        context.stroke(hl, with: .color(.white.opacity(0.10)), lineWidth: 0.6)

        if vertical {
            let handleH = min(14, rect.height * 0.32)
            let handle = CGRect(x: rect.minX + 4, y: rect.maxY - handleH - 4, width: rect.width - 8, height: handleH)
            context.fill(Path(roundedRect: handle, cornerRadius: 2), with: .color(Color(hex: 0x15171A)))
            let r: CGFloat = min(2.4, handleH * 0.22)
            let hole = CGRect(x: handle.midX - r, y: handle.midY - r, width: 2 * r, height: 2 * r)
            context.fill(Path(ellipseIn: hole), with: .color(Color(hex: 0x050506)))
            context.stroke(Path(ellipseIn: hole.insetBy(dx: -0.6, dy: -0.6)), with: .color(Color(hex: 0x50555D)), lineWidth: 0.5)
            // Vent ribs between LED and handle.
            let ribTop = rect.minY + 10, ribBottom = handle.minY - 3
            if ribBottom - ribTop > 6 {
                var y = ribTop
                while y < ribBottom {
                    var rib = Path()
                    rib.move(to: CGPoint(x: rect.minX + 6, y: y))
                    rib.addLine(to: CGPoint(x: rect.maxX - 6, y: y))
                    context.stroke(rib, with: .color(.black.opacity(0.35)), lineWidth: 0.6)
                    y += 3.2
                }
            }
        } else {
            let handle = CGRect(x: rect.maxX - 14, y: rect.minY + 2.5, width: 10, height: rect.height - 5)
            context.fill(Path(roundedRect: handle, cornerRadius: 1.5), with: .color(Color(hex: 0x15171A)))
        }
    }

    private func emptyTray(_ context: inout GraphicsContext, _ rect: CGRect) {
        let shape = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2.5)
        context.fill(shape, with: .color(Color(hex: 0x050506)))
        context.stroke(shape, with: .color(Color(hex: 0x2A2D33)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 1.5]))
    }

    // MARK: Compact (1–2 bay, closed front)

    private func drawCompactFront(_ context: inout GraphicsContext, _ f: CGRect, time: Double, animate: Bool) {
        let count = max(bays?.count ?? spec.bays, 1)
        // Glossy front panel seam.
        var seam = Path()
        seam.move(to: CGPoint(x: f.minX + 6, y: f.minY + 14))
        seam.addLine(to: CGPoint(x: f.maxX - 6, y: f.minY + 14))
        context.stroke(seam, with: .color(.black.opacity(0.08)), lineWidth: 0.8)

        var x = f.minX + 12
        let y = f.minY + 8
        led(&context, at: CGPoint(x: x, y: y), color: Self.green, brightness: 1)
        x += 8
        led(&context, at: CGPoint(x: x, y: y), color: Self.green, brightness: blink(seed: 900, level: 0.3, time: time, animate: animate))
        for index in 0..<count {
            x += 8
            let bay = bays?[safe: index]
            guard bay?.state != .empty else {
                led(&context, at: CGPoint(x: x, y: y), color: Self.green, brightness: 0)
                continue
            }
            let (color, brightness) = ledState(bay, slot: bay?.slot ?? index + 1, time: time, animate: animate)
            led(&context, at: CGPoint(x: x, y: y), color: color, brightness: brightness)
        }
        powerButton(&context, at: CGPoint(x: f.midX, y: f.maxY - 12), radius: 3.6)
        let usb = CGRect(x: f.midX - 4, y: f.maxY - 26, width: 8, height: 2.8)
        context.fill(Path(roundedRect: usb, cornerRadius: 0.8), with: .color(Color(hex: 0x1F2937)))
    }

    // MARK: Rack

    private func drawRackFront(_ context: inout GraphicsContext, _ f: CGRect, time: Double, animate: Bool) {
        let count = max(bays?.count ?? spec.bays, 1)
        let ear: CGFloat = 16
        for rect in [CGRect(x: f.minX, y: f.minY, width: ear - 2, height: f.height),
                     CGRect(x: f.maxX - ear + 2, y: f.minY, width: ear - 2, height: f.height)] {
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Color(hex: 0x1B1D21)))
        }
        led(&context, at: CGPoint(x: f.minX + 5, y: f.minY + 5), color: Self.green, brightness: 1)
        led(&context, at: CGPoint(x: f.minX + 10, y: f.minY + 5), color: Self.green, brightness: blink(seed: 900, level: 0.3, time: time, animate: animate))
        powerButton(&context, at: CGPoint(x: f.maxX - 8, y: f.minY + 6), radius: 2.8)

        for index in 0..<count {
            let col = index % 4, row = index / 4
            let rect = CGRect(x: f.minX + ear + CGFloat(col) * 47, y: f.minY + 6 + CGFloat(row) * 16, width: 44, height: 13)
            let bay = bays?[safe: index]
            if bay?.state == .empty {
                emptyTray(&context, rect)
            } else {
                tray(&context, rect, vertical: false)
                let (color, brightness) = ledState(bay, slot: bay?.slot ?? index + 1, time: time, animate: animate)
                led(&context, at: CGPoint(x: rect.minX + 4, y: rect.midY), color: color, brightness: brightness)
            }
        }
    }

    // MARK: LEDs

    static let green = Color(hex: 0x22E37A)
    static let amber = Color(hex: 0xF59E0B)
    static let red = Color(hex: 0xEF4444)

    private func ledState(_ bay: DriveBay?, slot: Int, time: Double, animate: Bool) -> (Color, Double) {
        switch bay?.state ?? .normal {
        case .empty:
            return (Self.green, 0)
        case .critical:
            // Slow alarm blink regardless of activity.
            let on = !animate || sin(time * .pi * 2) > -0.2
            return (Self.red, on ? 1 : 0.15)
        case .warning:
            return (Self.amber, blink(seed: slot, level: activity[slot] ?? 0.1, time: time, animate: animate))
        case .unused:
            return (Self.green, 0.55)
        case .normal:
            return (Self.green, blink(seed: slot, level: activity[slot] ?? 0.12, time: time, animate: animate))
        }
    }

    /// Activity flicker: higher level → faster, more frequent off-flashes, like a real drive LED.
    private func blink(seed: Int, level: Double, time: Double, animate: Bool) -> Double {
        guard animate else { return 1 }
        let rate = 3 + level * 14
        let tick = Int(floor(time * rate))
        let off = Self.noise(seed &* 1_000_003 &+ tick) < 0.08 + level * 0.55
        return off ? 0.22 : 1
    }

    private static func noise(_ n: Int) -> Double {
        var z = UInt64(truncatingIfNeeded: n) &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z % 10_000) / 10_000
    }

    private func led(_ context: inout GraphicsContext, at p: CGPoint, color: Color, brightness: Double) {
        let r: CGFloat = 1.5
        if brightness > 0.5 {
            let glow = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: glow), with: .radialGradient(Gradient(colors: [color.opacity(0.55 * brightness), color.opacity(0)]),
                                                                       center: p, startRadius: 0, endRadius: 4))
        }
        let dot = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        let off = dark ? Color(hex: 0x1D2024) : Color(hex: 0xC9CDD3)
        context.fill(Path(ellipseIn: dot), with: .color(brightness > 0.05 ? color.opacity(max(0.25, brightness)) : off))
    }

    private func powerButton(_ context: inout GraphicsContext, at p: CGPoint, radius r: CGFloat) {
        let ring = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        let glow = ring.insetBy(dx: -2.5, dy: -2.5)
        let blue = Color(hex: 0x3B82F6)
        context.fill(Path(ellipseIn: glow), with: .radialGradient(Gradient(colors: [blue.opacity(0.45), blue.opacity(0)]),
                                                                   center: p, startRadius: r * 0.6, endRadius: r + 2.5))
        context.fill(Path(ellipseIn: ring), with: .color(dark ? Color(hex: 0x111215) : Color(hex: 0xEDEFF2)))
        context.stroke(Path(ellipseIn: ring), with: .color(blue), lineWidth: 0.8)
    }
}

fileprivate extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
