import Foundation

// Synology Photos browsing beyond the timeline: folders, people, places, tags and favourites.
// Method and parameter names follow what the Synology Photos web client sends (SYNO.Foto.* on
// DSM 7.2); folders, people, places and tags are not yet checked against a real NAS.

/// A face group ("人物"), a place ("地点") or a general tag ("标签"), each listed with a cover photo.
public enum PhotoCategory: String, CaseIterable, Sendable {
    case person, place, tag

    public var label: String {
        switch self {
        case .person: return "人物"
        case .place: return "地点"
        case .tag: return "标签"
        }
    }

    var api: String {
        switch self {
        case .person: return "Browse.Person"
        case .place: return "Browse.Geocoding"
        case .tag: return "Browse.GeneralTag"
        }
    }

    /// Parameter of Browse.Item.list that filters items by this category.
    var itemFilter: String {
        switch self {
        case .person: return "person_id"
        case .place: return "geocoding_id"
        case .tag: return "general_tag_id"
        }
    }
}

public struct PhotoGroup: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let itemCount: Int
    /// Person covers are fetched by the person's id; places and tags by the cover photo's id.
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
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        itemCount = (try? c.decodeIfPresent(FlexInt.self, forKey: .item_count))??.value ?? 0
        let a = try? c.decodeIfPresent(Additional.self, forKey: .additional)
        coverID = a?.thumbnail?.unit_id?.value
        coverCacheKey = a?.thumbnail?.cache_key
    }
}

public struct PhotoFolder: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    /// Path inside the space, e.g. "/" for the root or "/2024/旅行".
    public let path: String
    public let parentID: Int?

    public var name: String {
        path == "/" ? "全部文件夹" : (path.split(separator: "/").last.map(String.init) ?? path)
    }

    enum CodingKeys: String, CodingKey { case id, name, parent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexInt.self, forKey: .id).value
        path = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "/"
        parentID = (try? c.decodeIfPresent(FlexInt.self, forKey: .parent))??.value
    }
}

/// Filters for `photos(space:filter:)`.
public enum PhotoFilter: Hashable, Sendable {
    case all
    case album(Int)
    case folder(Int)
    case group(PhotoCategory, Int)
}

extension PhotoSpace {
    /// Where the space lives in File Station: the user's home Photos folder or the /photo share.
    public var fileStationRoot: String { self == .personal ? "/home/Photos" : "/photo" }

    /// File Station path of a Synology Photos folder.
    public func fileStationPath(of folderPath: String) -> String {
        folderPath == "/" || folderPath.isEmpty ? fileStationRoot : fileStationRoot + folderPath
    }
}

extension DSMClient {
    /// Album the app uses for "收藏". Synology Photos has no favourite flag that its web API
    /// exposes reliably across versions, so favourites are kept in a normal album with this name.
    public static let favoritesAlbumName = "收藏"

    public func supportsPhotoCategory(_ category: PhotoCategory, space: PhotoSpace) -> Bool {
        supports("\(space.rawValue).\(category.api)")
    }

    public func supportsPhotoFolders(_ space: PhotoSpace) -> Bool {
        supports("\(space.rawValue).Browse.Folder")
    }

    /// Items newest first, limited by `filter`.
    public func photos(space: PhotoSpace, filter: PhotoFilter, offset: Int = 0, limit: Int = 200) async throws -> [PhotoItem] {
        switch filter {
        case .all: return try await photos(space: space, offset: offset, limit: limit)
        case .album(let id): return try await photos(space: space, albumID: id, offset: offset, limit: limit)
        case .folder(let id): return try await photoItems(space: space, extra: ["folder_id": String(id)], offset: offset, limit: limit)
        case .group(let category, let id):
            return try await photoItems(space: space, extra: [category.itemFilter: String(id)], offset: offset, limit: limit)
        }
    }

    private func photoItems(space: PhotoSpace, extra: [String: String], offset: Int, limit: Int) async throws -> [PhotoItem] {
        struct R: Decodable { let list: [PhotoItem] }
        var params = [
            "offset": String(offset),
            "limit": String(limit),
            "sort_by": FSParam.string("takentime"),
            "sort_direction": FSParam.string("desc"),
            "additional": FSParam.strings(["thumbnail", "resolution"]),
        ]
        params.merge(extra) { _, new in new }
        let r: R = try await call("\(space.rawValue).Browse.Item", method: "list", version: 1, params: params)
        return r.list
    }

    // MARK: People, places, tags

