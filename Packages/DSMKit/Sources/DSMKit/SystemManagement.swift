import Foundation

// MARK: Users and groups (SYNO.Core.User / SYNO.Core.Group)

public struct NASUser: Decodable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String?
    public let email: String?
    /// "normal", "now" (disabled) or an expiry date.
    public let expired: String

    public var isDisabled: Bool { expired == "now" }
    public var isSystem: Bool { ["admin", "guest"].contains(name) }

    enum CodingKeys: String, CodingKey { case name, description, email, expired }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)?.nilIfEmpty
        email = try c.decodeIfPresent(String.self, forKey: .email)?.nilIfEmpty
        expired = (try? c.decodeIfPresent(FlexString.self, forKey: .expired))??.value ?? "normal"
    }
}

public struct NASGroup: Decodable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String?
}

// MARK: Current connections (SYNO.Core.CurrentConnection)

public struct NASConnection: Decodable, Identifiable, Hashable, Sendable {
    public var id: String { "\(who)|\(from)|\(type)|\(pid)" }
    public let who: String
    public let from: String
    /// e.g. "HTTP/HTTPS", "SMB", "AFP", "FTP".
    public let type: String
    public let description: String?
    public let time: String
    public let pid: Int
    public let canKick: Bool

    enum CodingKeys: String, CodingKey { case who, from, type, descr, time, pid, can_be_kicked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        who = try c.decodeIfPresent(String.self, forKey: .who) ?? ""
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .descr)?.nilIfEmpty
        time = (try? c.decodeIfPresent(FlexString.self, forKey: .time))??.value ?? ""
        pid = (try? c.decodeIfPresent(FlexInt.self, forKey: .pid))??.value ?? 0
        canKick = (try? c.decodeIfPresent(Bool.self, forKey: .can_be_kicked)) ?? false
    }
}

// MARK: Network (SYNO.Core.System info type=network)

public struct NetworkInterface: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let address: String
    public let mask: String
    public let mac: String
    public let type: String
    public let ipv6: [String]

    enum CodingKeys: String, CodingKey { case id, addr, mask, mac, type, ipv6 }
    struct V6: Decodable { let addr: String?; let prefix_length: FlexInt? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        address = try c.decodeIfPresent(String.self, forKey: .addr) ?? ""
        mask = try c.decodeIfPresent(String.self, forKey: .mask) ?? ""
        mac = try c.decodeIfPresent(String.self, forKey: .mac) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        let v6 = (try? c.decodeIfPresent([V6].self, forKey: .ipv6)) ?? nil
        ipv6 = (v6 ?? []).compactMap { v in
            v.addr.map { a in v.prefix_length.map { "\(a)/\($0.value)" } ?? a }
        }
    }
}

public struct NetworkSummary: Decodable, Hashable, Sendable {
    public let hostname: String
    public let gateway: String
    public let dns: String
    public let workgroup: String?
    public let interfaces: [NetworkInterface]

    enum CodingKeys: String, CodingKey { case hostname, gateway, dns, workgroup, nif }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        gateway = try c.decodeIfPresent(String.self, forKey: .gateway) ?? ""
        dns = try c.decodeIfPresent(String.self, forKey: .dns) ?? ""
        workgroup = try c.decodeIfPresent(String.self, forKey: .workgroup)?.nilIfEmpty
        interfaces = try c.decodeIfPresent([NetworkInterface].self, forKey: .nif) ?? []
    }
}

// MARK: File services

public enum FileService: String, CaseIterable, Identifiable, Sendable {
    case smb, afp, nfs, ftp, ftps, sftp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .smb: return "SMB"
        case .afp: return "AFP"
        case .nfs: return "NFS"
        case .ftp: return "FTP"
        case .ftps: return "FTPS"
        case .sftp: return "SFTP"
        }
    }

    public var summary: String {
        switch self {
        case .smb: return "Windows / macOS 网络共享"
        case .afp: return "旧版 macOS 共享（DSM 7 已不推荐）"
        case .nfs: return "Linux / ESXi 挂载"
        case .ftp: return "未加密的 FTP，仅建议局域网使用"
        case .ftps: return "TLS 加密的 FTP"
        case .sftp: return "基于 SSH 的文件传输"
        }
    }

    var api: String {
        switch self {
        case .smb: return "SYNO.Core.FileServ.SMB"
        case .afp: return "SYNO.Core.FileServ.AFP"
        case .nfs: return "SYNO.Core.FileServ.NFS"
        case .ftp, .ftps: return "SYNO.Core.FileServ.FTP"
        case .sftp: return "SYNO.Core.FileServ.FTP.SFTP"
        }
    }

    var version: Int {
        switch self {
        case .smb, .ftp, .ftps: return 3
        case .nfs: return 2
        case .afp, .sftp: return 1
        }
    }

    var enableKey: String {
        switch self {
        case .smb: return "enable_samba"
        case .afp: return "enable_afp"
        case .nfs: return "enable_nfs"
        case .ftp: return "enable_ftp"
        case .ftps: return "enable_ftps"
        case .sftp: return "enable"
        }
    }
}

