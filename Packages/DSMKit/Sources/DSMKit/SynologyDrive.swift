import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Synology Drive Server (DSM 7) web API, as used by the Drive web portal.
// Verified against the open-source synology-drive-api client: Files list/get/upload/download,
// TeamFolders list, and the "/mydrive/" and "/team-folders/" path roots.
// Inferred and not yet checked on a real NAS: the list_starred / list_recent /
// list_shared_with_me methods, the admin console's SYNO.SynologyDrive.Connection list,
// and the mapping of Drive paths onto File Station paths.

/// One of the Drive portal's top-level views.
public enum DriveCategory: String, CaseIterable, Identifiable, Sendable {
    case myDrive, teamFolders, recent, sharedWithMe, starred

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .myDrive: return "我的文件"
        case .teamFolders: return "团队文件夹"
        case .recent: return "最近"
        case .sharedWithMe: return "与我共享"
        case .starred: return "星标"
        }
    }

    public var symbol: String {
        switch self {
        case .myDrive: return "person.crop.circle"
        case .teamFolders: return "person.3"
        case .recent: return "clock"
        case .sharedWithMe: return "person.2.wave.2"
        case .starred: return "star"
        }
    }

    /// SYNO.SynologyDrive.Files method for the flat views; nil for folder roots.
    var listMethod: String? {
        switch self {
        case .myDrive, .teamFolders: return nil
        case .recent: return "list_recent"              // inferred
        case .sharedWithMe: return "list_shared_with_me" // inferred
        case .starred: return "list_starred"            // inferred
        }
    }
}

/// A file or folder in Synology Drive. `path` is Drive's display path, e.g. "/mydrive/a.txt"
/// or "/team-folders/Projects/b.pdf"; `fileID` is the stable id DSM accepts as "id:<n>".
public struct DriveItem: Decodable, Identifiable, Hashable, Sendable {
    public let fileID: String
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64?
    public let modified: Date?
    public let starred: Bool
    public let shared: Bool
    public let owner: String?

    public var id: String { fileID.isEmpty ? path : fileID }
    public var kind: FileKind { FileKind.of(name: name, isDirectory: isDirectory) }
    /// The form Drive's file APIs accept: "id:<n>" when the id is known, else the path.
    public var reference: String { fileID.isEmpty ? path : "id:\(fileID)" }

    /// Where the same item lives in File Station, so previews and uploads can reuse that
    /// (verified) code. My Drive is stored in the home folder's "Drive" subfolder and each team
    /// folder is a shared folder of the same name. Inferred from Drive's storage layout; nil for
    /// items such as "shared with me" whose owner's home this account cannot browse.
    public var fileStationPath: String? { DriveItem.fileStationPath(for: path) }

    public static func fileStationPath(for drivePath: String) -> String? {
        if drivePath == "/mydrive" || drivePath.hasPrefix("/mydrive/") {
            return "/home/Drive" + drivePath.dropFirst("/mydrive".count)
        }
        if drivePath.hasPrefix("/team-folders/") {
            let rest = drivePath.dropFirst("/team-folders".count)
            return rest.count > 1 ? String(rest) : nil
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case file_id, name, path, display_path, type, content_type, size, modified_time, starred, shared, owner
    }
    struct Owner: Decodable { let name: String?; let display_name: String? }

    public init(fileID: String, name: String, path: String, isDirectory: Bool, size: Int64? = nil,
                modified: Date? = nil, starred: Bool = false, shared: Bool = false, owner: String? = nil) {
        self.fileID = fileID
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.starred = starred
        self.shared = shared
        self.owner = owner
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileID = try c.decodeIfPresent(FlexString.self, forKey: .file_id)?.value ?? ""
        let display = (try? c.decodeIfPresent(String.self, forKey: .display_path)) ?? nil
        let raw = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? nil
        path = display ?? raw ?? ""
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? (path as NSString).lastPathComponent
        let type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
        let contentType = (try? c.decodeIfPresent(String.self, forKey: .content_type)) ?? nil
        isDirectory = type == "dir" || type == "folder" || contentType == "dir"
        let rawSize = (try? c.decodeIfPresent(FlexString.self, forKey: .size)) ?? nil
        size = rawSize.flatMap { Int64($0.value) }
        let mtime = (try? c.decodeIfPresent(FlexInt.self, forKey: .modified_time)) ?? nil
        modified = mtime.flatMap { $0.value > 0 ? Date(timeIntervalSince1970: TimeInterval($0.value)) : nil }
        starred = ((try? c.decodeIfPresent(Bool.self, forKey: .starred)) ?? nil) ?? false
        shared = ((try? c.decodeIfPresent(Bool.self, forKey: .shared)) ?? nil) ?? false
        let o = (try? c.decodeIfPresent(Owner.self, forKey: .owner)) ?? nil
        owner = o?.display_name.flatMap { $0.isEmpty ? nil : $0 } ?? o?.name
    }
}

public struct DriveListing: Sendable {
    public let items: [DriveItem]
    public let total: Int
}

/// A Drive client (desktop, mobile, ShareSync) connected to the server, from the admin console.
public struct DriveConnection: Identifiable, Hashable, Sendable {
    public let id: String
    public let user: String?
    public let device: String?
    public let client: String?
    public let address: String?
    public let version: String?
    public let lastSeen: Date?
}

/// What the Drive module can show about the server side.
public struct DriveServerStatus: Sendable {
    /// From Package Center; nil when the account cannot read the package list.
    public let package: InstalledPackage?
    /// SYNO.SynologyDrive* APIs this NAS advertises, with their highest version.
    public let apis: [(name: String, maxVersion: Int)]
    public let teamFolders: [DriveItem]
    /// nil when the admin API is missing or refused (non-admin accounts).
    public let connections: [DriveConnection]?
    public let connectionError: String?

