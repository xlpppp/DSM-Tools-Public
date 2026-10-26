import Foundation

/// HTTP/HTTPS ports DSM itself is listening on (Control Panel › Login Portal), not a reverse proxy.
public struct DSMWebPorts: Equatable, Sendable {
    public var httpEnabled: Bool
    public var httpPort: Int
    public var httpsEnabled: Bool
    public var httpsPort: Int

    public init(httpEnabled: Bool, httpPort: Int, httpsEnabled: Bool, httpsPort: Int) {
        self.httpEnabled = httpEnabled
        self.httpPort = httpPort
        self.httpsEnabled = httpsEnabled
        self.httpsPort = httpsPort
    }
}

/// Which URL the in-app DSM desktop should open.
public enum DSMWebAddress {
    /// On the LAN, open the NAS IP with the port DSM reports. From outside, keep the saved WAN
    /// host and port — the internal DSM port is usually not forwarded.
    public static func url(endpoint: Endpoint, ports: DSMWebPorts?) -> URL? {
        guard endpoint.kind == .lan, let ports, !endpoint.host.isEmpty else { return endpoint.baseURL }
        let https = ports.httpsEnabled || !ports.httpEnabled
        var c = URLComponents()
        c.scheme = https ? "https" : "http"
        c.host = endpoint.host
        c.port = https ? ports.httpsPort : ports.httpPort
        return c.url
    }
}

extension DSMClient {
    /// `SYNO.Core.Web.DSM` `get`. Field names match DSM 7; a missing flag means that scheme is off.
    public func webPorts() async throws -> DSMWebPorts {
        struct R: Decodable {
            let http_port: FlexInt?
            let https_port: FlexInt?
            let enable_http: Bool?
            let enable_https: Bool?
        }
        let r: R = try await call("SYNO.Core.Web.DSM", method: "get", version: 1)
        return DSMWebPorts(httpEnabled: r.enable_http ?? false,
                           httpPort: r.http_port?.value ?? 5000,
                           httpsEnabled: r.enable_https ?? false,
                           httpsPort: r.https_port?.value ?? 5001)
    }
}
