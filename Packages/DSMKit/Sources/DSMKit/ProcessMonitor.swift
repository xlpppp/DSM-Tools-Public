import Foundation

/// One row of SYNO.Core.System.Process `list` (Resource Monitor → Processes).
///
/// Field names and scaling are inferred from DSM 7.2's Resource Monitor and still
/// need checking on a real NAS, so decoding tries the likely spellings.
public struct SystemProcess: Sendable, Equatable, Identifiable {
    public let pid: Int
    public let command: String
    /// Raw status letter from `ps` (R, S, D, Z, T…).
    public let status: String
    public let cpuPercent: Double
    public let privateMemoryKB: Int
    public let sharedMemoryKB: Int

    public var id: Int { pid }

    public var statusLabel: String {
        switch status.uppercased().first {
        case "R", "S", "I": return "运行中"
        case "D": return "等待 I/O"
        case "T": return "已停止"
        case "Z": return "僵尸"
        default: return status.isEmpty ? "—" : status
        }
    }

    init?(_ json: JSONValue) {
        guard let pid = json.int(["pid"]) else { return nil }
        self.pid = pid
        command = json.text(["command", "name", "cmd"]) ?? "pid \(pid)"
        status = json.text(["status", "state"]) ?? ""
        cpuPercent = json.permille(["cpu", "cpu_usage", "cpu_utilization"]) ?? 0
        privateMemoryKB = json.int(["mem", "memory", "mem_private"]) ?? 0
        sharedMemoryKB = json.int(["mem_shared", "shared_mem", "share"]) ?? 0
    }
}

/// One row of SYNO.Core.System.ProcessGroup `list` (Resource Monitor → Services):
/// a package or system service with its processes summed.
public struct ServiceUsage: Sendable, Equatable, Identifiable {
    public let name: String
    public let cpuPercent: Double
    /// Accumulated CPU time in seconds.
    public let cpuTimeSeconds: Int?
    public let memoryKB: Int
    public let processCount: Int

    public var id: String { name }

    init?(_ json: JSONValue) {
        guard let name = json.text(["display_name", "displayname", "name", "slice", "id"]), !name.isEmpty else { return nil }
        self.name = name
        cpuPercent = json.permille(["cpu_utilization", "cpu", "cpu_usage"]) ?? 0
        cpuTimeSeconds = json.int(["cpu_time", "cputime"])
        memoryKB = json.int(["memory", "mem", "memory_usage"]) ?? 0
        processCount = json["pids"]?.array?.count ?? json["processes"]?.array?.count ?? 0
    }
}

extension DSMClient {
    public func processes() async throws -> [SystemProcess] {
        let data: JSONValue = try await call("SYNO.Core.System.Process", method: "list", version: 1)
        return data.rows(["process", "processes", "items"]).compactMap(SystemProcess.init)
            .sorted { $0.cpuPercent > $1.cpuPercent }
    }

    public func serviceUsage() async throws -> [ServiceUsage] {
        let data: JSONValue = try await call("SYNO.Core.System.ProcessGroup", method: "list", version: 1)
        return data.rows(["process_group", "groups", "slice", "slices", "items"]).compactMap(ServiceUsage.init)
            .sorted { ($0.cpuPercent, $0.memoryKB) > ($1.cpuPercent, $1.memoryKB) }
    }
}

extension JSONValue {
    /// The list under the first matching key, or the first array found, or self if it is an array.
    func rows(_ keys: [String]) -> [JSONValue] {
        if let a = array { return a }
        for key in keys { if let a = self[key]?.array { return a } }
        if case .object(let o) = self {
            for key in o.keys.sorted() { if let a = o[key]?.array { return a } }
        }
        return []
    }

    func first(_ keys: [String]) -> JSONValue? {
        for key in keys { if let v = self[key], v != .null { return v } }
        return nil
    }

    func text(_ keys: [String]) -> String? { first(keys)?.string }

    func int(_ keys: [String]) -> Int? {
        guard let v = first(keys) else { return nil }
        switch v {
        case .number(let n): return Int(n)
        case .string(let s):
            if let i = Int(s) { return i }
            if let d = Double(s) { return Int(d) }
            return Self.clockSeconds(s)
        default: return nil
        }
    }

    /// DSM reports per-process CPU as an integer in tenths of a percent (71 = 7.1%).
    /// A fractional number is taken as a percent already.
    func permille(_ keys: [String]) -> Double? {
        guard let v = first(keys) else { return nil }
        switch v {
        case .number(let n): return n.rounded() == n ? n / 10 : n
        case .string(let s):
            guard let d = Double(s) else { return nil }
            return s.contains(".") ? d : d / 10
        default: return nil
        }
    }

    /// "HH:MM:SS" or "MM:SS" to seconds.
    static func clockSeconds(_ s: String) -> Int? {
        let parts = s.split(separator: ":").map { Int($0) }
        guard parts.count >= 2, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + ($1 ?? 0) }
    }
}
