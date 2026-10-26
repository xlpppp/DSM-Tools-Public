import Foundation

/// Chassis facts used to draw a product: enclosure style and how many front drive bays it has.
///
/// DSM does not report the bay count, so it comes from a table of known models, with a
/// naming-rule fallback; `DriveBay.layout` widens it when DSM reports a disk in a higher slot.
public struct NASModelSpec: Sendable, Equatable {
    public enum Form: String, Sendable {
        /// Black desktop tower with exposed drive trays (Plus / xs series, most 4-bay and up).
        case desktop
        /// Small 1–2 bay unit with a closed front panel (j / play / value series).
        case compact
        /// Rackmount (RS / FS / SA / HD); trays are horizontal.
        case rack
    }

    public let model: String
    public let form: Form
    public let bays: Int
    /// True when `bays` came from the table rather than the naming rule.
    public let isKnown: Bool

    public init(model: String, form: Form, bays: Int, isKnown: Bool) {
        self.model = model
        self.form = form
        self.bays = bays
        self.isKnown = isKnown
    }

    /// Drive trays per row when drawn.
    public var columns: Int {
        switch form {
        case .rack: return min(bays, 4)
        case .compact: return bays
        case .desktop: return bays > 8 ? (bays + 1) / 2 : bays
        }
    }

    public var rows: Int { max(1, (bays + columns - 1) / max(columns, 1)) }

    public static func lookup(_ raw: String?) -> NASModelSpec {
        let model = (raw ?? "").trimmingCharacters(in: .whitespaces)
        let key = model.uppercased().replacingOccurrences(of: " ", with: "")
        let form = form(for: key)
        if let bays = knownBays[key] {
            return NASModelSpec(model: model, form: form, bays: bays, isKnown: true)
        }
        return NASModelSpec(model: model, form: form, bays: guessBays(key, form: form), isKnown: false)
    }

    static func form(for key: String) -> Form {
        if ["RS", "FS", "SA", "HD", "UC"].contains(where: { key.hasPrefix($0) }) { return .rack }
        guard key.hasPrefix("DS") || key.hasPrefix("DVA") else { return .desktop }
        let digits = key.drop { !$0.isNumber }.prefix { $0.isNumber }
        // 1–2 bay units without "+" or "xs" have a closed front (DS118, DS223j, DS218play).
        if let first = digits.first, digits.count == 3, ["1", "2"].contains(first),
           !key.contains("+"), !key.contains("XS") {
            return .compact
        }
        return .desktop
    }

    /// Synology names encode the maximum bays with expansion units, not the chassis itself,
    /// so this maps the common prefixes to chassis bays. Unknown → 4.
    static func guessBays(_ key: String, form: Form) -> Int {
        let digits = String(key.drop { !$0.isNumber }.prefix { $0.isNumber })
        if form == .rack { return 4 }
        switch digits.count {
        case 3:
            switch digits.first ?? "0" {
            case "1": return 1
            case "2", "7": return 2
            case "4", "9": return 4
            default: return 4
            }
        case 4:
            switch String(digits.prefix(2)) {
            case "10", "15": return 5
            case "16", "30": return 6
            case "18": return 8
            case "24", "36": return 12
            default: return 4
            }
        default:
            return 4
        }
    }

