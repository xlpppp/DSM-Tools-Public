import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Synology Photos (DSM 7). The personal space uses SYNO.Foto.*, the shared space SYNO.FotoTeam.*.
public enum PhotoSpace: String, CaseIterable, Sendable {
    case personal = "SYNO.Foto", shared = "SYNO.FotoTeam"

    public var label: String { self == .personal ? "个人空间" : "共享空间" }
}

public struct PhotoItem: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let filename: String
    public let fileSize: Int64
    public let taken: Date?
    public let isVideo: Bool
    public let width: Int?
    public let height: Int?
    /// Needed to fetch thumbnails; nil while DSM is still generating them.
    public let cacheKey: String?
    /// Synology Photos folder holding the file; used to work out its File Station path.
    public private(set) var folderID: Int?

    enum CodingKeys: String, CodingKey { case id, filename, filesize, time, type, folder_id, additional }
    struct Additional: Decodable {
        struct Thumb: Decodable { let cache_key: String?; let m: String? }
        struct Resolution: Decodable { let width: FlexInt?; let height: FlexInt? }
        let thumbnail: Thumb?
        let resolution: Resolution?
    }

    /// Rebuilds an item the app saved itself, e.g. the home screen's recently viewed photos.
    public init(id: Int, filename: String, fileSize: Int64 = 0, taken: Date? = nil, isVideo: Bool,
                width: Int? = nil, height: Int? = nil, cacheKey: String?) {
        self.id = id
        self.filename = filename
        self.fileSize = fileSize
        self.taken = taken
        self.isVideo = isVideo
        self.width = width
        self.height = height
        self.cacheKey = cacheKey
        self.folderID = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexInt.self, forKey: .id).value
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        fileSize = Int64(try c.decodeIfPresent(FlexString.self, forKey: .filesize)?.value ?? "") ?? 0
        let t: FlexInt? = (try? c.decodeIfPresent(FlexInt.self, forKey: .time)) ?? nil
        taken = t.map { Date(timeIntervalSince1970: TimeInterval($0.value)) }
        isVideo = (try c.decodeIfPresent(String.self, forKey: .type)) == "video"
        let a = try c.decodeIfPresent(Additional.self, forKey: .additional)
        width = a?.resolution?.width?.value
        height = a?.resolution?.height?.value
        cacheKey = a?.thumbnail?.cache_key
        folderID = (try? c.decodeIfPresent(FlexInt.self, forKey: .folder_id))??.value
    }
}

public struct PhotoAlbum: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let itemCount: Int
    /// Cover photo's thumbnail key and id.
    public let coverID: Int?
    public let coverCacheKey: String?

    enum CodingKeys: String, CodingKey { case id, name, item_count, additional }
    struct Additional: Decodable {
        struct Thumb: Decodable { let cache_key: String?; let unit_id: FlexInt? }
        let thumbnail: Thumb?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexInt.self, forKey: .id).value
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        itemCount = try c.decodeIfPresent(FlexInt.self, forKey: .item_count)?.value ?? 0
        let a = try c.decodeIfPresent(Additional.self, forKey: .additional)
        coverID = a?.thumbnail?.unit_id?.value
        coverCacheKey = a?.thumbnail?.cache_key
    }
}

public enum ThumbnailSize: String, Sendable {
    case small = "sm", medium = "m", large = "xl"
}

extension DSMClient {
    public func hasPhotos(_ space: PhotoSpace = .personal) -> Bool { supports("\(space.rawValue).Browse.Item") }

    /// Newest first. `albumID` limits the list to one album.
    public func photos(space: PhotoSpace = .personal, albumID: Int? = nil, offset: Int = 0, limit: Int = 200) async throws -> [PhotoItem] {
        struct R: Decodable { let list: [PhotoItem] }
        var params = [
            "offset": String(offset),
            "limit": String(limit),
            "sort_by": FSParam.string("takentime"),
            "sort_direction": FSParam.string("desc"),
            "additional": FSParam.strings(["thumbnail", "resolution"]),
        ]
        if let albumID { params["album_id"] = String(albumID) }
        let r: R = try await call("\(space.rawValue).Browse.Item", method: "list", version: 1, params: params)
        return r.list
    }

    /// Albums exist only in the personal space; the shared space is organised by folders.
    public func photoAlbums(offset: Int = 0, limit: Int = 200) async throws -> [PhotoAlbum] {
        struct R: Decodable { let list: [PhotoAlbum] }
        let r: R = try await call("SYNO.Foto.Browse.Album", method: "list", version: 1, params: [
            "offset": String(offset), "limit": String(limit),
            "additional": FSParam.strings(["thumbnail"]),
        ])
        return r.list
    }

    public func photoThumbnailURL(space: PhotoSpace = .personal, id: Int, cacheKey: String, size: ThumbnailSize = .medium) throws -> URL {
        try authenticatedURL(api: "\(space.rawValue).Thumbnail", method: "get", preferredVersion: 1, params: [
            "id": String(id),
            "cache_key": FSParam.string(cacheKey),
            "type": FSParam.string("unit"),
            "size": FSParam.string(size.rawValue),
        ])
    }

    /// The original file (photo or video).
    public func photoOriginalURL(space: PhotoSpace = .personal, id: Int) throws -> URL {
        try authenticatedURL(api: "\(space.rawValue).Download", method: "download", preferredVersion: 1, params: [
            "unit_id": "[\(id)]",
        ])
    }

    /// GET through the client's own transport, including a Range header when the caller set one.
    /// 206 is success. Used so AVPlayer can read an original file without the system trust store.
    public func fetchResponse(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw DSMError.transport("HTTP \(response.statusCode)") }
        return (data, response)
    }

    /// Downloads to a temp file. A Range header is forwarded, so a 2-byte probe stays a 2-byte file.
    public func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (temp, response) = try await transport.download(request)
        guard (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: temp)
            throw DSMError.transport("HTTP \(response.statusCode)")
        }
        return (temp, response)
    }

    /// GET through the client's own transport, so pinned self-signed certificates work for images.
    public func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await transport.send(URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else { throw DSMError.transport("HTTP \(response.statusCode)") }
        if response.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true,
           let envelope = try? JSONDecoder().decode(Envelope<EmptyData>.self, from: data), !envelope.success {
            throw DSMError.api(code: envelope.error?.code ?? 100, api: url.path)
        }
        return data
    }

    /// Like `downloadFile(at:)` but for any authenticated URL; the result keeps `name`.
    public func download(_ url: URL, as name: String) async throws -> URL {
        let (temp, response) = try await transport.download(URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: temp)
            throw DSMError.transport("HTTP \(response.statusCode)")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }
}
