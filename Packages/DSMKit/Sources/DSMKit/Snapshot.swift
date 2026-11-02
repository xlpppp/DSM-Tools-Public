import Foundation

/// One shared-folder snapshot from Snapshot Replication (`SYNO.Core.Share.Snapshot`).
public struct ShareSnapshot: Decodable, Identifiable, Hashable, Sendable {
    public let time: String
    public let description: String
    public let locked: Bool
    public let scheduled: Bool

    public var id: String { time }

    /// `GMT+08-2024.01.02-03.04.05` → `2024-01-02 03:04:05`.
    public var displayTime: String {
        let parts = time.split(separator: "-")
        guard parts.count >= 4 else { return time }
        let day = parts[1].replacingOccurrences(of: ".", with: "-")
        let clock = parts[2].replacingOccurrences(of: ".", with: ":")
        return "\(day) \(clock)"
    }

    enum CodingKeys: String, CodingKey { case time, desc, lock, schedule_snapshot }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(String.self, forKey: .time)
        description = try c.decodeIfPresent(String.self, forKey: .desc) ?? ""
        locked = try c.decodeIfPresent(Bool.self, forKey: .lock) ?? false
        scheduled = try c.decodeIfPresent(Bool.self, forKey: .schedule_snapshot) ?? false
    }
}

/// A replication plan (`SYNO.DR.Plan` list). Fields that differ between DSM builds stay optional.
public struct ReplicationPlan: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let source: String
    public let destination: String
    public let enabled: Bool
    public let lastSuccess: Bool?

    enum CodingKeys: String, CodingKey { case plan_id, id, additional }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .plan_id)
            ?? c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        let extra = try c.decodeIfPresent(Extra.self, forKey: .additional)
        source = extra?.main?.target_name ?? extra?.main?.hostname ?? "本地"
        let remote = extra?.dr?.target_name ?? ""
        let host = extra?.dr?.hostname ?? ""
        destination = [host, remote].filter { !$0.isEmpty }.joined(separator: " / ")
        enabled = extra?.policy?.enabled ?? true
        lastSuccess = extra?.last?.is_success
    }

    private struct Extra: Decodable {
        struct Site: Decodable { let hostname: String?; let target_name: String? }
        struct Policy: Decodable { let enabled: Bool? }
        struct Last: Decodable { let is_success: Bool? }
        let main_site_info: Site?
        let dr_site_info: Site?
        let sync_policy: Policy?
        let last_op_info: Last?
        var main: Site? { main_site_info }
        var dr: Site? { dr_site_info }
        var policy: Policy? { sync_policy }
        var last: Last? { last_op_info }
    }
}

/// Daily or hourly snapshot schedule sent to `SYNO.Core.Share.Snapshot` `set_schedule`.
public struct SnapshotSchedule: Sendable, Equatable {
    public var hour: Int
    public var minute: Int
    /// 0 keeps one snapshot a day. Greater than 0 repeats during the day.
    public var repeatHours: Int
    public var keep: Int

    public init(hour: Int = 3, minute: Int = 0, repeatHours: Int = 0, keep: Int = 256) {
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
        self.repeatHours = min(23, max(0, repeatHours))
        self.keep = min(1024, max(1, keep))
    }

    public var json: String {
        let body: [String: Any] = [
            "date_type": 0,
            "week_day": "0,1,2,3,4,5,6",
            "hour": hour,
            "min": minute,
            "repeat_hour": repeatHours,
            "repeat_min": 0,
            "last_work_hour": 23,
            "date": "2024/1/1",
            "repeat": 0,
            "max_snapshot": keep,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

extension DSMClient {
    public func shareSnapshots(_ share: String) async throws -> [ShareSnapshot] {
        struct R: Decodable { let snapshots: [ShareSnapshot]? }
        let r: R = try await call("SYNO.Core.Share.Snapshot", method: "list", version: 2, params: [
            "name": share,
            "additional": FSParam.strings(["desc", "lock", "schedule_snapshot"]),
            "offset": "0",
            "limit": "-1",
        ])
        return r.snapshots ?? []
    }

    public func createShareSnapshot(_ share: String, description: String = "") async throws {
        let info = ["desc": description, "lock": false] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: info)
        let _: EmptyData = try await call("SYNO.Core.Share.Snapshot", method: "create", version: 1, params: [
            "name": share,
            "snapinfo": String(data: data, encoding: .utf8) ?? "{}",
        ])
    }

    /// Puts the share back to this snapshot. The caller must already have asked the user to confirm.
    public func restoreShareSnapshot(_ share: String, time: String) async throws {
        let _: EmptyData = try await call("SYNO.Core.Share.Snapshot", method: "restore", version: 1, params: [
            "name": share,
            "snapshot": time,
        ])
    }

    public func setSnapshotSchedule(_ share: String, _ schedule: SnapshotSchedule) async throws {
        let _: EmptyData = try await call("SYNO.Core.Share.Snapshot", method: "set_schedule", version: 1, params: [
            "name": share,
            "enable": "true",
            "reserve": String(schedule.keep),
            "schedule": schedule.json,
        ])
    }

    public func replicationPlans() async throws -> [ReplicationPlan] {
        struct R: Decodable { let plans: [ReplicationPlan]? }
        let extra = ["sync_policy", "main_site_info", "dr_site_info", "last_op_info"]
        let r: R = try await call("SYNO.DR.Plan", method: "list", version: 1, params: [
            "additional": FSParam.strings(extra),
        ])
        return r.plans ?? []
    }

    public func syncReplication(_ planID: String) async throws {
        let _: EmptyData = try await call("SYNO.DR.Plan", method: "sync", version: 1, params: [
            "plan_id": planID,
            "nowait": "true",
            "auto_remove": "true",
            "is_snapshot_locked": "false",
            "sync_description": "NAS Helper",
        ])
    }

    /// Creates a share replication toward another DSM. The package rejects the call when the remote is not reachable.
    public func createReplication(sourceShare: String, host: String, port: Int, username: String,
                                  password: String, destinationShare: String, schedule: SnapshotSchedule) async throws {
        let plan: [String: Any] = [
            "sync_policy": [
                "enabled": true,
                "mode": 2,
                "schedule": [
                    "date_type": 0, "week_day": "0,1,2,3,4,5,6",
                    "hour": schedule.hour, "min": schedule.minute, "repeat_hour": schedule.repeatHours,
                ],
            ],
            "main_site_info": ["role": 1, "target_name": sourceShare],
            "dr_site_info": [
                "role": 2, "hostname": host, "port": port, "username": username,
                "password": password, "target_name": destinationShare,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: plan)
        let _: EmptyData = try await call("SYNO.DR.Plan", method: "create", version: 1, params: [
            "plan": String(data: data, encoding: .utf8) ?? "{}",
        ])
    }

    public func snapshotLogs() async throws -> [LogEntry] {
        if apis["SYNO.DR.Log"] != nil {
            struct R: Decodable { let logs: [LogEntry]?; let items: [LogEntry]? }
            if let r = try? await call("SYNO.DR.Log", method: "list", version: 1, params: [
                "offset": "0", "limit": "100",
            ]) as R {
                let rows = r.logs ?? r.items ?? []
                if !rows.isEmpty { return rows }
            }
        }
        let english = try await logs(category: .system, keyword: "Snapshot", limit: 100).entries
        if !english.isEmpty { return english }
        return try await logs(category: .system, keyword: "快照", limit: 100).entries
    }
}
