import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DSMKit

/// Third-party media servers the user can add. Each has its own credentials; NAS credentials are never sent to them.
public enum ServiceKind: String, Codable, CaseIterable, Sendable {
    case jellyfin, emby, immich, navidrome

    public var title: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .immich: return "Immich"
        case .navidrome: return "Navidrome"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .jellyfin, .emby: return 8096
        case .immich: return 2283
        case .navidrome: return 4533
        }
    }

    /// Immich authenticates with an API key instead of a password.
    public var usesAPIKey: Bool { self == .immich }
}

public struct ServiceAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: ServiceKind
    public var name: String
    /// e.g. "http://192.0.2.10:8096" or "https://music.example.com".
    public var address: String
    public var username: String
    public var pinnedCertificateSHA256: String?
    /// LAN address. Empty on accounts saved before dual addresses existed.
    public var lanAddress: String
    /// WAN address. Tried only when the LAN port does not accept a connection.
    public var wanAddress: String
    /// NAS this account belongs to. Nil only in JSON saved before accounts were scoped to a device.
    public var deviceID: UUID?

    public init(id: UUID = UUID(), kind: ServiceKind, name: String, address: String, username: String = "",
                pinnedCertificateSHA256: String? = nil, lanAddress: String = "", wanAddress: String = "",
                deviceID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.address = address
        self.username = username
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
        self.lanAddress = lanAddress
        self.wanAddress = wanAddress
        self.deviceID = deviceID
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, address, username, pinnedCertificateSHA256, lanAddress, wanAddress, deviceID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ServiceKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        pinnedCertificateSHA256 = try c.decodeIfPresent(String.self, forKey: .pinnedCertificateSHA256)
        lanAddress = try c.decodeIfPresent(String.self, forKey: .lanAddress) ?? ""
        wanAddress = try c.decodeIfPresent(String.self, forKey: .wanAddress) ?? ""
        deviceID = try c.decodeIfPresent(UUID.self, forKey: .deviceID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(address, forKey: .address)
        try c.encode(username, forKey: .username)
        try c.encodeIfPresent(pinnedCertificateSHA256, forKey: .pinnedCertificateSHA256)
        try c.encode(lanAddress, forKey: .lanAddress)
        try c.encode(wanAddress, forKey: .wanAddress)
        try c.encodeIfPresent(deviceID, forKey: .deviceID)
    }

    /// What the list shows. Both addresses when the user filled them in.
    public var summaryAddress: String {
        let lan = lanAddress.trimmingCharacters(in: .whitespaces)
        let wan = wanAddress.trimmingCharacters(in: .whitespaces)
        if !lan.isEmpty && !wan.isEmpty { return "\(lan) / \(wan)" }
        if !lan.isEmpty { return lan }
        if !wan.isEmpty { return wan }
        return address
    }

    /// Picks the LAN address when its port accepts a TCP connection, otherwise the WAN address.
    /// A certificate error is not part of this check. Accounts with only `address` stay as they are.
    public static func preferredAddress(_ account: ServiceAccount,
                                        probe: @Sendable (_ host: String, _ port: Int) async -> Bool) async -> String {
        let lan = account.lanAddress.trimmingCharacters(in: .whitespaces)
        let wan = account.wanAddress.trimmingCharacters(in: .whitespaces)
        if lan.isEmpty && wan.isEmpty { return account.address }
        if let parts = hostPort(lan, defaultPort: account.kind.defaultPort), await probe(parts.host, parts.port) { return lan }
        if let parts = hostPort(wan, defaultPort: account.kind.defaultPort), await probe(parts.host, parts.port) { return wan }
        if !lan.isEmpty { return lan }
        if !wan.isEmpty { return wan }
        return account.address
    }

    static func hostPort(_ address: String, defaultPort: Int) -> (host: String, port: Int)? {
        var text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
        return (host, url.port ?? defaultPort)
    }

    public var baseURL: URL? {
        var text = address.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }
}

public enum ServiceError: Error, Equatable, Sendable {
    case invalidAddress
    case unauthorized
    case http(Int)
    case server(String)
    case invalidResponse

    public var message: String {
        switch self {
        case .invalidAddress: return "服务地址格式不正确"
        case .unauthorized: return "账号、密码或 API Key 不正确"
        case .http(let code): return "服务器返回错误（HTTP \(code)）"
        case .server(let text): return text
        case .invalidResponse: return "服务器返回了无法识别的数据"
        }
    }
}

/// Shared JSON-over-HTTP plumbing for the service clients.
struct ServiceHTTP: Sendable {
    let base: URL
    let transport: HTTPTransport

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return c.url!
    }

    func data(_ method: String = "GET", _ url: URL, headers: [String: String] = [:], json: Any? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw ServiceError.unauthorized
        default: throw ServiceError.http(response.statusCode)
        }
    }

    func get<T: Decodable>(_ type: T.Type, _ url: URL, headers: [String: String] = [:]) async throws -> T {
        let data = try await data("GET", url, headers: headers)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ServiceError.invalidResponse }
    }
}
