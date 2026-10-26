import Foundation

// MARK: Power schedule (SYNO.Core.Hardware.PowerSchedule)
//
// Inferred from the DSM 7 control panel (Hardware & Power › Power Schedule); not yet verified
// on a real NAS. load returns { poweron_tasks: [...], poweroff_tasks: [...] }, each task
// { enabled, hour, min, weekdays: "0,1,…,6" } with 0 = Sunday. save takes both lists back as JSON.

public struct PowerTask: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var enabled: Bool
    public var hour: Int
    public var minute: Int
    /// 0 = Sunday … 6 = Saturday.
    public var weekdays: Set<Int>

    public init(enabled: Bool = true, hour: Int = 8, minute: Int = 0, weekdays: Set<Int> = Set(0...6)) {
        self.enabled = enabled
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
    }

    enum CodingKeys: String, CodingKey { case enabled, hour, min, weekdays }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil)
            ?? (((try? c.decodeIfPresent(FlexInt.self, forKey: .enabled)) ?? nil)?.value ?? 0 != 0)
        hour = ((try? c.decodeIfPresent(FlexInt.self, forKey: .hour)) ?? nil)?.value ?? 0
        minute = ((try? c.decodeIfPresent(FlexInt.self, forKey: .min)) ?? nil)?.value ?? 0
        let raw = ((try? c.decodeIfPresent(FlexString.self, forKey: .weekdays)) ?? nil)?.value ?? ""
        weekdays = Set(raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { (0...6).contains($0) })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(hour, forKey: .hour)
        try c.encode(minute, forKey: .min)
        try c.encode(weekdays.sorted().map(String.init).joined(separator: ","), forKey: .weekdays)
    }

    /// e.g. "每天 08:00", "工作日 23:30", "周一、周三 07:00".
    public var summary: String {
        String(format: "%@ %02d:%02d", Self.describe(weekdays), hour, minute)
    }

    public static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    public static func describe(_ days: Set<Int>) -> String {
        if days.count == 7 { return "每天" }
        if days == Set(1...5) { return "工作日" }
        if days == [0, 6] { return "周末" }
        if days.isEmpty { return "未选日期" }
        return days.sorted().map { weekdayNames[$0] }.joined(separator: "、")
    }
}

public struct PowerSchedule: Hashable, Sendable {
    public var powerOn: [PowerTask]
    public var powerOff: [PowerTask]

    public init(powerOn: [PowerTask] = [], powerOff: [PowerTask] = []) {
        self.powerOn = powerOn
        self.powerOff = powerOff
    }
}

extension DSMClient {
    public func powerSchedule() async throws -> PowerSchedule {
        struct R: Decodable { let poweron_tasks: [PowerTask]?; let poweroff_tasks: [PowerTask]? }
        let r: R = try await call("SYNO.Core.Hardware.PowerSchedule", method: "load", version: 1)
        return PowerSchedule(powerOn: r.poweron_tasks ?? [], powerOff: r.poweroff_tasks ?? [])
    }

    /// Replaces the whole schedule. Callers confirm first: a wrong power-off time shuts the NAS down.
    public func savePowerSchedule(_ schedule: PowerSchedule) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json(_ tasks: [PowerTask]) throws -> String {
            String(data: try encoder.encode(tasks), encoding: .utf8) ?? "[]"
        }
        let _: EmptyData = try await call("SYNO.Core.Hardware.PowerSchedule", method: "save", version: 1, params: [
            "poweron_tasks": try json(schedule.powerOn),
            "poweroff_tasks": try json(schedule.powerOff),
        ])
    }
}