public struct FileServiceState: Identifiable, Hashable, Sendable {
    public var id: FileService { service }
    public let service: FileService
    public let enabled: Bool
    public let port: Int?
    public let detail: String?
}

// MARK: Task scheduler (SYNO.Core.TaskScheduler)

public struct ScheduledTask: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let enabled: Bool
    public let owner: String
    public let type: String
    public let action: String?
    public let nextRun: String?

    public var typeLabel: String {
        switch type {
        case "script": return "用户脚本"
        case "beep": return "蜂鸣"
        case "service": return "服务"
        case "recycle": return "清空回收站"
        default: return type.isEmpty ? "任务" : type
        }
    }

    enum CodingKeys: String, CodingKey { case id, name, enable, owner, real_owner, type, action, next_trigger_time }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexInt.self, forKey: .id).value
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enable)) ?? false
        owner = try c.decodeIfPresent(String.self, forKey: .real_owner) ?? c.decodeIfPresent(String.self, forKey: .owner) ?? "root"
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action)?.nilIfEmpty
        nextRun = (try? c.decodeIfPresent(FlexString.self, forKey: .next_trigger_time))??.value.nilIfEmpty
    }
}

extension DSMClient {
    // MARK: Users

    public func users() async throws -> [NASUser] {
        struct R: Decodable { let users: [NASUser] }
        let r: R = try await call("SYNO.Core.User", method: "list", version: 1, params: [
            "type": "local", "offset": "0", "limit": "-1",
            "additional": FSParam.strings(["email", "description", "expired"]),
        ])
        return r.users
    }

    public func groups() async throws -> [NASGroup] {
        struct R: Decodable { let groups: [NASGroup] }
        let r: R = try await call("SYNO.Core.Group", method: "list", version: 1, params: [
            "type": "local", "offset": "0", "limit": "-1", "additional": FSParam.strings(["description"]),
        ])
        return r.groups
    }

    /// Disabling a user signs them out everywhere. Callers confirm first.
    public func setUserDisabled(_ name: String, _ disabled: Bool) async throws {
        let _: EmptyData = try await call("SYNO.Core.User", method: "set", version: 1, params: [
            "name": name, "expired": disabled ? "now" : "normal",
        ])
    }

    public func createUser(name: String, password: String, description: String = "", email: String = "") async throws {
        let _: EmptyData = try await call("SYNO.Core.User", method: "create", version: 1, params: [
            "name": name, "password": password, "description": description, "email": email,
            "cannot_chg_passwd": "false", "expired": "normal",
        ])
    }

    public func deleteUser(_ name: String) async throws {
        let _: EmptyData = try await call("SYNO.Core.User", method: "delete", version: 1, params: [
            "name": FSParam.strings([name]),
        ])
    }

    // MARK: Connections

    public func connections() async throws -> [NASConnection] {
        struct R: Decodable { let items: [NASConnection] }
        let r: R = try await call("SYNO.Core.CurrentConnection", method: "list", version: 1, params: [
            "offset": "0", "limit": "200", "sort_by": "time", "sort_direction": "DESC",
        ])
        return r.items
    }

    public func kick(_ connection: NASConnection) async throws {
        struct Item: Encodable { let who: String; let from: String; let type: String; let pid: Int }
        let json = String(data: try JSONEncoder().encode([Item(who: connection.who, from: connection.from,
                                                               type: connection.type, pid: connection.pid)]),
                          encoding: .utf8) ?? "[]"
        let _: EmptyData = try await call("SYNO.Core.CurrentConnection", method: "kick", version: 1, params: [
            "connection": json,
        ])
    }

    // MARK: Network

    public func network() async throws -> NetworkSummary {
        try await call("SYNO.Core.System", method: "info", version: 1, params: ["type": "network"])
    }

    // MARK: File services

    /// Services the NAS reports; ones whose API is missing (e.g. AFP on newer DSM) are skipped.
    public func fileServices() async throws -> [FileServiceState] {
        var raw: [String: JSONValue] = [:]
        for api in Set(FileService.allCases.map(\.api)) where supports(api) {
            let service = FileService.allCases.first { $0.api == api }!
            if let value: JSONValue = try? await call(api, method: "get", version: service.version) {
                raw[api] = value
            }
        }
        return FileService.allCases.compactMap { service in
            guard let v = raw[service.api] else { return nil }
            let port = v["portnum"]?.int64.map(Int.init) ?? v["port"]?.int64.map(Int.init)
            var detail: String?
            switch service {
            case .smb: detail = v["workgroup"]?.string.map { "工作组：\($0)" }
            case .nfs: detail = (v["enable_nfs_v4"]?.bool ?? v["nfs_v4_enable"]?.bool) == true ? "已启用 NFSv4" : nil
            default: break
            }
            return FileServiceState(service: service, enabled: v[service.enableKey]?.bool ?? false,
                                    port: service == .ftps ? nil : port, detail: detail)
        }
    }

