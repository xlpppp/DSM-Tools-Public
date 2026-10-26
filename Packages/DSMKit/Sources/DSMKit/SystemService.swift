import Foundation

/// Device facts from SYNO.Core.System `info`.
public struct SystemInfo: Decodable, Sendable, Equatable {
    public let model: String?
    public let serial: String?
    public let firmwareVersion: String?
    public let upTime: String?
    public let cpuVendor: String?
    public let cpuSeries: String?
    public let cpuClockMHz: Int?
    public let cpuCores: Int?
    public let ramMB: Int?
    public let temperature: Int?
    public let temperatureWarning: Bool?
    public let systemTime: String?

    enum CodingKeys: String, CodingKey {
        case model, serial, firmware_ver, up_time, cpu_vendor, cpu_series, cpu_family, cpu_clock_speed,
             cpu_cores, ram_size, sys_temp, temperature_warning, time
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(FlexString.self, forKey: .model)?.value
        serial = try c.decodeIfPresent(FlexString.self, forKey: .serial)?.value
        firmwareVersion = try c.decodeIfPresent(FlexString.self, forKey: .firmware_ver)?.value
        upTime = try c.decodeIfPresent(FlexString.self, forKey: .up_time)?.value
        cpuVendor = try c.decodeIfPresent(FlexString.self, forKey: .cpu_vendor)?.value
        let series = try c.decodeIfPresent(FlexString.self, forKey: .cpu_series)?.value
        let family = try c.decodeIfPresent(FlexString.self, forKey: .cpu_family)?.value
        cpuSeries = [family, series].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ").nilIfEmpty
        cpuClockMHz = try c.decodeIfPresent(FlexInt.self, forKey: .cpu_clock_speed)?.value
        cpuCores = try c.decodeIfPresent(FlexInt.self, forKey: .cpu_cores)?.value
        ramMB = try c.decodeIfPresent(FlexInt.self, forKey: .ram_size)?.value
        temperature = try c.decodeIfPresent(FlexInt.self, forKey: .sys_temp)?.value
        temperatureWarning = try c.decodeIfPresent(Bool.self, forKey: .temperature_warning)
        systemTime = try c.decodeIfPresent(FlexString.self, forKey: .time)?.value
    }

    /// DSM reports uptime as "days:hours:minutes:seconds" (or "hours:minutes:seconds").
    public var upTimeDays: Int? {
        guard let parts = upTime?.split(separator: ":").compactMap({ Int($0) }), parts.count >= 3 else { return nil }
        return parts.count == 4 ? parts[0] : parts[0] / 24
    }
}

/// Live load from SYNO.Core.System.Utilization `get`.
public struct Utilization: Decodable, Sendable, Equatable {
    public let cpuPercent: Int
    public let cpuUser: Int
    public let cpuSystem: Int
    /// `other_load`; DSM's Resource Monitor shows it as I/O wait.
    public let cpuOther: Int
    public let load1: Double?
    public let load5: Double?
    public let load15: Double?
    public let memoryPercent: Int
    /// Installed RAM (`memory_size`); the gap to `memoryTotalKB` is reserved by the kernel.
    public let memorySizeKB: Int
    public let memoryTotalKB: Int
    public let memoryAvailableKB: Int
    public let memoryCachedKB: Int
    public let memoryBufferKB: Int
    public let swapPercent: Int
    public let swapTotalKB: Int
    public let networkRxBytesPerSec: Int
    public let networkTxBytesPerSec: Int
    /// Per-interface rates, without the synthetic "total" row.
    public let interfaces: [InterfaceRate]
    public let diskReadBytesPerSec: Int
    public let diskWriteBytesPerSec: Int
    public let diskUtilization: Int?

    public struct InterfaceRate: Sendable, Equatable, Identifiable {
        public let device: String
        public let rxBytesPerSec: Int
        public let txBytesPerSec: Int
        public var id: String { device }
    }

    /// Memory the system is actively using: neither free, buffers nor page cache.
    public var memoryUsedKB: Int {
        max(0, memoryTotalKB - memoryAvailableKB - memoryBufferKB - memoryCachedKB)
    }

    public var memoryReservedKB: Int { max(0, memorySizeKB - memoryTotalKB) }

    struct CPU: Decodable {
        let user_load: FlexInt?
        let system_load: FlexInt?
        let other_load: FlexInt?
        let load1: LoadAverage?
        let load5: LoadAverage?
        let load15: LoadAverage?

