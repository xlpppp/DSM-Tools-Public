import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum FileKind: Sendable {
    case folder, audio, video, image, text, archive, other

    public static func of(name: String, isDirectory: Bool) -> FileKind {
        if isDirectory { return .folder }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "mp3", "flac", "wav", "m4a", "aac", "ogg", "ape", "alac", "aiff", "wma", "dsf", "dff":
            return .audio
        case "mp4", "mkv", "mov", "m4v", "avi", "ts", "m2ts", "webm", "wmv", "flv", "rmvb", "mpg", "mpeg":
            return .video
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif":
            return .image
        case "txt", "log", "md", "json", "xml", "yml", "yaml", "ini", "conf", "cfg", "sh", "py", "js", "csv",
             "cue", "srt", "ass", "nfo", "env", "toml", "properties", "html", "css", "sql":
            return .text
        case "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz":
            return .archive
        default:
            return .other
        }
    }
}

/// A file or folder in File Station. `path` starts with the shared folder, e.g. "/video/a.mkv".
public struct RemoteFile: Decodable, Identifiable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64?
    public let modified: Date?
    public let realPath: String?

    public var id: String { path }
    public var kind: FileKind { FileKind.of(name: name, isDirectory: isDirectory) }
    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    enum CodingKeys: String, CodingKey { case path, name, isdir, additional }
    struct Additional: Decodable {
        struct Time: Decodable { let mtime: FlexInt? }
        let size: FlexString?
        let time: Time?
        let real_path: String?
    }

    public init(path: String, name: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil,
                realPath: String? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.realPath = realPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        isDirectory = (try? c.decode(Bool.self, forKey: .isdir)) ?? false
        let extra = try c.decodeIfPresent(Additional.self, forKey: .additional)
        size = extra?.size.flatMap { Int64($0.value) }
        modified = extra?.time?.mtime.map { Date(timeIntervalSince1970: TimeInterval($0.value)) }
        realPath = extra?.real_path
    }
}

public struct FileListing: Sendable {
    public let files: [RemoteFile]
    public let total: Int
}

public enum FileSort: String, CaseIterable, Sendable {
    case name, size, mtime, type

    public var label: String {
        switch self {
        case .name: return "名称"
        case .size: return "大小"
        case .mtime: return "修改时间"
        case .type: return "类型"
        }
    }
}

/// File Station v2+ takes JSON-encoded parameter values (the DSM web UI sends them this way),
/// which keeps paths containing commas or quotes intact.
enum FSParam {
    static func string(_ value: String) -> String { json(value) }
    static func strings(_ values: [String]) -> String { json(values) }
    static func bool(_ value: Bool) -> String { value ? "true" : "false" }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? ""
    }
}

public struct SharingLink: Decodable, Identifiable, Sendable, Hashable {
    public let url: String
    /// DSM's link id; falls back to the URL so lists stay identifiable.
    public let id: String
    public let name: String?
    public let path: String?
    public let isFolder: Bool
    public let hasPassword: Bool
    public let owner: String?
    /// "valid", "expired", "invalid"… as DSM reports it.
    public let status: String?
    /// DSM date strings, e.g. "2026-10-31" or "2026-10-31 23:59:59"; empty = none.
    public let dateExpired: String?
    public let dateAvailable: String?
    /// Remaining allowed accesses; nil or 0 = unlimited. Field name inferred from DSM 7 web UI, unverified.
    public let accessLimit: Int?

    public var isValid: Bool { status.map { $0 == "valid" } ?? true }

    enum CodingKeys: String, CodingKey {
        case url, id, name, path, isFolder, has_password, link_owner, status, date_expired, date_available, expire_times
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        id = (try? c.decodeIfPresent(FlexString.self, forKey: .id))??.value ?? url
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        path = try? c.decodeIfPresent(String.self, forKey: .path)
        isFolder = ((try? c.decodeIfPresent(Bool.self, forKey: .isFolder)) ?? nil) ?? false
        hasPassword = ((try? c.decodeIfPresent(Bool.self, forKey: .has_password)) ?? nil) ?? false
        owner = try? c.decodeIfPresent(String.self, forKey: .link_owner)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        dateExpired = ((try? c.decodeIfPresent(FlexString.self, forKey: .date_expired)) ?? nil)?.value.nilIfEmpty
        dateAvailable = ((try? c.decodeIfPresent(FlexString.self, forKey: .date_available)) ?? nil)?.value.nilIfEmpty
        accessLimit = ((try? c.decodeIfPresent(FlexInt.self, forKey: .expire_times)) ?? nil)?.value
    }
}

extension DSMClient {
    private static let fileAdditional = FSParam.strings(["real_path", "size", "time", "type"])

    // MARK: Browse

