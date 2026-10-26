import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Sends one HTTP request. Abstracted so the client can be tested without a NAS.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Sends `request` with the contents of `file` as its body (used for multipart uploads).
    func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse)
    /// Downloads the response body to a temporary file (used for large files).
    func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

extension HTTPTransport {
    public func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
        var r = request
        r.httpBody = try Data(contentsOf: file)
        return try await send(r)
    }

    public func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (data, response) = try await send(request)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        return (file, response)
    }
}

/// URLSession-backed transport. On Apple platforms it honours a pinned certificate
/// fingerprint, which is how a self-signed DSM certificate gets trusted explicitly.
public final class URLSessionTransport: NSObject, HTTPTransport, @unchecked Sendable {
    private let pinnedSHA256: String?
    private let timeout: TimeInterval
    private var session: URLSession!
    private let lock = NSLock()
    private var lastSeenFingerprint: [String: String] = [:]

    public init(pinnedSHA256: String? = nil, timeout: TimeInterval = 15) {
        self.pinnedSHA256 = pinnedSHA256?.normalizedFingerprint
        self.timeout = timeout
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await run(request) { try await self.session.data(for: request) }
    }

    public func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
        // Uploads can be large and slow; give them far more time than API calls.
        var r = request
        r.timeoutInterval = 3600
        return try await run(r) { try await self.session.upload(for: r, fromFile: file) }
    }

    public func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        var r = request
        r.timeoutInterval = 3600
        let (temp, response) = try await run(r) { () async throws -> (URL, URLResponse) in
            try await self.session.download(for: r)
        }
        // URLSession deletes its temp file once the call returns; move it somewhere we own.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: temp, to: file)
        return (file, response)
    }

    private func run<T>(_ request: URLRequest,
                        _ operation: () async throws -> (T, URLResponse)) async throws -> (T, HTTPURLResponse) {
        do {
            let (data, response) = try await operation()
            guard let http = response as? HTTPURLResponse else { throw DSMError.invalidResponse }
            return (data, http)
        } catch let error as URLError {
            let host = request.url?.host ?? ""
            switch error.code {
            case .cancelled:
                // Our delegate cancels the handshake when a pinned certificate no longer matches.
                if let pinned = pinnedSHA256, let fp = fingerprint(for: host), fp != pinned {
                    throw DSMError.untrustedCertificate(host: host, fingerprint: fp)
                }
                throw CancellationError()
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .secureConnectionFailed:
                throw DSMError.untrustedCertificate(host: host, fingerprint: fingerprint(for: host))
            case .timedOut:
                throw DSMError.timedOut
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed:
                throw DSMError.unreachable
            default:
                throw DSMError.transport(error.localizedDescription)
            }
        }
    }

    private func fingerprint(for host: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return lastSeenFingerprint[host]
    }

    fileprivate func record(fingerprint: String, host: String) {
        lock.lock(); defer { lock.unlock() }
        lastSeenFingerprint[host] = fingerprint
    }
}

extension URLSessionTransport: URLSessionDelegate {
    #if canImport(Security) && canImport(CryptoKit)
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        let leafFingerprint = Self.leafFingerprint(trust)
        if let fp = leafFingerprint { record(fingerprint: fp, host: host) }

        if let pinned = pinnedSHA256 {
            // The user explicitly trusted this exact certificate; accept it and nothing else.
            if leafFingerprint == pinned {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    public static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    #endif
}

extension String {
    /// Upper-case, colon-separated form so fingerprints compare regardless of how they were typed.
    var normalizedFingerprint: String {
        let hex = uppercased().filter { $0.isHexDigit }
        var pairs: [String] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            pairs.append(String(hex[i..<j]))
            i = j
        }
        return pairs.joined(separator: ":")
    }
}
