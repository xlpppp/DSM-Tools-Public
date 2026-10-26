import Foundation

// Cloud Sync (SYNO.CloudSync). Synology does not document this API; method names and
// payloads follow the community client N4S4/synology-api (cloud_sync.py) and are
// inferred until checked against a DSM 7.2 NAS.

/// Sync state shared by connections and their tasks ("uptodate", "syncing", ...).
public enum CloudSyncStatus: String, Sendable {
    case uptodate, syncing, paused, preparing, error, unlinked, unknown

    init(raw: String?) {
        switch raw?.lowercased() ?? "" {
        case "uptodate", "up_to_date", "done": self = .uptodate
        case "syncing", "uploading", "downloading", "processing": self = .syncing
        case "pause", "paused": self = .paused
        case "prepare", "preparing", "waiting", "init": self = .preparing
        case "error", "failed", "fail": self = .error
        case "unlink", "unlinked", "relink", "auth_failed": self = .unlinked
        default: self = .unknown
        }
    }

    public var label: String {
        switch self {
        case .uptodate: return "已同步"
        case .syncing: return "同步中"
        case .paused: return "已暂停"
        case .preparing: return "准备中"
        case .error: return "出错"
        case .unlinked: return "连接断开"
        case .unknown: return "未知"
        }
    }
}

/// One cloud account linked in Cloud Sync (list_conn → conn[]).
public struct CloudSyncConnection: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    /// Provider code such as "db" (Dropbox), "od_v1" (OneDrive), "gd" (Google Drive).
    public let type: String
    public let status: CloudSyncStatus
    /// 1 = linked; anything else means the token needs re-authorising on the NAS.
    public let linked: Bool
    public let unfinishedFiles: Int
    public let userName: String?

    public var provider: String { CloudSyncConnection.providerName(type) ?? name }

    enum CodingKeys: String, CodingKey {
        case id, type, status, link_status, task_display_name, task_name, unfinished_files, user_name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexInt.self, forKey: .id).value
        type = try c.decodeIfPresent(FlexString.self, forKey: .type)?.value ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .task_display_name)
            ?? c.decodeIfPresent(String.self, forKey: .task_name) ?? type
        let link = try c.decodeIfPresent(FlexInt.self, forKey: .link_status)?.value ?? 1
        linked = link == 1
        let raw = try c.decodeIfPresent(FlexString.self, forKey: .status)?.value
        status = linked ? CloudSyncStatus(raw: raw) : .unlinked
        unfinishedFiles = try c.decodeIfPresent(FlexInt.self, forKey: .unfinished_files)?.value ?? 0
        userName = try c.decodeIfPresent(String.self, forKey: .user_name)
    }

    /// Display names for the common provider codes; nil falls back to DSM's own name.
    static func providerName(_ code: String) -> String? {
        let base = code.split(separator: "_").first.map(String.init) ?? code
        switch base {
        case "db": return "Dropbox"
        case "od": return "OneDrive"
        case "gd": return "Google Drive"
        case "box": return "Box"
        case "s3": return "Amazon S3"
        case "baidu", "bd": return "百度网盘"
        case "webdav": return "WebDAV"
        case "c2", "c2s": return "Synology C2"
        case "aliyun", "ali": return "阿里云 OSS"
        default: return nil
        }
    }
}

public struct CloudSyncOverview: Decodable, Sendable {
    public let connections: [CloudSyncConnection]
    /// True when the whole package is paused (not just one connection).
    public let isPaused: Bool

    enum CodingKeys: String, CodingKey { case conn, is_pause }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connections = try c.decodeIfPresent([CloudSyncConnection].self, forKey: .conn) ?? []
        isPaused = try c.decodeIfPresent(Bool.self, forKey: .is_pause) ?? false
    }
}

/// A sync task (a local folder ↔ remote folder pair) inside a connection (list_sess → sess[]).
public struct CloudSyncTask: Decodable, Identifiable, Hashable, Sendable {
    public enum Direction: String, Sendable {
        case both = "BIDIRECTION", uploadOnly = "ONLY_UPLOAD", downloadOnly = "ONLY_DOWNLOAD", unknown

        public var label: String {
            switch self {
            case .both: return "双向同步"
            case .uploadOnly: return "仅上传"
            case .downloadOnly: return "仅下载"
            case .unknown: return "—"
            }
        }
    }