    public func photoGroups(_ category: PhotoCategory, space: PhotoSpace, offset: Int = 0, limit: Int = 500) async throws -> [PhotoGroup] {
        struct R: Decodable { let list: [PhotoGroup] }
        var params = [
            "offset": String(offset), "limit": String(limit),
            "additional": FSParam.strings(["thumbnail"]),
        ]
        if category == .person {
            params["show_more"] = "true"
            params["show_hidden"] = "false"
        }
        let r: R = try await call("\(space.rawValue).\(category.api)", method: "list", version: 1, params: params)
        // Unnamed people come back with an empty name; keep them, the app labels them.
        return r.list.filter { $0.itemCount > 0 }
    }

    /// Cover of a person, place or tag.
    public func photoGroupCoverURL(_ group: PhotoGroup, category: PhotoCategory, space: PhotoSpace,
                                   size: ThumbnailSize = .small) throws -> URL? {
        guard let key = group.coverCacheKey else { return nil }
        let isPerson = category == .person
        guard let id = isPerson ? group.id : group.coverID else { return nil }
        return try authenticatedURL(api: "\(space.rawValue).Thumbnail", method: "get", preferredVersion: 1, params: [
            "id": String(id),
            "cache_key": FSParam.string(key),
            "type": FSParam.string(isPerson ? "person" : "unit"),
            "size": FSParam.string(size.rawValue),
        ])
    }

    // MARK: Folders

    /// The space's root folder, or the folder with `id`.
    public func photoFolder(space: PhotoSpace, id: Int? = nil) async throws -> PhotoFolder {
        struct R: Decodable { let folder: PhotoFolder }
        var params: [String: String] = [:]
        if let id { params["id"] = String(id) }
        let r: R = try await call("\(space.rawValue).Browse.Folder", method: "get", version: 1, params: params)
        return r.folder
    }

    public func photoSubfolders(space: PhotoSpace, of parent: Int, offset: Int = 0, limit: Int = 500) async throws -> [PhotoFolder] {
        struct R: Decodable { let list: [PhotoFolder] }
        let r: R = try await call("\(space.rawValue).Browse.Folder", method: "list", version: 1, params: [
            "id": String(parent),
            "offset": String(offset), "limit": String(limit),
            "sort_by": FSParam.string("filename"),
            "sort_direction": FSParam.string("asc"),
        ])
        return r.list
    }

    /// File Station path of an item, for share links. Nil when the item's folder is unknown.
    public func photoFileStationPath(of item: PhotoItem, space: PhotoSpace) async throws -> String? {
        guard let folderID = item.folderID else { return nil }
        let folder = try await photoFolder(space: space, id: folderID)
        return space.fileStationPath(of: folder.path) + "/" + item.filename
    }

    // MARK: Favourites (a normal album in the personal space)

    /// The favourites album, created on first use when `create` is true.
    public func favoritesAlbum(create: Bool) async throws -> PhotoAlbum? {
        if let found = try await photoAlbums(limit: 1000).first(where: { $0.name == Self.favoritesAlbumName }) {
            return found
        }
        guard create else { return nil }
        struct R: Decodable { let album: PhotoAlbum }
        let r: R = try await call("SYNO.Foto.Browse.NormalAlbum", method: "create", version: 1, params: [
            "name": FSParam.string(Self.favoritesAlbumName),
            "item": "[]",
        ])
        return r.album
    }

    public func addPhotos(_ ids: [Int], toAlbum album: Int) async throws {
        let _: EmptyData = try await call("SYNO.Foto.Browse.NormalAlbum", method: "add_item", version: 1, params: [
            "id": String(album),
            "item": "[\(ids.map(String.init).joined(separator: ","))]",
        ])
    }

    public func removePhotos(_ ids: [Int], fromAlbum album: Int) async throws {
        let _: EmptyData = try await call("SYNO.Foto.Browse.NormalAlbum", method: "remove_item", version: 1, params: [
            "id": String(album),
            "item": "[\(ids.map(String.init).joined(separator: ","))]",
        ])
    }

    /// Ids of the photos in the favourites album; empty when the album does not exist yet.
    public func favoritePhotoIDs() async throws -> Set<Int> {
        guard let album = try await favoritesAlbum(create: false) else { return [] }
        return Set(try await photos(space: .personal, albumID: album.id, limit: 5000).map(\.id))
    }

    // MARK: Upload

    /// Uploads a file from the phone into a Synology Photos folder through File Station.
    /// Synology Photos indexes new files in its folders on its own, usually within a minute.
    @discardableResult
    public func uploadPhoto(fileAt local: URL, space: PhotoSpace, folderPath: String? = nil) async throws -> String {
        let target = folderPath.map { space.fileStationPath(of: $0) } ?? space.fileStationRoot + "/Upload"
        try await upload(fileAt: local, to: target)
        return target
    }
}
