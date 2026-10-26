import Foundation

/// One way to reach a NAS. A device has several, tried in order.
public struct Endpoint: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case lan, wan, quickConnect

        public var label: String {
            switch self {
            case .lan: return "局域网"
            case .wan: return "外网"
            case .quickConnect: return "QuickConnect"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var host: String
    public var port: Int
    public var useHTTPS: Bool
    /// SHA-256 of a certificate the user chose to trust (self-signed). Nil = normal system validation.
    public var pinnedCertificateSHA256: String?

    public init(id: UUID = UUID(), kind: Kind, host: String, port: Int? = nil, useHTTPS: Bool = true,
                pinnedCertificateSHA256: String? = nil) {
        self.id = id
        self.kind = kind
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.useHTTPS = useHTTPS
        self.port = port ?? (useHTTPS ? 5001 : 5000)
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
    }

    public var baseURL: URL? {
        var c = URLComponents()
        c.scheme = useHTTPS ? "https" : "http"
        c.host = host
        c.port = port
        return c.url
    }

    public var display: String {
        isQuickConnectID ? "QuickConnect：\(host)" : "\(useHTTPS ? "https" : "http")://\(host):\(port)"
    }

    /// A QuickConnect endpoint the user entered holds the bare ID (no dots); the resolver turns it
    /// into real addresses. A resolved relay address has kind .quickConnect too, but a full hostname.
    public var isQuickConnectID: Bool { kind == .quickConnect && !host.contains(".") }
}

/// A saved NAS. Passwords are not stored here; the app keeps them in the Keychain under `id`.
public struct DeviceProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var endpoints: [Endpoint]
    public var username: String
    /// SSH is configured separately: its host, port and account can differ from DSM's.
    public var ssh: SSHSettings

    public init(id: UUID = UUID(), name: String, endpoints: [Endpoint], username: String,
                ssh: SSHSettings = SSHSettings()) {
        self.id = id
        self.name = name
        self.endpoints = endpoints
        self.username = username
        self.ssh = ssh
    }
}

public struct SSHSettings: Codable, Hashable, Sendable {
    /// Legacy single address. Empty when `lanHost` or `wanHost` is set.
    public var host: String
    public var port: Int
    /// Empty = reuse the DSM username.
    public var username: String
    /// SHA-256 of the host key the user accepted. Nil until first connection.
    public var trustedHostKeySHA256: String?
    /// LAN SSH address. Empty = don't add a LAN candidate of its own.
    public var lanHost: String
    public var lanPort: Int
    /// WAN SSH address, often a router-forwarded port that is not 22.
    public var wanHost: String
    public var wanPort: Int

    public init(host: String = "", port: Int = 22, username: String = "", trustedHostKeySHA256: String? = nil,
                lanHost: String = "", lanPort: Int = 22, wanHost: String = "", wanPort: Int = 22) {
        self.host = host
        self.port = port
        self.username = username
        self.trustedHostKeySHA256 = trustedHostKeySHA256
        self.lanHost = lanHost
        self.lanPort = lanPort
        self.wanHost = wanHost
        self.wanPort = wanPort
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, username, trustedHostKeySHA256, lanHost, lanPort, wanHost, wanPort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        trustedHostKeySHA256 = try c.decodeIfPresent(String.self, forKey: .trustedHostKeySHA256)
        lanHost = try c.decodeIfPresent(String.self, forKey: .lanHost) ?? ""
        lanPort = try c.decodeIfPresent(Int.self, forKey: .lanPort) ?? 22
        wanHost = try c.decodeIfPresent(String.self, forKey: .wanHost) ?? ""
        wanPort = try c.decodeIfPresent(Int.self, forKey: .wanPort) ?? 22
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encodeIfPresent(trustedHostKeySHA256, forKey: .trustedHostKeySHA256)
        try c.encode(lanHost, forKey: .lanHost)
        try c.encode(lanPort, forKey: .lanPort)
        try c.encode(wanHost, forKey: .wanHost)
        try c.encode(wanPort, forKey: .wanPort)
    }
}
