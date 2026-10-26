import Foundation

/// A Virtual Machine Manager guest (SYNO.Virtualization.API.Guest, Synology's documented VMM API).
public struct VirtualMachine: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let vcpus: Int?
    /// Memory in MB.
    public let memoryMB: Int?
    public let autorun: Bool?
    public let description: String?
    public let disks: [Disk]
    public let nics: [NIC]

    public struct Disk: Decodable, Hashable, Sendable {
        public let sizeMB: Int?
        enum CodingKeys: String, CodingKey { case vdisk_size }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sizeMB = (try? c.decodeIfPresent(FlexInt.self, forKey: .vdisk_size))??.value
        }
    }

    public struct NIC: Decodable, Hashable, Sendable {
        public let mac: String?
        public let model: String?
        enum CodingKeys: String, CodingKey { case mac, model }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mac = try c.decodeIfPresent(String.self, forKey: .mac)
            model = (try? c.decodeIfPresent(FlexString.self, forKey: .model))??.value
        }
    }

    public var isRunning: Bool { status == "running" }

    public var statusLabel: String {
        switch status {
        case "running": return "运行中"
        case "shutdown", "stopped", "inactive": return "已关机"
        case "booting": return "启动中"
        case "shutting_down", "stopping": return "关机中"
        case "paused", "suspended": return "已暂停"
        case "moving", "migrating": return "迁移中"
        case "crashed", "error": return "异常"
        default: return status
        }
    }

    enum CodingKeys: String, CodingKey { case guest_id, guest_name, status, vcpu_num, vram_size, autorun, description, vdisks, vnics }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexString.self, forKey: .guest_id).value
        name = try c.decodeIfPresent(String.self, forKey: .guest_name) ?? id
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        vcpus = (try? c.decodeIfPresent(FlexInt.self, forKey: .vcpu_num))??.value
        memoryMB = (try? c.decodeIfPresent(FlexInt.self, forKey: .vram_size))??.value
        let run: FlexInt? = (try? c.decodeIfPresent(FlexInt.self, forKey: .autorun)) ?? nil
        autorun = run.map { $0.value != 0 }
        description = try c.decodeIfPresent(String.self, forKey: .description)?.nilIfEmpty
        disks = (try? c.decodeIfPresent([Disk].self, forKey: .vdisks)) ?? nil ?? []
        nics = (try? c.decodeIfPresent([NIC].self, forKey: .vnics)) ?? nil ?? []
    }
}

extension DSMClient {
    public var hasVirtualMachineManager: Bool { supports("SYNO.Virtualization.API.Guest") }

    public func virtualMachines() async throws -> [VirtualMachine] {
        struct R: Decodable { let guests: [VirtualMachine] }
        let r: R = try await call("SYNO.Virtualization.API.Guest", method: "list", version: 1, params: [
            "additional": "true",
        ])
        return r.guests.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func powerOnVM(_ id: String) async throws { try await vmAction("poweron", id) }
    /// Asks the guest OS to shut down (ACPI).
    public func shutdownVM(_ id: String) async throws { try await vmAction("shutdown", id) }
    /// Cuts power immediately, like pulling the plug.
    public func powerOffVM(_ id: String) async throws { try await vmAction("poweroff", id) }

    private func vmAction(_ method: String, _ id: String) async throws {
        let _: EmptyData = try await call("SYNO.Virtualization.API.Guest.Action", method: method, version: 1, params: [
            "guest_id": id,
        ])
    }

    /// Opens DSM's web desktop with Virtual Machine Manager, whose console (noVNC) runs in a browser.
    nonisolated public func vmManagerURL() -> URL? {
        guard var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        if c.path.isEmpty { c.path = "/" }
        c.queryItems = [URLQueryItem(name: "launchApp", value: "SYNO.SDS.Virtualization.Application")]
        return c.url
    }

    /// Session id for handing the login to an embedded web view. Never log or persist it.
    public var sessionID: String? { session?.sid }
}
