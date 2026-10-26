import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Turns a QuickConnect ID into concrete addresses by asking Synology's QuickConnect servers,
/// the same way DSM's own apps do. Only the ID is sent; no NAS credentials leave the app.
///
/// Order returned: the NAS's LAN interfaces, its DDNS / FQDN, its public IP, then the relay.
/// The relay always works when QuickConnect is enabled but is slow, so it is the last resort.
public struct QuickConnectResolver: Sendable {
    let transport: HTTPTransport
    /// China-registered IDs live on quickconnect.cn; the global server answers with a redirect
    /// ("sites") for those, so both are tried.
    static let servers = ["global.quickconnect.to", "global.quickconnect.cn"]

    public init(transport: HTTPTransport = URLSessionTransport(timeout: 8)) {
        self.transport = transport
    }

    public func endpoints(for id: String, https: Bool = true, pinnedSHA256: String? = nil) async throws -> [Endpoint] {
        let id = id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { throw DSMError.unreachable }
        var hosts = Self.servers
        var tried = Set<String>()
        while let host = hosts.first {
            hosts.removeFirst()
            guard tried.insert(host).inserted else { continue }
            guard let info = try? await serverInfo(id: id, https: https, server: host) else { continue }
            if let found = info.endpoints(id: id, https: https, pinnedSHA256: pinnedSHA256, server: host), !found.isEmpty {
                return found
            }
            hosts.insert(contentsOf: info.sites, at: 0)
        }
        throw DSMError.transport("找不到 QuickConnect ID「\(id)」，或该 NAS 未启用 QuickConnect")
    }

    func serverInfo(id: String, https: Bool, server: String) async throws -> ServerInfo {
        guard let url = URL(string: "https://\(server)/Serv.php") else { throw DSMError.unreachable }
        let service = https ? "dsm_portal_https" : "dsm_portal"
        let body: [[String: JSONValue]] = [[
            "version": .number(1), "command": .string("get_server_info"), "stop_when_error": .bool(false),
            "stop_when_success": .bool(false), "id": .string(service), "serverID": .string(id), "is_gofile": .bool(false),
        ]]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw DSMError.transport("HTTP \(response.statusCode)") }
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        // The reply is an array with one element per request, or a bare object.
        guard let first = root.array?.first ?? (root["errno"] != nil ? root : nil) else { throw DSMError.invalidResponse }
        return ServerInfo(json: first)
    }

    struct ServerInfo {
        let errno: Int
        let lanIPs: [String]
        let externalIP: String?
        let hostnames: [String]
        let port: Int?
        let externalPort: Int?
        let relayRegion: String?
        let sites: [String]

        init(json v: JSONValue) {
            errno = Int(v["errno"]?.int64 ?? 0)
            let server = v["server"]
            lanIPs = server?["interface"]?.array?.compactMap { $0["ip"]?.string }.filter { !$0.isEmpty && $0 != "0.0.0.0" } ?? []
            externalIP = server?["external"]?["ip"]?.string.flatMap { $0.isEmpty || $0 == "0.0.0.0" ? nil : $0 }
            hostnames = [server?["ddns"]?.string, server?["fqdn"]?.string]
                .compactMap { $0 }
                .filter { !$0.isEmpty && $0.uppercased() != "NULL" }
            port = v["service"]?["port"]?.int64.map(Int.init)
            externalPort = v["service"]?["ext_port"]?.int64.map(Int.init).flatMap { $0 > 0 ? $0 : nil }
            relayRegion = v["env"]?["relay_region"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            sites = v["sites"]?.array?.compactMap(\.string) ?? []
        }

        func endpoints(id: String, https: Bool, pinnedSHA256: String?, server: String) -> [Endpoint]? {
            guard errno == 0 else { return nil }
            let local = port ?? (https ? 5001 : 5000)
            let external = externalPort ?? local
            var out: [Endpoint] = []
        for ip in lanIPs {
            out.append(Endpoint(kind: .lan, host: ip, port: local, useHTTPS: https, pinnedCertificateSHA256: pinnedSHA256))
        }
        for name in hostnames {
            // A pin accepted for the LAN certificate must not be sent to the public name.
            out.append(Endpoint(kind: .wan, host: name, port: external, useHTTPS: https))
        }
        if let externalIP {
            out.append(Endpoint(kind: .wan, host: externalIP, port: external, useHTTPS: https))
        }
            if let relayRegion {
                // Synology's relay has a publicly trusted certificate, so it is never pinned.
                let domain = server.hasSuffix(".cn") ? "quickconnect.cn" : "quickconnect.to"
                out.append(Endpoint(kind: .quickConnect, host: "\(id).\(relayRegion).\(domain)", port: 443, useHTTPS: true))
            }
            return out
        }
    }
}
