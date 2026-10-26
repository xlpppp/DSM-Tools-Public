import Foundation
import DSMKit

public struct ImmichAsset: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let type: String
    public let originalFileName: String
    public let fileCreatedAt: String?

    public var isVideo: Bool { type == "VIDEO" }
}

public struct ImmichAlbum: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let albumName: String
    public let assetCount: Int
    public let albumThumbnailAssetId: String?
}

/// Immich with an API key (Account Settings › API Keys). The key goes in a header, never in URLs.
public final class ImmichClient: @unchecked Sendable {
    let http: ServiceHTTP
    let apiKey: String

    public init(account: ServiceAccount, apiKey: String, transport: HTTPTransport) throws {
        guard let base = account.baseURL else { throw ServiceError.invalidAddress }
        http = ServiceHTTP(base: base.path.hasSuffix("/api") ? base : base.appendingPathComponent("api"), transport: transport)
        self.apiKey = apiKey
    }

    public var headers: [String: String] { ["x-api-key": apiKey, "Accept": "application/json"] }

    /// Validates the key; returns the user's name.
    public func me() async throws -> String {
        struct R: Decodable { let name: String }
        return try await http.get(R.self, http.url("users/me"), headers: headers).name
    }

    /// Newest first, `page` starting at 1.
    public func timeline(page: Int = 1, size: Int = 200) async throws -> [ImmichAsset] {
        struct R: Decodable {
            struct A: Decodable { let items: [ImmichAsset] }
            let assets: A
        }
        let data = try await http.data("POST", http.url("search/metadata"), headers: headers,
                                       json: ["page": page, "size": size, "order": "desc", "withExif": false])
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { throw ServiceError.invalidResponse }
        return r.assets.items
    }

    public func albums() async throws -> [ImmichAlbum] {
        try await http.get([ImmichAlbum].self, http.url("albums"), headers: headers)
    }

    public func assets(inAlbum id: String) async throws -> [ImmichAsset] {
        struct R: Decodable { let assets: [ImmichAsset] }
        return try await http.get(R.self, http.url("albums/\(id)"), headers: headers).assets
    }

    public func thumbnailURL(_ id: String, preview: Bool = false) -> URL {
        http.url("assets/\(id)/thumbnail", query: ["size": preview ? "preview" : "thumbnail"])
    }

    public func originalURL(_ id: String) -> URL { http.url("assets/\(id)/original") }
    public func videoURL(_ id: String) -> URL { http.url("assets/\(id)/video/playback") }

    public func fetch(_ url: URL) async throws -> Data { try await http.data("GET", url, headers: headers) }
}
