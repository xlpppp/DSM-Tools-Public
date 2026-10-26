import Foundation

/// One line from Log Center (SYNO.Core.SyslogClient.Log).
public struct LogEntry: Decodable, Identifiable, Hashable, Sendable {
    public enum Level: String, Sendable, CaseIterable {
        case info, warning, error

        public var label: String {
            switch self {
            case .info: return "信息"
            case .warning: return "警告"
            case .error: return "错误"
            }
        }

        /// Value of the `level` filter DSM expects.
        var queryValue: String {
            switch self {
            case .info: return "info"
            case .warning: return "warn"
            case .error: return "err"
            }
        }

        init(raw: String?) {
            switch raw?.lowercased() {
            case "warn", "warning", "notice": self = .warning
            case "err", "error", "crit", "critical", "alert", "emerg": self = .error
            default: self = .info
            }
        }
    }

    public let level: Level
    public let time: Date?
    public let rawTime: String
    public let user: String?
    public let category: String?
    public let message: String

    public var id: String { "\(rawTime)|\(category ?? "")|\(message)" }

    enum CodingKeys: String, CodingKey { case level, time, who, logtype, orginalLogType, descr, msg }

    public init(level: Level, time: Date?, rawTime: String = "", user: String? = nil, category: String? = nil, message: String) {
        self.level = level
        self.time = time
        self.rawTime = rawTime
        self.user = user
        self.category = category
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = Level(raw: try c.decodeIfPresent(String.self, forKey: .level))
        rawTime = try c.decodeIfPresent(FlexString.self, forKey: .time)?.value ?? ""
        time = Self.parseTime(rawTime)
        user = try c.decodeIfPresent(String.self, forKey: .who)?.nilIfEmpty
        category = try (c.decodeIfPresent(String.self, forKey: .orginalLogType) ?? c.decodeIfPresent(String.self, forKey: .logtype))?.nilIfEmpty
        message = try (c.decodeIfPresent(String.self, forKey: .descr) ?? c.decodeIfPresent(String.self, forKey: .msg)) ?? ""
    }

    /// DSM sends "2024/05/01 08:30:12" in the NAS's local time, or a Unix timestamp.
    static func parseTime(_ raw: String) -> Date? {
        if let seconds = TimeInterval(raw), seconds > 1_000_000_000 { return Date(timeIntervalSince1970: seconds) }
        for format in ["yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }
}

/// Log Center's built-in log groups.
public enum LogCategory: String, CaseIterable, Sendable {
    case system, connection, fileTransfer

    public var label: String {
        switch self {
        case .system: return "常规"
        case .connection: return "连接"
        case .fileTransfer: return "文件传输"
        }
    }

    var queryValue: String {
        switch self {
        case .system: return "system,netbackup"
        case .connection: return "connection"
        case .fileTransfer: return "ftp,filestation,webdav,cifs,tftp,afp"
        }
    }
}

public struct LogPage: Sendable {
    public let entries: [LogEntry]
    public let total: Int
    public let warningCount: Int?
    public let errorCount: Int?
}

extension DSMClient {
    public func logs(category: LogCategory = .system, level: LogEntry.Level? = nil, keyword: String = "",
                     offset: Int = 0, limit: Int = 50) async throws -> LogPage {
        struct R: Decodable {
            let items: [LogEntry]?
            let total: FlexInt?
            let warnCount: FlexInt?
            let errorCount: FlexInt?
        }
        let r: R = try await call("SYNO.Core.SyslogClient.Log", method: "list", version: 1, params: [
            "start": String(offset),
            "limit": String(limit),
            "target": "LOCAL",
            "dir": "desc",
            "logtype": category.queryValue,
            "level": level?.queryValue ?? "",
            "keyword": keyword,
            "date_from": "0",
            "date_to": "0",
        ])
        let items = r.items ?? []
        return LogPage(entries: items, total: r.total?.value ?? items.count,
                       warningCount: r.warnCount?.value, errorCount: r.errorCount?.value)
    }
}

/// Something on a NAS that needs attention: a failing disk, a degraded volume, a new error log.
public struct HealthAlert: Identifiable, Hashable, Sendable {
    public enum Severity: Int, Sendable, Comparable {
        case warning, critical
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String
    public let date: Date?
}

extension DSMClient {
    /// Read-only scan used by the alert screen and background checks.
    /// Logs only count when newer than `since`, so repeated scans don't re-alert.
    public func scanHealth(since: Date?) async -> [HealthAlert] {
        var alerts: [HealthAlert] = []
        if let storage = try? await storageOverview() {
            for disk in storage.unhealthyDisks {
                alerts.append(HealthAlert(id: "disk-\(disk.id)", severity: .critical,
                                          title: "硬盘异常：\(disk.name ?? disk.id)",
                                          detail: "状态：\(StorageStatus.label(disk.status))，S.M.A.R.T.：\(StorageStatus.label(disk.smartStatus))",
                                          date: nil))
            }
            for pool in storage.pools where !StorageStatus.isNormal(pool.status) {
                alerts.append(HealthAlert(id: "pool-\(pool.id)", severity: pool.status == "attention" ? .warning : .critical,
                                          title: "\(pool.name)：\(StorageStatus.label(pool.status))",
                                          detail: "\(pool.raidLabel)，请在 DSM 存储管理器中查看原因", date: nil))
            }
            for volume in storage.volumes where !StorageStatus.isNormal(volume.status) {
                alerts.append(HealthAlert(id: "volume-\(volume.id)", severity: volume.status == "attention" ? .warning : .critical,
                                          title: "\(StorageStatus.volumeName(volume.name))：\(StorageStatus.label(volume.status))",
                                          detail: "请在 DSM 存储管理器中查看原因", date: nil))
            }
            for volume in storage.volumes where volume.totalBytes > 0 && Double(volume.usedBytes) / Double(volume.totalBytes) >= 0.9 {
                let percent = Int(Double(volume.usedBytes) / Double(volume.totalBytes) * 100)
                alerts.append(HealthAlert(id: "full-\(volume.id)", severity: .warning,
                                          title: "\(StorageStatus.volumeName(volume.name)) 已用 \(percent)%",
                                          detail: "可用空间不足 10%", date: nil))
            }
        }
        if let page = try? await logs(category: .system, level: .error, limit: 20) {
            for entry in page.entries where since == nil || (entry.time ?? .distantPast) > since! {
                alerts.append(HealthAlert(id: "log-\(entry.id)", severity: .warning, title: "错误日志",
                                          detail: entry.message, date: entry.time))
            }
        }
        return alerts.sorted { $0.severity > $1.severity }
    }
}