    static let knownBays: [String: Int] = {
        var table: [String: Int] = [:]
        func add(_ bays: Int, _ models: String) {
            for m in models.split(separator: " ") { table[String(m)] = bays }
        }
        add(1, "DS115J DS116 DS118 DS119J DS120J DS124")
        add(2, "DS216 DS216+ DS216+II DS216J DS216PLAY DS218 DS218+ DS218J DS218PLAY DS220+ DS220J DS223 DS223J DS224+ DS225+ DS716+ DS716+II DS718+ DS720+ DS723+ DS725+ RS217")
        add(4, "DS416 DS416J DS416PLAY DS418 DS418J DS418PLAY DS420+ DS420J DS423 DS423+ DS424+ DS425+ DS916+ DS918+ DS920+ DS923+ RS422+ RS816 RS819 RS820+ RS820RP+ RS1619XS+")
        add(5, "DS1019+ DS1515+ DS1517+ DS1520+ DS1522+ DS1525+")
        add(6, "DS1618+ DS1621+ DS1621XS+ DS1623XS+ DS3018XS")
        add(8, "DS1817 DS1817+ DS1819+ DS1821+ DS1823XS+ DS1825+ RS1219+ RS1221+ RS1221RP+")
        add(12, "DS2415+ DS2419+ DS2419+II DS2422+ DS3617XS DS3617XSII DS3622XS+ RS2418+ RS2418RP+ RS2421+ RS2421RP+ RS2423+ RS2423RP+ RS3617XS+ RS3618XS RS3621XS+ RS3621RPXS")
        add(16, "RS4021XS+ RS4017XS+ RS2821RP+ RS2825RP+")
        return table
    }()
}

/// One front drive bay as drawn: the disk in it, if any, and the LED state.
public struct DriveBay: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable {
        case empty, normal, unused, warning, critical

        public var label: String {
            switch self {
            case .empty: return "空盘位"
            case .normal: return "正常"
            case .unused: return "未使用"
            case .warning: return "警告"
            case .critical: return "危险"
            }
        }
    }

    public let slot: Int
    public let disk: StorageOverview.Disk?
    public let state: State

    public var id: Int { slot }

    public init(slot: Int, disk: StorageOverview.Disk?, state: State? = nil) {
        self.slot = slot
        self.disk = disk
        self.state = state ?? disk.map(Self.state(of:)) ?? .empty
    }

    /// Maps DSM's disk `status` and `smart_status` to an LED state.
    public static func state(of disk: StorageOverview.Disk) -> State {
        let status = (disk.status ?? "normal").lowercased()
        let smart = (disk.smartStatus ?? "normal").lowercased()
        let bad = ["crashed", "failing", "damage", "damaged", "system_partition_failed", "broken"]
        if bad.contains(status) || bad.contains(smart) { return .critical }
        if ["not_initialized", "initialized", "not_use", "unused"].contains(status) { return .unused }
        if status == "normal" && ["normal", ""].contains(smart) { return .normal }
        return .warning
    }

    /// Front bays for a chassis: internal SATA/SAS disks placed by slot number when DSM gives one,
    /// otherwise in reported order. M.2 cache drives and expansion-unit disks are left out.
    public static func layout(spec: NASModelSpec, disks: [StorageOverview.Disk]) -> [DriveBay] {
        let front = disks.filter { $0.isFrontBay }
        let highest = front.compactMap(\.slot).max() ?? 0
        let count = max(spec.bays, highest, front.count)
        var bySlot: [Int: StorageOverview.Disk] = [:]
        var unplaced: [StorageOverview.Disk] = []
        for disk in front {
            if let slot = disk.slot, slot >= 1, bySlot[slot] == nil { bySlot[slot] = disk } else { unplaced.append(disk) }
        }
        var bays: [DriveBay] = []
        for slot in 1...max(count, 1) {
            if let disk = bySlot[slot] {
                bays.append(DriveBay(slot: slot, disk: disk))
            } else if !unplaced.isEmpty {
                bays.append(DriveBay(slot: slot, disk: unplaced.removeFirst()))
            } else {
                bays.append(DriveBay(slot: slot, disk: nil))
            }
        }
        return bays
    }
}

extension StorageOverview.Disk {
    /// M.2 NVMe drives sit inside the chassis, not in a front tray.
    public var isM2: Bool {
        id.lowercased().hasPrefix("nvme") || (diskType ?? "").uppercased().contains("NVME") || (diskType ?? "").uppercased() == "M2"
    }

    public var isFrontBay: Bool {
        !isM2 && (containerType ?? "internal").lowercased() == "internal"
    }
}

