import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Picks the address to use right now. Reachability is a TCP connect to the saved port, so a
/// self-signed certificate does not make the LAN look down. The first open port in the user's
/// order wins; the HTTPS API call, and any certificate prompt, happen only for that address.
public struct EndpointResolver: Sendable {
    public typealias TransportFactory = @Sendable (Endpoint) -> HTTPTransport
    public typealias Probe = @Sendable (_ host: String, _ port: Int) async -> Bool

    private let makeTransport: TransportFactory
    private let makeSessionTransport: TransportFactory
    private let quickConnect: QuickConnectResolver
    private let probe: Probe

    /// `makeTransport` is for the probes, which should give up fast. The returned client gets a
    /// transport from `makeSessionTransport` instead: heavy calls (Log Center, big listings) over
    /// WAN routinely take longer than a probe is allowed to. Defaults to `makeTransport` when only
    /// that one is given.
    public init(makeTransport: TransportFactory? = nil,
                makeSessionTransport: TransportFactory? = nil,
                quickConnect: QuickConnectResolver = QuickConnectResolver(),
                probe: Probe? = nil) {
        self.makeTransport = makeTransport ?? { URLSessionTransport(pinnedSHA256: $0.pinnedCertificateSHA256, timeout: 4) }
        self.makeSessionTransport = makeSessionTransport ?? makeTransport
            ?? { URLSessionTransport(pinnedSHA256: $0.pinnedCertificateSHA256, timeout: 30) }
        self.quickConnect = quickConnect
        self.probe = probe ?? { await PortProbe.isOpen(host: $0, port: $1) }
    }

    public struct Resolution: Sendable {
        public let endpoint: Endpoint
        public let client: DSMClient
    }

    public func resolve(_ configured: [Endpoint]) async throws -> Resolution {
        guard !configured.isEmpty else { throw DSMError.unreachable }

        // QuickConnect IDs expand into the addresses Synology knows for the NAS, in place,
        // so the user's ordering still decides priority.
        var endpoints: [Endpoint] = []
        var origins: [Endpoint] = []
        var lookupError: Error?
        for endpoint in configured {
            if endpoint.isQuickConnectID {
                do {
                    let found = try await quickConnect.endpoints(for: endpoint.host, https: endpoint.useHTTPS,
                                                                 pinnedSHA256: endpoint.pinnedCertificateSHA256)
                    endpoints += found
                    origins += Array(repeating: endpoint, count: found.count)
                } catch {
                    lookupError = error
                }
            } else {
                endpoints.append(endpoint)
                origins.append(endpoint)
            }
        }
        if endpoints.isEmpty { throw lookupError ?? DSMError.unreachable }

        let open = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, endpoint) in endpoints.enumerated() {
                group.addTask { (index, await probe(endpoint.host, endpoint.port)) }
            }
            var flags = Array(repeating: false, count: endpoints.count)
            for await (index, reachable) in group { flags[index] = reachable }
            return flags
        }

        var lastError: Error?
        for (index, endpoint) in endpoints.enumerated() where open[index] {
            guard let url = endpoint.baseURL else { continue }
            let probed = DSMClient(baseURL: url, transport: makeTransport(endpoint))
            do {
                try await probed.loadAPIInfo()
                let client = DSMClient(baseURL: probed.baseURL, transport: makeSessionTransport(endpoint),
                                       apis: await probed.apis)
                return Resolution(endpoint: endpoint, client: client)
            } catch let error as DSMError {
                if case .untrustedCertificate(_, let fp) = error {
                    // Report the address that failed, not the QuickConnect ID. Pinning the ID
                    // would copy one LAN certificate onto every resolved address.
                    throw DSMError.untrustedCertificate(host: endpoint.host, fingerprint: fp)
                }
                lastError = error
            } catch {
                lastError = error
            }
        }
        if let lastError, (lastError as? DSMError) != .timedOut { throw lastError }
        throw DSMError.unreachable
    }
}
