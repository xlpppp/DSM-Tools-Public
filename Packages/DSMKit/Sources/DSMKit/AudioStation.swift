import Foundation

public struct Song: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let path: String?
    public let artist: String?
    public let album: String?
    public let albumArtist: String?
    public let track: Int?
    public let duration: Int?
    public let codec: String?
    public let bitrate: Int?

    enum CodingKeys: String, CodingKey { case id, title, path, additional }
    struct Additional: Decodable {
        struct Tag: Decodable { let artist: String?; let album: String?; let album_artist: String?; let track: FlexInt? }
        struct Audio: Decodable { let duration: FlexInt?; let codec: String?; let bitrate: FlexInt? }
        let song_tag: Tag?
        let song_audio: Audio?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        let a = try c.decodeIfPresent(Additional.self, forKey: .additional)
        let rawTitle = try c.decodeIfPresent(String.self, forKey: .title)?.nilIfEmpty
        title = rawTitle ?? path.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? id
        artist = a?.song_tag?.artist?.nilIfEmpty
        album = a?.song_tag?.album?.nilIfEmpty
        albumArtist = a?.song_tag?.album_artist?.nilIfEmpty
        track = a?.song_tag?.track?.value
        duration = a?.song_audio?.duration?.value
        codec = a?.song_audio?.codec
        bitrate = a?.song_audio?.bitrate?.value
    }

    /// Formats iOS can't decode natively get transcoded to MP3 by Audio Station.
    public var needsTranscode: Bool {
        guard let codec = codec?.lowercased() else { return false }
        return ["ape", "wma", "wmav2", "dsd", "dsf", "dff", "ogg", "vorbis", "opus"].contains { codec.contains($0) }
    }
}

public struct MusicAlbum: Decodable, Identifiable, Hashable, Sendable {
    public let name: String
    public let artist: String
    public let year: Int?
    public var id: String { "\(artist)\u{1F}\(name)" }

    enum CodingKeys: String, CodingKey { case name, album_artist, display_artist, year }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let albumArtist = try c.decodeIfPresent(String.self, forKey: .album_artist)?.nilIfEmpty
        artist = try albumArtist ?? c.decodeIfPresent(String.self, forKey: .display_artist) ?? ""
        let y = (try? c.decodeIfPresent(FlexInt.self, forKey: .year)) ?? nil
        year = y.flatMap { $0.value > 0 ? $0.value : nil }
    }
}

public struct MusicPlaylist: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
}

public struct MusicName: Decodable, Identifiable, Hashable, Sendable {
    public let name: String
    /// Folder or group id when the API has one; otherwise the display name.
    public let token: String
    public var id: String { token }

    enum CodingKeys: String, CodingKey { case name, title, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)?.nilIfEmpty
            ?? c.decodeIfPresent(String.self, forKey: .title)?.nilIfEmpty
            ?? ""
        if let text = try? c.decode(String.self, forKey: .id), !text.isEmpty {
            token = text
        } else if let number = try? c.decode(FlexInt.self, forKey: .id) {
            token = String(number.value)
        } else {
            token = name
        }
    }
}

public struct MusicRadio: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String

    enum CodingKeys: String, CodingKey { case id, title, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? c.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try c.decode(FlexInt.self, forKey: .id).value)
        }
        title = try c.decodeIfPresent(String.self, forKey: .title)?.nilIfEmpty
            ?? c.decodeIfPresent(String.self, forKey: .name)?.nilIfEmpty
            ?? id
    }
}

public struct MusicFolderPage: Sendable {
    public let folders: [MusicName]
    public let songs: [Song]

    public init(folders: [MusicName], songs: [Song]) {
        self.folders = folders
        self.songs = songs
    }
}

extension DSMClient {
    public var hasAudioStation: Bool { supports("SYNO.AudioStation.Song") }

    static let songAdditional = "song_tag,song_audio"

    public func songs(album: MusicAlbum? = nil, keyword: String? = nil, artist: String? = nil,
                      composer: String? = nil, genre: String? = nil, offset: Int = 0, limit: Int = 500) async throws -> [Song] {
        struct R: Decodable { let songs: [Song] }
        var params = [
            "library": "all", "offset": String(offset), "limit": String(limit),
            "additional": Self.songAdditional,
        ]
        if let album {
            params["album"] = album.name
            params["album_artist"] = album.artist
            params["sort_by"] = "track"
        } else {
            params["sort_by"] = "title"
        }
        if let artist, !artist.isEmpty { params["artist"] = artist }
        if let composer, !composer.isEmpty { params["composer"] = composer }
        if let genre, !genre.isEmpty { params["genre"] = genre }
        if let keyword, !keyword.isEmpty { params["keyword"] = keyword }
        let r: R = try await call("SYNO.AudioStation.Song", method: keyword == nil ? "list" : "search", version: 2, params: params)
        return r.songs
    }