    public var isInstalled: Bool { package != nil || !apis.isEmpty }
}

extension DSMClient {
    static let driveFiles = "SYNO.SynologyDrive.Files"

    public var hasSynologyDrive: Bool { supports(Self.driveFiles) }

    // MARK: Browse

    /// Lists a folder by Drive path ("/mydrive/", "/team-folders/x") or by "id:<n>".
    public func driveList(_ folder: String, sortBy: String = "name", ascending: Bool = true,
                          offset: Int = 0, limit: Int = 1000) async throws -> DriveListing {
        try await driveListCall("list", params: [
            "path": FSParam.string(folder),
            "filter": "{}",
            "sort_by": FSParam.string(sortBy),
            "sort_direction": FSParam.string(ascending ? "asc" : "desc"),
            "offset": String(offset),
            "limit": String(limit),
        ])
    }

    /// Team folders this account can see in Drive.
    public func driveTeamFolders() async throws -> [DriveItem] {
        struct R: Decodable { let items: [DriveItem]? }
        let r: R = try await call("SYNO.SynologyDrive.TeamFolders", method: "list", version: 1, params: [
            "filter": "{}",
            "sort_by": FSParam.string("name"),
            "sort_direction": FSParam.string("asc"),
            "offset": "0",
            "limit": "1000",
        ])
        // The list entry may omit the path; team folders always live under /team-folders/.
        return (r.items ?? []).map { item in
            if item.path.hasPrefix("/team-folders/") { return item }
            return DriveItem(fileID: item.fileID, name: item.name, path: "/team-folders/\(item.name)",
                             isDirectory: true, size: item.size, modified: item.modified,
                             starred: item.starred, shared: item.shared, owner: item.owner)
        }
    }

    /// Recent, shared-with-me and starred views. Method names are inferred from the Drive web portal.
    public func driveList(_ category: DriveCategory, offset: Int = 0, limit: Int = 500) async throws -> DriveListing {
        guard let method = category.listMethod else {
            return try await driveList(category == .myDrive ? "/mydrive/" : "/team-folders/")
        }
        return try await driveListCall(method, params: [
            "filter": "{}",
            "offset": String(offset),
            "limit": String(limit),
        ])
    }

    private func driveListCall(_ method: String, params: [String: String]) async throws -> DriveListing {
        struct R: Decodable { let items: [DriveItem]?; let total: FlexInt? }
        let r: R = try await call(Self.driveFiles, method: method, version: 2, params: params)
        let items = r.items ?? []
        return DriveListing(items: items, total: r.total?.value ?? items.count)
    }

    // MARK: Files