        enum CodingKeys: String, CodingKey {
            case user_load, system_load, other_load
            case load1 = "1min_load", load5 = "5min_load", load15 = "15min_load"
        }
    }
    struct Memory: Decodable {
        let real_usage: FlexInt?
        let memory_size: FlexInt?
        let total_real: FlexInt?
        let avail_real: FlexInt?
        let cached: FlexInt?
        let buffer: FlexInt?
        let swap_usage: FlexInt?
        let total_swap: FlexInt?
    }
    struct Net: Decodable {
        let device: String
        let rx: FlexInt?
        let tx: FlexInt?
    }
    struct Disk: Decodable {
        struct Total: Decodable {
            let read_byte: FlexInt?
            let write_byte: FlexInt?
            let utilization: FlexInt?
        }
        let total: Total?
    }
    enum CodingKeys: String, CodingKey { case cpu, memory, network, disk }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cpu = try c.decodeIfPresent(CPU.self, forKey: .cpu)
        let mem = try c.decodeIfPresent(Memory.self, forKey: .memory)
        let nets = (try? c.decodeIfPresent([Net].self, forKey: .network)) ?? []
        let disk = try? c.decodeIfPresent(Disk.self, forKey: .disk)

        cpuUser = cpu?.user_load?.value ?? 0
        cpuSystem = cpu?.system_load?.value ?? 0
        cpuOther = cpu?.other_load?.value ?? 0
        cpuPercent = min(100, cpuUser + cpuSystem + cpuOther)
        load1 = cpu?.load1?.value
        load5 = cpu?.load5?.value
        load15 = cpu?.load15?.value
        memoryPercent = mem?.real_usage?.value ?? 0
        memoryTotalKB = mem?.total_real?.value ?? 0
        memorySizeKB = max(mem?.memory_size?.value ?? 0, memoryTotalKB)
        memoryAvailableKB = mem?.avail_real?.value ?? 0
        memoryCachedKB = mem?.cached?.value ?? 0
        memoryBufferKB = mem?.buffer?.value ?? 0
        swapPercent = mem?.swap_usage?.value ?? 0
        swapTotalKB = mem?.total_swap?.value ?? 0
        // "total" is the sum over interfaces; fall back to adding them up.
        let total = nets.first { $0.device == "total" }
        let devices = nets.filter { $0.device != "total" }
        networkRxBytesPerSec = total?.rx?.value ?? devices.reduce(0) { $0 + ($1.rx?.value ?? 0) }
        networkTxBytesPerSec = total?.tx?.value ?? devices.reduce(0) { $0 + ($1.tx?.value ?? 0) }
        interfaces = devices.map { InterfaceRate(device: $0.device, rxBytesPerSec: $0.rx?.value ?? 0, txBytesPerSec: $0.tx?.value ?? 0) }
        diskReadBytesPerSec = disk?.total?.read_byte?.value ?? 0
        diskWriteBytesPerSec = disk?.total?.write_byte?.value ?? 0
        diskUtilization = disk?.total?.utilization?.value
    }
}

/// DSM sends load averages as integers scaled by 100 (87 = 0.87). A fractional
/// value is taken as already unscaled, in case a version sends it that way.
struct LoadAverage: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            value = Double(i) / 100
        } else if let d = try? c.decode(Double.self) {
            value = d
        } else if let s = try? c.decode(String.self), let d = Double(s) {
            value = s.contains(".") ? d : d / 100
        } else {
            throw DecodingError.typeMismatch(Double.self, .init(codingPath: decoder.codingPath, debugDescription: "not a load average"))
        }
    }
}

extension DSMClient {
    public func systemInfo() async throws -> SystemInfo {
        try await call("SYNO.Core.System", method: "info", version: 3)
    }

    public func utilization() async throws -> Utilization {
        try await call("SYNO.Core.System.Utilization", method: "get", version: 1)
    }

    /// Restarts the NAS. Callers must have confirmed with the user first.
    public func reboot() async throws {
        let _: EmptyData = try await call("SYNO.Core.System", method: "reboot", version: 1)
    }

    /// Shuts the NAS down. Callers must have confirmed with the user first.
    public func shutdown() async throws {
        let _: EmptyData = try await call("SYNO.Core.System", method: "shutdown", version: 1)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
