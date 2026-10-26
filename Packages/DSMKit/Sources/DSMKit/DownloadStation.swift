import Foundation

/// A Download Station task (SYNO.DownloadStation.Task, the documented API that DSM 6.2–7.2 all serve).
public struct DownloadTask: Decodable, Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable {
        case waiting, downloading, paused, finishing, finished, hashChecking = "hash_checking", seeding
        case filehostingWaiting = "filehosting_waiting", extracting, error, unknown

        public var label: String {
            switch self {
            case .waiting, .filehostingWaiting: return "等待中"
            case .downloading: return "下载中"
            case .paused: return "已暂停"
            case .finishing: return "即将完成"
            case .finished: return "已完成"
            case .hashChecking: return "校验中"
            case .seeding: return "做种中"
            case .extracting: return "解压中"
            case .error: return "出错"
            case .unknown: return "未知"
            }
        }

        public var isActive: Bool { [.waiting, .downloading, .finishing, .hashChecking, .extracting, .filehostingWaiting].contains(self) }
        public var isDone: Bool { self == .finished || self == .seeding }
    }

    public let id: String
    public let title: String
    public let type: String
    public let status: Status
    public let errorDetail: String?
    public let size: Int64
    public let downloaded: Int64
    public let uploaded: Int64
    public let downloadSpeed: Int
    public let uploadSpeed: Int
    public let destination: String?
    public let uri: String?
    public let created: Date?

    public var progress: Double { size > 0 ? min(Double(downloaded) / Double(size), 1) : (status.isDone ? 1 : 0) }

    /// Seconds remaining at the current speed, when it can be estimated.
    public var remaining: Int? {
        guard status == .downloading, downloadSpeed > 0, size > downloaded else { return nil }
        return Int((size - downloaded) / Int64(downloadSpeed))
    }

    enum CodingKeys: String, CodingKey { case id, title, type, status, status_extra, size, additional }
    struct Extra: Decodable { let error_detail: String? }
    struct Additional: Decodable { let detail: Detail?; let transfer: Transfer? }
    struct Detail: Decodable { let destination: String?; let uri: String?; let create_time: FlexInt? }
    struct Transfer: Decodable {
        let size_downloaded: FlexString?
        let size_uploaded: FlexString?
        let speed_download: FlexInt?
        let speed_upload: FlexInt?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        status = Status(rawValue: try c.decodeIfPresent(FlexString.self, forKey: .status)?.value ?? "") ?? .unknown
        errorDetail = try c.decodeIfPresent(Extra.self, forKey: .status_extra)?.error_detail
        size = Int64(try c.decodeIfPresent(FlexString.self, forKey: .size)?.value ?? "") ?? 0
        let additional = try c.decodeIfPresent(Additional.self, forKey: .additional)
        downloaded = Int64(additional?.transfer?.size_downloaded?.value ?? "") ?? 0
        uploaded = Int64(additional?.transfer?.size_uploaded?.value ?? "") ?? 0
        downloadSpeed = additional?.transfer?.speed_download?.value ?? 0
        uploadSpeed = additional?.transfer?.speed_upload?.value ?? 0
        destination = additional?.detail?.destination
        uri = additional?.detail?.uri
        created = additional?.detail?.create_time.map { Date(timeIntervalSince1970: TimeInterval($0.value)) }
    }
}

public struct DownloadStats: Decodable, Sendable {
    public let downloadSpeed: Int
    public let uploadSpeed: Int

    enum CodingKeys: String, CodingKey { case speed_download, speed_upload }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadSpeed = try c.decodeIfPresent(FlexInt.self, forKey: .speed_download)?.value ?? 0
        uploadSpeed = try c.decodeIfPresent(FlexInt.self, forKey: .speed_upload)?.value ?? 0
    }
}

extension DSMClient {
    public var hasDownloadStation: Bool { supports("SYNO.DownloadStation.Task") }

    public func downloadTasks() async throws -> [DownloadTask] {
        struct R: Decodable { let tasks: [DownloadTask] }
        let r: R = try await call("SYNO.DownloadStation.Task", method: "list", version: 1, params: [
            "additional": "detail,transfer",
            "offset": "0",
            "limit": "-1",
        ])
        return r.tasks
    }

    public func downloadStats() async throws -> DownloadStats {
        try await call("SYNO.DownloadStation.Statistic", method: "getinfo", version: 1)
    }

    /// Adds one task per link (http/https/ftp/magnet/ed2k). `destination` is a shared-folder path such as "/downloads/movies".
    public func addDownloads(_ links: [String], destination: String? = nil) async throws {
        var params = ["uri": links.joined(separator: ",")]
        if let destination { params["destination"] = Self.dsDestination(destination) }
        let _: EmptyData = try await call("SYNO.DownloadStation.Task", method: "create", version: 1, params: params)
    }

    /// Adds a task from a local .torrent or .nzb file.
    public func addDownload(torrentAt file: URL, destination: String? = nil) async throws {
        var fields: [(String, String)] = []
        if let destination { fields.append(("destination", Self.dsDestination(destination))) }
        let _: EmptyData = try await multipartUpload(api: "SYNO.DownloadStation.Task", method: "create", preferredVersion: 1,
                                                     fields: fields, fileField: "file",
                                                     fileName: file.lastPathComponent, fileURL: file)
    }

    public func pauseDownloads(_ ids: [String]) async throws { try await taskAction("pause", ids) }
    public func resumeDownloads(_ ids: [String]) async throws { try await taskAction("resume", ids) }

    /// `keepFiles` false also discards partially downloaded data.
    public func deleteDownloads(_ ids: [String], keepFiles: Bool = true) async throws {
        try await taskAction("delete", ids, extra: ["force_complete": keepFiles ? "false" : "true"])
    }

    private func taskAction(_ method: String, _ ids: [String], extra: [String: String] = [:]) async throws {
        var params = extra
        params["id"] = ids.joined(separator: ",")
        // The reply lists each task with its own error code; 0 means it worked.
        struct Item: Decodable { let error: FlexInt? }
        struct Items: Decodable {
            let list: [Item]
            init(from decoder: Decoder) throws { list = (try? [Item](from: decoder)) ?? [] }
        }
        let r: Items = try await call("SYNO.DownloadStation.Task", method: method, version: 1, params: params)
        if let code = r.list.compactMap({ $0.error?.value }).first(where: { $0 != 0 }) {
            throw DSMError.api(code: code, api: "SYNO.DownloadStation.Task")
        }
    }

    /// Download Station wants destinations without the leading slash ("downloads/movies").
    static func dsDestination(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }
}