    public func listSharedFolders() async throws -> [RemoteFile] {
        struct R: Decodable { let shares: [RemoteFile] }
        let r: R = try await call("SYNO.FileStation.List", method: "list_share", version: 2, params: [
            "additional": Self.fileAdditional,
            "sort_by": FSParam.string("name"),
        ])
        return r.shares
    }

    public func listFolder(_ path: String, sort: FileSort = .name, ascending: Bool = true,
                           offset: Int = 0, limit: Int = 1000) async throws -> FileListing {
        struct R: Decodable { let files: [RemoteFile]; let total: FlexInt? }
        let r: R = try await call("SYNO.FileStation.List", method: "list", version: 2, params: [
            "folder_path": FSParam.string(path),
            "additional": Self.fileAdditional,
            "sort_by": FSParam.string(sort.rawValue),
            "sort_direction": FSParam.string(ascending ? "asc" : "desc"),
            "offset": String(offset),
            "limit": String(limit),
        ])
        return FileListing(files: r.files, total: r.total?.value ?? r.files.count)
    }

    // MARK: Search

    /// Searches file names under `folders` (recursively). DSM searches in the background, so this
    /// polls until it finishes, `limit` hits arrive or `timeout` passes, then frees the task.
    public func searchFiles(_ keyword: String, in folders: [String], limit: Int = 200,
                            timeout: TimeInterval = 15) async throws -> [RemoteFile] {
        let taskID = try await startTask("SYNO.FileStation.Search", version: 2, params: [
            "folder_path": FSParam.strings(folders),
            "pattern": FSParam.string(keyword),
            "recursive": FSParam.bool(true),
        ])
        struct R: Decodable { let finished: Bool?; let files: [RemoteFile]? }
        let deadline = Date().addingTimeInterval(timeout)
        var files: [RemoteFile] = []
        do {
            while true {
                try Task.checkCancellation()
                let r: R = try await call("SYNO.FileStation.Search", method: "list", version: 2, params: [
                    "taskid": FSParam.string(taskID),
                    "offset": "0",
                    "limit": String(limit),
                    "additional": Self.fileAdditional,
                ])
                files = r.files ?? []
                if r.finished == true || files.count >= limit || Date() >= deadline { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        } catch {
            await endSearch(taskID)
            throw error
        }
        await endSearch(taskID)
        return files
    }

    private func endSearch(_ taskID: String) async {
        let params = ["taskid": FSParam.string(taskID)]
        _ = try? await call("SYNO.FileStation.Search", method: "stop", version: 2, params: params) as EmptyData
        _ = try? await call("SYNO.FileStation.Search", method: "clean", version: 2, params: params) as EmptyData
    }

    // MARK: Read

    /// URL that returns the file's bytes; usable by AVPlayer for streaming.
    /// It carries the session id, so it must not be logged or shared.
    public func downloadURL(for path: String) throws -> URL {
        try authenticatedURL(api: "SYNO.FileStation.Download", method: "download", preferredVersion: 2, params: [
            "path": FSParam.strings([path]),
            "mode": FSParam.string("open"),
        ])
    }

    public func thumbnailURL(for path: String, size: String = "medium") throws -> URL {
        try authenticatedURL(api: "SYNO.FileStation.Thumb", method: "get", preferredVersion: 2, params: [
            "path": FSParam.string(path),
            "size": FSParam.string(size),
        ])
    }

    /// Downloads a file into memory through the client's own transport, so a trusted
    /// self-signed certificate works. For previews (text, images), not for large files.
    public func fileData(at path: String) async throws -> Data {
        let request = URLRequest(url: try downloadURL(for: path))
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw DSMError.transport("HTTP \(response.statusCode)") }
        // A failed download comes back as a JSON error envelope instead of file bytes.
        if response.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true,
           let envelope = try? JSONDecoder().decode(Envelope<EmptyData>.self, from: data), !envelope.success {
            throw DSMError.api(code: envelope.error?.code ?? 100, api: "SYNO.FileStation.Download")
        }
        return data
    }

    /// Downloads a file to a temporary location named after it, through the client's own
    /// transport (so a pinned self-signed certificate works). The caller owns the returned file.
    public func downloadFile(at path: String) async throws -> URL {
        let (temp, response) = try await transport.download(URLRequest(url: try downloadURL(for: path)))
        guard (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: temp)
            throw DSMError.transport("HTTP \(response.statusCode)")
        }
        if response.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true,
           let data = try? Data(contentsOf: temp),
           let envelope = try? JSONDecoder().decode(Envelope<EmptyData>.self, from: data), !envelope.success {
            try? FileManager.default.removeItem(at: temp)
            throw DSMError.api(code: envelope.error?.code ?? 100, api: "SYNO.FileStation.Download")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent((path as NSString).lastPathComponent)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    func authenticatedURL(api: String, method: String, preferredVersion: Int, params: [String: String],
                          pathSuffix: String = "") throws -> URL {
        guard let d = apis[api], let v = version(of: api, preferred: preferredVersion) else {
            throw DSMError.apiUnavailable(api)
        }
        guard let session else { throw DSMError.notAuthenticated }
        var fields = params
        fields["api"] = api
        fields["method"] = method
        fields["version"] = String(v)
        fields["_sid"] = session.sid
        if let token = session.synoToken { fields["SynoToken"] = token }
        guard let url = URL(string: "webapi/\(d.path)\(pathSuffix)?\(Self.formEncode(fields))", relativeTo: baseURL)?.absoluteURL else {
            throw DSMError.invalidResponse
        }
        return url
    }

    // MARK: Change

    public func createFolder(in parent: String, name: String) async throws {
        let _: EmptyData = try await call("SYNO.FileStation.CreateFolder", method: "create", version: 2, params: [
            "folder_path": FSParam.strings([parent]),
            "name": FSParam.strings([name]),
            "force_parent": "false",
        ])
    }

    public func rename(_ path: String, to newName: String) async throws {
        let _: EmptyData = try await call("SYNO.FileStation.Rename", method: "rename", version: 2, params: [
            "path": FSParam.strings([path]),
            "name": FSParam.strings([newName]),
        ])
    }

    public func delete(_ paths: [String]) async throws {
        let taskID = try await startTask("SYNO.FileStation.Delete", version: 2, params: [
            "path": FSParam.strings(paths),
            "recursive": "true",
        ])
        try await waitForTask("SYNO.FileStation.Delete", version: 2, taskID: taskID)
    }

    public func copy(_ paths: [String], to destination: String, move: Bool, overwrite: Bool = false) async throws {
        let taskID = try await startTask("SYNO.FileStation.CopyMove", version: 3, params: [
            "path": FSParam.strings(paths),
            "dest_folder_path": FSParam.string(destination),
            "overwrite": FSParam.bool(overwrite),
            "remove_src": FSParam.bool(move),
        ])
        try await waitForTask("SYNO.FileStation.CopyMove", version: 3, taskID: taskID)
    }

    /// Zips `paths` into `destinationFile` (a full path ending in .zip).
    public func compress(_ paths: [String], into destinationFile: String) async throws {
        let taskID = try await startTask("SYNO.FileStation.Compress", version: 3, params: [
            "path": FSParam.strings(paths),
            "dest_file_path": FSParam.string(destinationFile),
            "format": FSParam.string("zip"),
            "mode": FSParam.string("add"),
        ])
        try await waitForTask("SYNO.FileStation.Compress", version: 3, taskID: taskID)
    }

    public func extract(_ archive: String, to destinationFolder: String, password: String? = nil) async throws {
        var params = [
            "file_path": FSParam.string(archive),
            "dest_folder_path": FSParam.string(destinationFolder),
            "keep_dir": "true",
            "create_subfolder": "true",
            "overwrite": "false",
        ]
        if let password, !password.isEmpty { params["password"] = FSParam.string(password) }
        let taskID = try await startTask("SYNO.FileStation.Extract", version: 2, params: params)
        try await waitForTask("SYNO.FileStation.Extract", version: 2, taskID: taskID)
    }

    /// Creates a public sharing link. `expires` nil = never; `accessLimit` nil or 0 = unlimited.
    /// `expire_times` (access count) is inferred from the DSM 7 web UI and unverified on a real NAS.
    public func createShareLink(for path: String, password: String? = nil, expires: Date? = nil,
                                accessLimit: Int? = nil) async throws -> SharingLink {
        var params = ["path": FSParam.string(path)]
        if let password, !password.isEmpty { params["password"] = FSParam.string(password) }
        if let expires {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            params["date_expired"] = FSParam.string(f.string(from: expires))
        }
        if let accessLimit, accessLimit > 0 { params["expire_times"] = String(accessLimit) }
        struct R: Decodable { let links: [SharingLink] }
        let r: R = try await call("SYNO.FileStation.Sharing", method: "create", version: 3, params: params)
        guard let link = r.links.first else { throw DSMError.invalidResponse }
        return link
    }

    /// Links the signed-in user created (admins see everyone's).
    public func shareLinks(offset: Int = 0, limit: Int = 500) async throws -> [SharingLink] {
        struct R: Decodable { let links: [SharingLink] }
        let r: R = try await call("SYNO.FileStation.Sharing", method: "list", version: 3, params: [
            "offset": String(offset), "limit": String(limit),
            "sort_by": FSParam.string("date_expired"), "sort_direction": FSParam.string("asc"),
            "force_clean": "false",
        ])
        return r.links
    }

    /// Cancels links; anyone holding them loses access. Callers confirm first.
    public func deleteShareLinks(_ ids: [String]) async throws {
        let _: EmptyData = try await call("SYNO.FileStation.Sharing", method: "delete", version: 3, params: [
            "id": FSParam.strings(ids),
        ])
    }

    /// Removes expired or broken links in one go.
    public func clearInvalidShareLinks() async throws {
        let _: EmptyData = try await call("SYNO.FileStation.Sharing", method: "clear_invalid", version: 3)
    }

    /// Uploads a local file into `folder`. The multipart body is written to a temporary
    /// file first so large videos are streamed from disk rather than held in memory.
    public func upload(fileAt local: URL, to folder: String, as name: String? = nil, overwrite: Bool = false) async throws {
        let _: EmptyData = try await multipartUpload(api: "SYNO.FileStation.Upload", method: "upload", preferredVersion: 2, fields: [
            ("path", folder),
            ("create_parents", "true"),
            ("overwrite", overwrite ? "true" : "false"),
        ], fileField: "file", fileName: name ?? local.lastPathComponent, fileURL: local)
    }

    /// Posts a file as multipart/form-data. The body is written to a temporary file first so large
    /// files stream from disk rather than being held in memory. api/method/version go in both the
    /// query and the form, since older CGI endpoints only read the form. `fieldsInQuery` also copies
    /// the other fields into the query, for APIs (Synology Drive) whose clients send them there.
    func multipartUpload<T: Decodable>(api: String, method: String, preferredVersion: Int, fields: [(String, String)],
                                       fileField: String, fileName: String, fileURL: URL,
                                       fieldsInQuery: Bool = false) async throws -> T {
        guard let d = apis[api], let v = version(of: api, preferred: preferredVersion) else {
            throw DSMError.apiUnavailable(api)
        }
        guard let session else { throw DSMError.notAuthenticated }
        var query = ["api": api, "method": method, "version": String(v), "_sid": session.sid]
        if let token = session.synoToken { query["SynoToken"] = token }
        if fieldsInQuery {
            for (name, value) in fields where query[name] == nil { query[name] = value }
        }
        guard let url = URL(string: "webapi/\(d.path)?\(Self.formEncode(query))", relativeTo: baseURL)?.absoluteURL else {
            throw DSMError.invalidResponse
        }

        let boundary = "NASHelper-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: body) }
        try Self.writeMultipart(to: body, boundary: boundary,
                                fields: [("api", api), ("method", method), ("version", String(v))] + fields,
                                fileField: fileField, fileName: fileName, fileURL: fileURL)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = session.synoToken { request.setValue(token, forHTTPHeaderField: "X-SYNO-TOKEN") }
        let logged = Dictionary(fields, uniquingKeysWith: { a, _ in a }).merging(["file": fileName]) { a, _ in a }
        do {
            let (data, response) = try await transport.upload(request, fromFile: body)
            let value: T = try decode(data, response, api: api)
            audit(api, method, logged, error: nil)
            return value
        } catch {
            audit(api, method, logged, error: error)
            throw error
        }
    }

    static func writeMultipart(to target: URL, boundary: String, fields: [(String, String)],
                               fileField: String, fileName: String, fileURL: URL) throws {
        _ = FileManager.default.createFile(atPath: target.path, contents: nil)
        let out = try FileHandle(forWritingTo: target)
        defer { try? out.close() }
        func write(_ s: String) { out.write(Data(s.utf8)) }

        for (name, value) in fields {
            write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        let safeName = fileName.replacingOccurrences(of: "\"", with: "'")
        write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(safeName)\"\r\n")
        write("Content-Type: application/octet-stream\r\n\r\n")
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while true {
            let chunk = input.readData(ofLength: 4 << 20)
            if chunk.isEmpty { break }
            out.write(chunk)
        }
        write("\r\n--\(boundary)--\r\n")
    }

    // MARK: Background tasks

    func startTask(_ api: String, version: Int, params: [String: String]) async throws -> String {
        struct R: Decodable { let taskid: String }
        let r: R = try await call(api, method: "start", version: version, params: params)
        return r.taskid
    }

    /// Polls `status` until DSM reports the task finished.
    func waitForTask(_ api: String, version: Int, taskID: String, timeout: TimeInterval = 600) async throws {
        struct S: Decodable { let finished: Bool? }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let s: S = try await call(api, method: "status", version: version, params: ["taskid": FSParam.string(taskID)])
            if s.finished == true { return }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        throw DSMError.transport("操作超时，DSM 仍在后台处理")
    }
}