    /// URL that returns the file's bytes. Carries the session id: do not log or share it.
    public func driveDownloadURL(for item: DriveItem) throws -> URL {
        // The file name after entry.cgi/ is what the web portal sends; DSM uses it for the saved name.
        let suffix = "/" + (item.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "download")
        return try authenticatedURL(api: Self.driveFiles, method: "download", preferredVersion: 2, params: [
            "files": FSParam.strings([item.reference]),
            "force_download": "true",
            "json_error": "true",
        ], pathSuffix: suffix)
    }

    /// Downloads to a temporary file named after the item. The caller owns the returned file.
    public func driveDownload(_ item: DriveItem) async throws -> URL {
        let (temp, response) = try await transport.download(URLRequest(url: try driveDownloadURL(for: item)))
        guard (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: temp)
            throw DSMError.transport("HTTP \(response.statusCode)")
        }
        if response.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true,
           let data = try? Data(contentsOf: temp),
           let envelope = try? JSONDecoder().decode(Envelope<EmptyData>.self, from: data), !envelope.success {
            try? FileManager.default.removeItem(at: temp)
            throw DSMError.api(code: envelope.error?.code ?? 100, api: Self.driveFiles)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A folder downloads as a zip.
        let name = item.isDirectory ? "\(item.name).zip" : item.name
        let target = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    /// Uploads into a Drive folder. `conflictAction` "version" keeps the old file as a previous
    /// version (Drive's default), "autorename" keeps both.
    public func driveUpload(fileAt local: URL, toFolder folder: String, as name: String? = nil,
                            conflictAction: String = "version") async throws {
        let fileName = name ?? local.lastPathComponent
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        let _: EmptyData = try await multipartUpload(api: Self.driveFiles, method: "upload", preferredVersion: 2, fields: [
            ("path", base + fileName),
            ("type", "file"),
            ("conflict_action", conflictAction),
        ], fileField: "file", fileName: fileName, fileURL: local, fieldsInQuery: true)
    }

    /// Stars or unstars items. Inferred: the web portal sends Files.update with `starred`.
    public func driveSetStarred(_ items: [DriveItem], starred: Bool) async throws {
        for item in items {
            let _: EmptyData = try await call(Self.driveFiles, method: "update", version: 2, params: [
                "path": FSParam.string(item.reference),
                "starred": FSParam.bool(starred),
            ])
        }
    }

    // MARK: Server

    /// Package state, advertised APIs, team folders and (for admins) connected clients.
    public func driveServerStatus() async -> DriveServerStatus {
        let package = (try? await installedPackages())?.first { $0.id == "SynologyDrive" }
        let apis = self.apis
            .filter { $0.key.hasPrefix("SYNO.SynologyDrive") }
            .map { (name: $0.key, maxVersion: $0.value.maxVersion) }
            .sorted { $0.name < $1.name }
        let teamFolders = (try? await driveTeamFolders()) ?? []
        var connections: [DriveConnection]?
        var connectionError: String?
        do {
            connections = try await driveConnections()
        } catch {
            connectionError = (error as? DSMError)?.message ?? "\(error)"
        }
        return DriveServerStatus(package: package, apis: apis, teamFolders: teamFolders,
                                 connections: connections, connectionError: connectionError)
    }

    /// Clients connected to Drive Server (admin console "Client List"). Inferred API; the payload
    /// is read loosely because its field names are not confirmed.
    public func driveConnections() async throws -> [DriveConnection] {
        let r: JSONValue = try await call("SYNO.SynologyDrive.Connection", method: "list", version: 1, params: [
            "offset": "0",
            "limit": "200",
        ])
        let rows = r["items"]?.array ?? r["connections"]?.array ?? r["list"]?.array ?? r.array ?? []
        return rows.enumerated().map { index, row in
            func text(_ keys: String...) -> String? {
                for key in keys { if let s = row[key]?.string, !s.isEmpty { return s } }
                return nil
            }
            let seen = (row["last_seen"] ?? row["login_time"] ?? row["time"])?.int64
            return DriveConnection(
                id: text("id", "session_id", "conn_id") ?? "\(index)",
                user: text("user", "user_name", "username", "owner"),
                device: text("device_name", "hostname", "computer_name", "client_name"),
                client: text("client_type", "type", "platform"),
                address: text("ip", "ip_address", "client_ip", "from"),
                version: text("client_version", "version"),
                lastSeen: seen.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil })
        }
    }
}