    public func musicAlbums(offset: Int = 0, limit: Int = 1000, sort: String = "name") async throws -> [MusicAlbum] {
        struct R: Decodable { let albums: [MusicAlbum] }
        let r: R = try await call("SYNO.AudioStation.Album", method: "list", version: 2, params: [
            "library": "all", "offset": String(offset), "limit": String(limit),
            "sort_by": sort, "sort_direction": sort == "name" ? "asc" : "desc",
        ])
        return r.albums
    }

    /// Artist, composer or genre names. `listKey` is the array in the response (`artists`, `composers`, `genres`).
    public func musicGroups(api: String, listKey: String) async throws -> [MusicName] {
        guard supports(api) else { throw DSMError.apiUnavailable(api) }
        let r: [String: JSONValue] = try await call(api, method: "list", version: 2, params: [
            "library": "all", "offset": "0", "limit": "500", "sort_by": "name", "sort_direction": "asc",
        ])
        return r[listKey]?.decode([MusicName].self)?.filter { !$0.name.isEmpty } ?? []
    }

    public func musicRadios() async throws -> [MusicRadio] {
        guard supports("SYNO.AudioStation.Radio") else { throw DSMError.apiUnavailable("SYNO.AudioStation.Radio") }
        struct R: Decodable { let radios: [MusicRadio]? }
        let r: R = try await call("SYNO.AudioStation.Radio", method: "list", version: 2, params: [
            "library": "all", "offset": "0", "limit": "200",
        ])
        return r.radios ?? []
    }

    public func musicFolderPage(id: String = "") async throws -> MusicFolderPage {
        guard supports("SYNO.AudioStation.Folder") else { throw DSMError.apiUnavailable("SYNO.AudioStation.Folder") }
        var params = ["library": "all", "offset": "0", "limit": "500", "additional": Self.songAdditional]
        if !id.isEmpty { params["id"] = id }
        let r: [String: JSONValue] = try await call("SYNO.AudioStation.Folder", method: "list", version: 2, params: params)
        return MusicFolderPage(
            folders: r["folders"]?.decode([MusicName].self)?.filter { !$0.name.isEmpty } ?? [],
            songs: r["songs"]?.decode([Song].self) ?? []
        )
    }

    public func musicPlaylists() async throws -> [MusicPlaylist] {
        struct R: Decodable { let playlists: [MusicPlaylist] }
        let r: R = try await call("SYNO.AudioStation.Playlist", method: "list", version: 2, params: [
            "library": "all", "offset": "0", "limit": "1000",
        ])
        return r.playlists
    }

    public func playlistSongs(_ id: String) async throws -> [Song] {
        struct R: Decodable {
            struct P: Decodable {
                struct A: Decodable { let songs: [Song]? }
                let additional: A?
            }
            let playlists: [P]
        }
        let r: R = try await call("SYNO.AudioStation.Playlist", method: "getinfo", version: 2, params: [
            "library": "all", "id": id, "additional": "songs_song_tag,songs_song_audio",
        ])
        return r.playlists.first?.additional?.songs ?? []
    }

    /// Streams the original file, or MP3 when iOS can't play the codec.
    public func streamURL(for song: Song) throws -> URL {
        if song.needsTranscode {
            return try authenticatedURL(api: "SYNO.AudioStation.Stream", method: "transcode", preferredVersion: 2,
                                        params: ["id": song.id, "format": "mp3"], pathSuffix: "/0.mp3")
        }
        let ext = song.path.map { ($0 as NSString).pathExtension }.flatMap { $0.isEmpty ? nil : $0 } ?? "mp3"
        return try authenticatedURL(api: "SYNO.AudioStation.Stream", method: "stream", preferredVersion: 2,
                                    params: ["id": song.id], pathSuffix: "/0.\(ext)")
    }

    public func coverURL(for song: Song) throws -> URL {
        try authenticatedURL(api: "SYNO.AudioStation.Cover", method: "getsongcover", preferredVersion: 3, params: ["id": song.id])
    }

    public func coverURL(for album: MusicAlbum) throws -> URL {
        try authenticatedURL(api: "SYNO.AudioStation.Cover", method: "getcover", preferredVersion: 3, params: [
            "album_name": album.name, "album_artist_name": album.artist,
        ])
    }
}
