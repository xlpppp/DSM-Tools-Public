import Foundation
import Network
import DSMKit

/// Plays a remote file through 127.0.0.1 so AVPlayer never sees the NAS certificate or auth headers.
/// Range requests are forwarded. HLS playlists are rewritten back through this bridge.
final class MediaBridge: @unchecked Sendable {
    let localURL: URL
    private let listener: NWListener
    private let queue = DispatchQueue(label: "nas.media.bridge")
    private let upstream: URL
    private let pull: @Sendable (URLRequest) async throws -> (URL, HTTPURLResponse)
    private let port: UInt16

    static func start(upstream: URL, pull: @escaping @Sendable (URLRequest) async throws -> (URL, HTTPURLResponse)) async throws -> MediaBridge {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        return try await withCheckedThrowingContinuation { continuation in
            let box = ResumeBox(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let raw = listener.port?.rawValue else { return }
                    let bridge = MediaBridge(listener: listener, upstream: upstream, pull: pull, port: raw)
                    listener.newConnectionHandler = { bridge.accept($0) }
                    box.resume(bridge)
                case .failed(let error):
                    box.resume(error)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "nas.media.bridge.listen"))
        }
    }

    private init(listener: NWListener, upstream: URL, pull: @escaping @Sendable (URLRequest) async throws -> (URL, HTTPURLResponse), port: UInt16) {
        self.listener = listener
        self.upstream = upstream
        self.pull = pull
        self.port = port
        self.localURL = URL(string: "http://127.0.0.1:\(port)/play")!
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
    }

    func stop() {
        listener.cancel()
    }

    private static func mediaType(_ url: URL, header: String) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        default: return header.isEmpty ? "application/octet-stream" : header
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHeader(connection, buffer: Data())
    }

    private func readHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, _ in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer[..<range.lowerBound]
                let text = String(data: head, encoding: .utf8) ?? ""
                Task { await self.respond(connection, request: text) }
                return
            }
            if complete || buffer.count > 32_768 {
                connection.cancel()
                return
            }
            self.readHeader(connection, buffer: buffer)
        }
    }

    private func respond(_ connection: NWConnection, request: String) async {
        defer { connection.cancel() }
        let lines = request.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        let target = parts.count > 1 ? url(from: parts[1]) : upstream
        let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        var upstreamRequest = URLRequest(url: target)
        if let range { upstreamRequest.setValue(range, forHTTPHeaderField: "Range") }
        do {
            let (file, response) = try await pull(upstreamRequest)
            defer { try? FileManager.default.removeItem(at: file) }
            let headerType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
            let mime = Self.mediaType(target, header: headerType)
            if mime.contains("mpegurl") || target.path.lowercased().contains(".m3u8") {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                let rewritten = rewrite(text, playlist: target)
                let body = Data(rewritten.utf8)
                try await send(connection, status: 200, headers: [
                    "Content-Type": "application/vnd.apple.mpegurl",
                    "Content-Length": String(body.count),
                    "Connection": "close",
                ], body: body, file: nil)
                return
            }
            let length = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            var headers = [
                "Content-Type": mime.contains("json") ? "video/mp4" : mime,
                "Content-Length": String(length),
                "Accept-Ranges": "bytes",
                "Connection": "close",
            ]
            if let raw = response.value(forHTTPHeaderField: "Content-Range") { headers["Content-Range"] = raw }
            let status = response.statusCode == 206 ? 206 : 200
            try await send(connection, status: status, headers: headers, body: nil, file: file)
        } catch {
            let body = Data("unavailable".utf8)
            try? await send(connection, status: 502, headers: [
                "Content-Length": String(body.count), "Connection": "close",
            ], body: body, file: nil)
        }
    }

    private func url(from path: String) -> URL {
        guard let components = URLComponents(string: "http://127.0.0.1\(path.hasPrefix("/") ? path : "/" + path)"),
              let item = components.queryItems?.first(where: { $0.name == "u" })?.value,
              let decoded = item.removingPercentEncoding, let remote = URL(string: decoded) else { return upstream }
        return remote
    }

    private func rewrite(_ text: String, playlist: URL) -> String {
        let base = playlist.deletingLastPathComponent()
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") && !trimmed.contains("URI=") { return raw }
            if trimmed.contains("URI=\"") { return raw.replacingURI { self.local($0, base: base) } }
            if trimmed.hasPrefix("#") { return raw }
            return local(trimmed, base: base)
        }.joined(separator: "\n")
    }

    private func local(_ raw: String, base: URL) -> String {
        let absolute: URL?
        if let url = URL(string: raw), url.scheme != nil {
            absolute = url
        } else {
            absolute = URL(string: raw, relativeTo: base)?.absoluteURL
        }
        guard let absolute else { return raw }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = absolute.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? absolute.absoluteString
        return "http://127.0.0.1:\(port)/r?u=\(encoded)"
    }

    private func send(_ connection: NWConnection, status: Int, headers: [String: String], body: Data?, file: URL?) async throws {
        var head = "HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : "OK")\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        try await write(connection, Data(head.utf8))
        if let body {
            try await write(connection, body)
            return
        }
        guard let file else { return }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while true {
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            try await write(connection, chunk)
        }
    }

    private func write(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

private final class ResumeBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<MediaBridge, Error>?
    private let lock = NSLock()
    init(_ continuation: CheckedContinuation<MediaBridge, Error>) { self.continuation = continuation }
    func resume(_ value: MediaBridge) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }
    func resume(_ error: Error) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(throwing: error)
    }
}

private extension String {
    func replacingURI(_ map: (String) -> String) -> String {
        guard let start = range(of: "URI=\""), let end = self[start.upperBound...].firstIndex(of: "\"") else { return self }
        let value = String(self[start.upperBound..<end])
        return String(self[..<start.upperBound]) + map(value) + String(self[end...])
    }
}
