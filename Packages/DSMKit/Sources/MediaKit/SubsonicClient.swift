import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import DSMKit

/// Navidrome via the Subsonic API. Every request carries a salted MD5 token, never the password itself.
public struct SubsonicAlbum: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let artist: String?
    public let year: Int?
    public let coverArt: String?
    public let songCount: Int?
}

public struct SubsonicSong: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let artist: String?
    public let album: String?
    public let duration: Int?
    public let track: Int?
    public let coverArt: String?
    public let suffix: String?
}

public struct SubsonicPlaylist: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let songCount: Int?
}

public final class SubsonicClient: @unchecked Sendable {
    let http: ServiceHTTP
    let username: String
    let password: String
    /// Fixed salt per client keeps URLs (and the image cache) stable for the session.
    let salt: String

    public init(account: ServiceAccount, password: String, transport: HTTPTransport,
                salt: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) throws {
        guard let base = account.baseURL else { throw ServiceError.invalidAddress }
        http = ServiceHTTP(base: base.appendingPathComponent("rest"), transport: transport)
        username = account.username
        self.password = password
        self.salt = salt
    }

    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var auth: [String: String] {
        ["u": username, "t": Self.md5Hex(password + salt), "s": salt, "v": "1.16.1", "c": "NASHelper", "f": "json"]
    }

    func url(_ endpoint: String, _ query: [String: String] = [:]) -> URL {
        http.url("\(endpoint).view", query: auth.merging(query) { _, new in new })
    }

    /// Unwraps {"subsonic-response": {...}} and turns status "failed" into an error.
    func call(_ endpoint: String, _ query: [String: String] = [:]) async throws -> JSONValue {
        let data = try await http.data("GET", url(endpoint, query))
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let body = root["subsonic-response"] else { throw ServiceError.invalidResponse }
        if body["status"]?.string == "failed" {
            let code = body["error"]?["code"]?.int64 ?? 0
            // 40: wrong credentials, 41: token auth not supported for this user.
            if code == 40 || code == 41 { throw ServiceError.unauthorized }
            throw ServiceError.server(body["error"]?["message"]?.string ?? "Navidrome 返回错误")
        }
        return body
    }

    public func ping() async throws {
        _ = try await call("ping")
    }

    public func albums(_ type: String = "newest", offset: Int = 0, size: Int = 200) async throws -> [SubsonicAlbum] {
        let body = try await call("getAlbumList2", ["type": type, "size": String(size), "offset": String(offset)])
        return body["albumList2"]?["album"]?.decode([SubsonicAlbum].self) ?? []
    }

    public func songs(inAlbum id: String) async throws -> [SubsonicSong] {
        let body = try await call("getAlbum", ["id": id])
        return body["album"]?["song"]?.decode([SubsonicSong].self) ?? []
    }

    public func playlists() async throws -> [SubsonicPlaylist] {
        let body = try await call("getPlaylists")
        return body["playlists"]?["playlist"]?.decode([SubsonicPlaylist].self) ?? []
    }

    public func songs(inPlaylist id: String) async throws -> [SubsonicSong] {
        let body = try await call("getPlaylist", ["id": id])
        return body["playlist"]?["entry"]?.decode([SubsonicSong].self) ?? []
    }

    public func search(_ text: String) async throws -> (albums: [SubsonicAlbum], songs: [SubsonicSong]) {
        let body = try await call("search3", ["query": text, "songCount": "50", "albumCount": "30", "artistCount": "0"])
        let result = body["searchResult3"]
        return (result?["album"]?.decode([SubsonicAlbum].self) ?? [], result?["song"]?.decode([SubsonicSong].self) ?? [])
    }

    /// Credentials are in the query (Subsonic's design); don't log these URLs.
    public func streamURL(for song: SubsonicSong) -> URL { url("stream", ["id": song.id]) }

    public func coverURL(_ coverArt: String, size: Int = 600) -> URL { url("getCoverArt", ["id": coverArt, "size": String(size)]) }

    public func fetch(_ url: URL) async throws -> Data { try await http.data("GET", url) }
}