/// Per-disk throughput from SYNO.Core.System.Utilization, keyed by DSM device id (e.g. "sata1").
public struct DiskActivity: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable {
        public let device: String
        public let readBytesPerSec: Int
        public let writeBytesPerSec: Int
        public let utilization: Int

        enum CodingKeys: String, CodingKey { case device, read_byte, write_byte, utilization }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            device = try c.decode(String.self, forKey: .device)
            readBytesPerSec = (try? c.decodeIfPresent(FlexInt.self, forKey: .read_byte))?.value ?? 0
            writeBytesPerSec = (try? c.decodeIfPresent(FlexInt.self, forKey: .write_byte))?.value ?? 0
            utilization = (try? c.decodeIfPresent(FlexInt.self, forKey: .utilization))?.value ?? 0
        }
    }

    public let entries: [Entry]

    struct Disk: Decodable { let disk: [Entry]? }
    enum CodingKeys: String, CodingKey { case disk }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = (try? c.decodeIfPresent(Disk.self, forKey: .disk))?.disk ?? []
    }

    /// 0...1 activity for a disk id; nil when DSM did not report that disk.
    public func level(for diskID: String) -> Double? {
        guard let e = entries.first(where: { $0.device == diskID }) else { return nil }
        if e.utilization > 0 { return min(1, Double(e.utilization) / 100) }
        let bytes = e.readBytesPerSec + e.writeBytesPerSec
        return bytes > 0 ? min(1, 0.15 + Double(bytes) / 50_000_000) : 0
    }
}

/// Server name and QuickConnect ID shown on the device page.
public struct ServerIdentity: Sendable, Equatable {
    public var serverName: String?
    public var quickConnectID: String?

    /// Memberwise init stays internal unless declared. The app constructs an empty value from another module.
    public init(serverName: String? = nil, quickConnectID: String? = nil) {
        self.serverName = serverName
        self.quickConnectID = quickConnectID
    }
}

extension DSMClient {
    public func diskActivity() async throws -> DiskActivity {
        try await call("SYNO.Core.System.Utilization", method: "get", version: 1)
    }

    /// Best effort: either field is nil when the API is missing or the account lacks rights.
    public func serverIdentity() async -> ServerIdentity {
        struct Network: Decodable { let server_name: String? }
        struct QC: Decodable { let server_alias: String? }
        var out = ServerIdentity()
        if let n: Network = try? await call("SYNO.Core.Network", method: "get", version: 1) {
            out.serverName = n.server_name?.nilIfEmpty
        }
        if let q: QC = try? await call("SYNO.Core.QuickConnect", method: "get", version: 1) {
            out.quickConnectID = q.server_alias?.nilIfEmpty
        }
        return out
    }
}

extension SystemInfo {
    /// Uptime in seconds from DSM's "d:h:m:s" or "h:m:s".
    public var upTimeSeconds: Int? {
        guard let parts = upTime?.split(separator: ":").compactMap({ Int($0) }), parts.count >= 3 else { return nil }
        let tail = parts.suffix(3)
        let (h, m, s) = (tail[tail.startIndex], tail[tail.startIndex + 1], tail[tail.startIndex + 2])
        let days = parts.count >= 4 ? parts[parts.count - 4] : 0
        return ((days * 24 + h) * 60 + m) * 60 + s
    }

    /// NAS wall-clock time, read as if it were UTC so adding seconds and formatting
    /// with the same zone keeps the NAS's local time regardless of the phone's zone.
    public var systemWallClock: Date? {
        guard let systemTime else { return nil }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = format
            if let d = f.date(from: systemTime) { return d }
        }
        return nil
    }

    public static func formatWallClock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    /// "172 天 20 小时 42 分钟 44 秒"
    public static func formatUptime(_ seconds: Int) -> String {
        let d = seconds / 86_400, h = seconds % 86_400 / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return d > 0 ? "\(d) 天 \(h) 小时 \(m) 分钟 \(s) 秒" : "\(h) 小时 \(m) 分钟 \(s) 秒"
    }
}
