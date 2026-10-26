import Foundation

/// Summary from SYNO.Storage.CGI.Storage `load_info` (Storage Manager). Needs an admin account.
public struct StorageOverview: Decodable, Sendable, Equatable {
    public struct Volume: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let path: String?
        public let status: String?
        public let totalBytes: Int64
        public let usedBytes: Int64

        enum CodingKeys: String, CodingKey { case id, vol_path, status, size }
        struct Size: Decodable { let total: FlexString?; let used: FlexString? }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(FlexString.self, forKey: .id).value
            path = try c.decodeIfPresent(String.self, forKey: .vol_path)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            let size = try c.decodeIfPresent(Size.self, forKey: .size)
            totalBytes = Int64(size?.total?.value ?? "") ?? 0
            usedBytes = Int64(size?.used?.value ?? "") ?? 0
        }

        public var name: String {
            if let path, let last = path.split(separator: "/").last { return String(last) }
            return id
        }
    }

    public struct Disk: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String?
        public let model: String?
        public let vendor: String?
        public let status: String?
        public let smartStatus: String?
        public let temperature: Int?
        public let sizeBytes: Int64
        public let serial: String?
        public let firmware: String?
        public let diskType: String?
        /// SSD remaining life in percent, when DSM reports it.
        public let remainingLife: Int?
        public let badSectors: Int?
        public let poolID: String?
        /// Bay number inside its enclosure (DSM `num_id`).
        public let slot: Int?
        /// "internal" for the NAS itself, "ebox" for an expansion unit (DSM `container.type`).
        public let containerType: String?

        enum CodingKeys: String, CodingKey {
            case id, name, model, vendor, status, smart_status, temp, size_total
            case serial, firm, diskType, remain_life, unc, used_by, num_id, container
        }
        struct Container: Decodable { let type: String? }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(FlexString.self, forKey: .id).value
            name = try c.decodeIfPresent(String.self, forKey: .name)
            model = try c.decodeIfPresent(String.self, forKey: .model)?.trimmingCharacters(in: .whitespaces)
            vendor = try c.decodeIfPresent(String.self, forKey: .vendor)?.trimmingCharacters(in: .whitespaces)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            smartStatus = try c.decodeIfPresent(String.self, forKey: .smart_status)
            temperature = try c.decodeIfPresent(FlexInt.self, forKey: .temp)?.value
            sizeBytes = Int64(try c.decodeIfPresent(FlexString.self, forKey: .size_total)?.value ?? "") ?? 0
            serial = try c.decodeIfPresent(String.self, forKey: .serial)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            firmware = try c.decodeIfPresent(String.self, forKey: .firm)?.nilIfEmpty
            diskType = try c.decodeIfPresent(String.self, forKey: .diskType)?.nilIfEmpty
            // remain_life is an int on some models and {"value": n} on others; -1 means unknown.
            let life = (try? c.decodeIfPresent(FlexInt.self, forKey: .remain_life))?.value
                ?? (try? c.decodeIfPresent(LifeValue.self, forKey: .remain_life))?.value.value
            remainingLife = life.flatMap { $0 >= 0 ? $0 : nil }
            badSectors = (try? c.decodeIfPresent(FlexInt.self, forKey: .unc))?.value
            poolID = try c.decodeIfPresent(String.self, forKey: .used_by)?.nilIfEmpty
            slot = (try? c.decodeIfPresent(FlexInt.self, forKey: .num_id))?.value
            containerType = (try? c.decodeIfPresent(Container.self, forKey: .container))?.type
        }

        struct LifeValue: Decodable { let value: FlexInt }

        /// DSM uses "normal" for a healthy disk; anything else deserves attention.
        public var isHealthy: Bool {
            StorageStatus.isNormal(status) && StorageStatus.isNormal(smartStatus)
        }
    }

    public struct Pool: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let number: Int?
        public let raidType: String?
        public let status: String?
        public let totalBytes: Int64
        public let usedBytes: Int64
        public let diskIDs: [String]

        enum CodingKeys: String, CodingKey { case id, num_id, device_type, raidType, status, size, disks }
        struct Size: Decodable { let total: FlexString?; let used: FlexString? }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(FlexString.self, forKey: .id).value
            number = (try? c.decodeIfPresent(FlexInt.self, forKey: .num_id))?.value
            raidType = try (c.decodeIfPresent(String.self, forKey: .device_type) ?? c.decodeIfPresent(String.self, forKey: .raidType))
            status = try c.decodeIfPresent(String.self, forKey: .status)
            let size = try c.decodeIfPresent(Size.self, forKey: .size)
            totalBytes = Int64(size?.total?.value ?? "") ?? 0
            usedBytes = Int64(size?.used?.value ?? "") ?? 0
            diskIDs = (try? c.decodeIfPresent([String].self, forKey: .disks)) ?? []
        }

        public var name: String { number.map { "存储池 \($0)" } ?? id }

        /// "raid_5" / "shr_without_disk_protect" → readable label.
        public var raidLabel: String {
            guard let raw = raidType?.lowercased() else { return "—" }
            if raw.hasPrefix("shr_2") || raw == "shr2" { return "SHR-2" }
            if raw.hasPrefix("shr") { return raw.contains("without") ? "SHR（无容错）" : "SHR" }
            if raw == "basic" { return "Basic" }
            if raw == "jbod" { return "JBOD" }
            if raw.hasPrefix("raid_") { return "RAID " + raw.dropFirst(5) }
            return raw.uppercased()
        }
    }

    public let volumes: [Volume]
    public let disks: [Disk]
    public let pools: [Pool]

    enum CodingKeys: String, CodingKey { case volumes, disks, storagePools }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumes = (try? c.decodeIfPresent([Volume].self, forKey: .volumes)) ?? []
        disks = (try? c.decodeIfPresent([Disk].self, forKey: .disks)) ?? []
        pools = (try? c.decodeIfPresent([Pool].self, forKey: .storagePools)) ?? []
    }

    public var totalBytes: Int64 { volumes.reduce(0) { $0 + $1.totalBytes } }
    public var usedBytes: Int64 { volumes.reduce(0) { $0 + $1.usedBytes } }
    public var unhealthyDisks: [Disk] { disks.filter { !$0.isHealthy } }
}