    public let id: Int
    public let localPath: String
    public let remotePath: String
    public let direction: Direction
    public let status: CloudSyncStatus
    public let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case sess_id, local_sync_path, remote_sync_path, sync_direction, sync_status, error, error_desc
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexInt.self, forKey: .sess_id).value
        localPath = try c.decodeIfPresent(String.self, forKey: .local_sync_path) ?? ""
        remotePath = try c.decodeIfPresent(String.self, forKey: .remote_sync_path) ?? ""
        direction = Direction(rawValue: try c.decodeIfPresent(String.self, forKey: .sync_direction) ?? "") ?? .unknown
        let code = try c.decodeIfPresent(FlexInt.self, forKey: .error)?.value ?? 0
        let desc = try c.decodeIfPresent(String.self, forKey: .error_desc)
        errorDescription = (desc?.isEmpty == false) ? desc : (code != 0 ? "错误码 \(code)" : nil)
        status = code != 0 ? .error : CloudSyncStatus(raw: try c.decodeIfPresent(FlexString.self, forKey: .sync_status)?.value)
    }
}

/// One line of a connection's log (get_log → items[]).
public struct CloudSyncLogEntry: Decodable, Identifiable, Hashable, Sendable {
    public enum Level: Int, Sendable { case info = 0, warning = 1, error = 2 }

    public let id: String
    public let time: Date
    public let level: Level
    public let action: Int
    public let fileName: String
    public let path: String
    public let errorCode: Int

    /// Chinese name for the `action` codes listed by the community client.
    public var actionLabel: String {
        switch action {
        case 0: return "删除云端"
        case 1: return "下载"
        case 2: return "上传"
        case 3: return "删除本地"
        case 4: return "云端重命名"
        case 8: return "合并"
        case 9: return "合并删除"
        default: return "同步"
        }
    }

    enum CodingKeys: String, CodingKey { case time, log_level, action, file_name, path, error_code }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ts = try c.decodeIfPresent(FlexInt.self, forKey: .time)?.value ?? 0
        time = Date(timeIntervalSince1970: TimeInterval(ts))
        level = Level(rawValue: try c.decodeIfPresent(FlexInt.self, forKey: .log_level)?.value ?? 0) ?? .info
        action = try c.decodeIfPresent(FlexInt.self, forKey: .action)?.value ?? -1
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        fileName = try c.decodeIfPresent(String.self, forKey: .file_name)
            ?? (path as NSString).lastPathComponent
        errorCode = try c.decodeIfPresent(FlexInt.self, forKey: .error_code)?.value ?? 0
        // The payload has no id; time + path + action is unique enough for a list.
        id = "\(ts)|\(action)|\(path)"
    }
}

extension DSMClient {
    public var hasCloudSync: Bool { supports("SYNO.CloudSync") }

    public func cloudSyncOverview() async throws -> CloudSyncOverview {
        try await call("SYNO.CloudSync", method: "list_conn", version: 1, params: [
            "is_tray": "false",
            "group_by": "group_by_user",
        ])
    }

    public func cloudSyncTasks(connection: Int) async throws -> [CloudSyncTask] {
        struct R: Decodable { let sess: [CloudSyncTask]? }
        let r: R = try await call("SYNO.CloudSync", method: "list_sess", version: 1,
                                  params: ["connection_id": String(connection)])
        return r.sess ?? []
    }

    /// Newest entries first. `limit` keeps the payload small on phones.
    public func cloudSyncLogs(connection: Int, limit: Int = 100) async throws -> [CloudSyncLogEntry] {
        struct R: Decodable { let items: [CloudSyncLogEntry]? }
        let r: R = try await call("SYNO.CloudSync", method: "get_log", version: 1, params: [
            "connection_id": String(connection),
            "keyword": "",
            "date_from": "0",
            "date_to": "0",
            "log_level": "-1",
            "action": "-1",
            "offset": "0",
            "limit": String(limit),
        ])
        return (r.items ?? []).sorted { $0.time > $1.time }
    }

    /// Pauses one connection, or every connection when `connection` is nil.
    public func pauseCloudSync(connection: Int? = nil) async throws {
        let _: EmptyData = try await call("SYNO.CloudSync", method: "pause", version: 1,
                                          params: connection.map { ["connection_id": String($0)] } ?? [:])
    }

    /// Resumes one connection, or every connection when `connection` is nil.
    public func resumeCloudSync(connection: Int? = nil) async throws {
        let _: EmptyData = try await call("SYNO.CloudSync", method: "resume", version: 1,
                                          params: connection.map { ["connection_id": String($0)] } ?? [:])
    }
}