    /// Turns a file service on or off. Callers confirm first; turning SMB off disconnects users.
    public func setFileService(_ service: FileService, enabled: Bool) async throws {
        let _: EmptyData = try await call(service.api, method: "set", version: service.version, params: [
            service.enableKey: FSParam.bool(enabled),
        ])
    }

    // MARK: Task scheduler

    public func scheduledTasks() async throws -> [ScheduledTask] {
        struct R: Decodable { let tasks: [ScheduledTask] }
        let r: R = try await call("SYNO.Core.TaskScheduler", method: "list", version: 3, params: [
            "offset": "0", "limit": "200", "sort_by": "next_trigger_time", "sort_direction": "ASC",
        ])
        return r.tasks
    }

    public func runTask(_ task: ScheduledTask) async throws {
        let _: EmptyData = try await call("SYNO.Core.TaskScheduler", method: "run", version: 1, params: [
            "tasks": #"[{"id":\#(task.id),"real_owner":\#(FSParam.string(task.owner))}]"#,
        ])
    }

    public func setTaskEnabled(_ task: ScheduledTask, _ enabled: Bool) async throws {
        let _: EmptyData = try await call("SYNO.Core.TaskScheduler", method: "set_enable", version: 2, params: [
            "status": #"[{"id":\#(task.id),"real_owner":\#(FSParam.string(task.owner)),"enable":\#(enabled)}]"#,
        ])
    }
}

// MARK: Terminal (SYNO.Core.Terminal), Control Panel › Terminal & SNMP

public struct TerminalSettings: Decodable, Hashable, Sendable {
    public let sshEnabled: Bool
    public let sshPort: Int?

    enum CodingKeys: String, CodingKey { case enable_ssh, ssh_port }

    public init(sshEnabled: Bool, sshPort: Int?) {
        self.sshEnabled = sshEnabled
        self.sshPort = sshPort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let flag = try? c.decode(Bool.self, forKey: .enable_ssh) {
            sshEnabled = flag
        } else if let flag = try? c.decode(FlexInt.self, forKey: .enable_ssh) {
            sshEnabled = flag.value != 0
        } else {
            sshEnabled = false
        }
        let port = (try? c.decode(FlexInt.self, forKey: .ssh_port))?.value ?? 0
        sshPort = port > 0 ? port : nil
    }
}

extension DSMClient {
    /// Whether SSH is on and which port sshd listens on, as set in DSM. Needs an admin account.
    public func terminalSettings() async throws -> TerminalSettings {
        try await call("SYNO.Core.Terminal", method: "get", version: 3)
    }
}

// MARK: SSH target

/// Where to open SSH, worked out from the device's SSH settings, the address DSM is reached on
/// and the port DSM reports. Kept here so it can be tested without a NAS.
public struct SSHTarget: Hashable, Sendable {
    public let host: String
    public let port: Int

    public var display: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Accepts what people paste into an address field: "nas.example.com", "ssh://admin@nas:2222",
    /// "192.0.2.10:2222", "[fe80::1]:2222". Returns the bare host and a port if one was given.
    public static func parse(_ text: String) -> (host: String, port: Int?) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
            return (host, port)
        }
        // A single colon separates the port; more than one is a bare IPv6 address.
        if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
            return (String(s[..<colon]), Int(s[s.index(after: colon)...]))
        }
        return (s, nil)
    }

    /// Hosts to try, best first. Explicit LAN and WAN SSH addresses come first, LAN before WAN.
    /// A legacy single host is the only candidate when those are empty. Otherwise the address DSM
    /// is connected on comes first, then the device's other addresses, skipping QuickConnect IDs
    /// and relays, which only carry DSM's web traffic.
    /// Port: a port typed into the host field wins. An explicit LAN or WAN address uses the
    /// port in that field, including 22. Only the fallback that reuses DSM's own addresses
    /// replaces 22 with the port DSM reports.
    public static func candidates(settings: SSHSettings, current: Endpoint?, endpoints: [Endpoint],
                                  reportedPort: Int?) -> [SSHTarget] {
        let sides = [target(settings.lanHost, port: settings.lanPort),
                     target(settings.wanHost, port: settings.wanPort)].compactMap { $0 }
        if !sides.isEmpty { return sides }
        if let single = target(settings.host, port: settings.port, reportedPort: reportedPort) { return [single] }
        let port = settings.port != 22 ? settings.port : (reportedPort ?? 22)
        var hosts: [String] = []
        for endpoint in [current].compactMap({ $0 }) + endpoints where endpoint.kind != .quickConnect {
            let host = endpoint.host.trimmingCharacters(in: .whitespaces)
            if !host.isEmpty && !hosts.contains(host) { hosts.append(host) }
        }
        return hosts.map { SSHTarget(host: $0, port: port) }
    }

    private static func target(_ text: String, port configured: Int, reportedPort: Int? = nil) -> SSHTarget? {
        let parsed = parse(text)
        guard !parsed.host.isEmpty else { return nil }
        let port = parsed.port ?? reportedPort.flatMap { configured == 22 ? $0 : nil } ?? configured
        return SSHTarget(host: parsed.host, port: port)
    }
}