/// Chinese labels for the status strings Storage Manager returns for pools, volumes and disks
/// ("attention", "degrade", "crashed"…). Unknown values fall back to the raw string so nothing is hidden.
public enum StorageStatus {
    public static func isNormal(_ status: String?) -> Bool {
        guard let s = status?.lowercased(), !s.isEmpty else { return true }
        return s == "normal"
    }

    public static func label(_ status: String?) -> String {
        guard let raw = status, !raw.isEmpty else { return "良好" }
        switch raw.lowercased() {
        case "normal": return "良好"
        case "attention": return "需要注意"
        case "warning": return "警告"
        case "abnormal": return "异常"
        case "degrade", "degraded": return "降级"
        case "crashed", "crash": return "已损毁"
        case "failing": return "即将损坏"
        case "repairing": return "修复中"
        case "background_checking", "data_scrubbing", "parity_checking": return "数据清理中"
        case "expanding": return "扩展中"
        case "migrating": return "迁移中"
        case "deploying", "creating": return "创建中"
        case "deleting": return "删除中"
        case "read_only", "readonly": return "只读"
        case "initialized": return "已初始化"
        case "not_initialized", "uninitialized": return "未初始化"
        case "system_partition_failed", "sys_partition_failed": return "系统分区失败"
        case "unformatted": return "未格式化"
        case "disabled": return "已停用"
        case "secure_erasing": return "安全擦除中"
        case "unknown": return "未知"
        default: return raw
        }
    }

    /// "volume1" → "存储空间 1", matching what DSM shows in Chinese; anything else is returned as is.
    public static func volumeName(_ name: String) -> String {
        if name.hasPrefix("volume"), let n = Int(name.dropFirst(6)) { return "存储空间 \(n)" }
        return name
    }
}

extension DSMClient {
    public func storageOverview() async throws -> StorageOverview {
        try await call("SYNO.Storage.CGI.Storage", method: "load_info", version: 1)
    }
}
