import Foundation

/// Rewrites an HLS playlist so every request for this server stays on a custom URL scheme.
/// AVPlayer then asks the app for each segment, which is how a pinned certificate and extra headers are applied.
public func rewriteMediaPlaylist(_ text: String, upstream: URL, scheme: String) -> String {
    guard let host = upstream.host, !host.isEmpty else { return text }
    let port = upstream.port
    func mapped(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let found = url.host,
              found.caseInsensitiveCompare(host) == .orderedSame else { return raw }
        if let port, let foundPort = url.port, foundPort != port { return raw }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = scheme
        return parts?.string ?? raw
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        let raw = String(line)
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return mapped(trimmed) }
        return raw.contains("URI=") ? raw.withURIRewrite(mapped) : raw
    }
    return lines.joined(separator: "\n")
}

private extension String {
    /// Replaces `URI="..."` values. The regex above is not used; this walks the quotes directly.
    func withURIRewrite(_ map: (String) -> String) -> String {
        var out = ""
        var rest = self[...]
        while let range = rest.range(of: "URI=\"") {
            out += rest[..<range.upperBound]
            rest = rest[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else {
                out += rest
                return out
            }
            out += map(String(rest[..<end]))
            out.append("\"")
            rest = rest[rest.index(after: end)...]
        }
        out += rest
        return out
    }
}

/// Finds `hev1` sample-entry tags inside an MP4 `moov` atom.
/// iOS plays the same HEVC samples when that tag is `hvc1` and the `hvcC` box is already present.
/// Replacing the four bytes does not change the file size, so range requests stay valid.
public enum MP4Hev1 {
    public static func offsets(in moovPayload: Data, fileOffset: Int) -> [Int] {
        let bytes = [UInt8](moovPayload)
        guard bytes.count > 8 else { return [] }
        var found: [Int] = []
        var index = 4
        while index + 4 <= bytes.count {
            if bytes[index] == 0x68, bytes[index + 1] == 0x65, bytes[index + 2] == 0x76, bytes[index + 3] == 0x31 {
                let size = (Int(bytes[index - 4]) << 24) | (Int(bytes[index - 3]) << 16)
                    | (Int(bytes[index - 2]) << 8) | Int(bytes[index - 1])
                if size >= 8, size < 20_000_000 { found.append(fileOffset + index) }
            }
            index += 1
        }
        return found
    }

    public static func apply(_ data: inout Data, rangeStart: Int, offsets: [Int]) {
        for offset in offsets {
            let local = offset - rangeStart
            guard local >= 0, local + 4 <= data.count else { continue }
            data.replaceSubrange(local..<(local + 4), with: [0x68, 0x76, 0x63, 0x31])
        }
    }

    /// Reads only the file header and, when `moov` is at the end, that atom. `mdat` is not downloaded.
    public static func locate(length: Int?, fetch: (Int, Int) async throws -> Data) async throws -> [Int] {
        let head = try await fetch(0, 256 * 1024)
        guard head.count >= 8 else { return [] }
        if let moov = box("moov", in: head) {
            let boxData = moov.start + moov.size <= head.count
                ? head.subdata(in: moov.start..<(moov.start + moov.size))
                : try await fetch(moov.start, moov.size)
            return moovOffsets(boxData, fileOffset: moov.start, header: moov.header)
        }
        if let mdat = box("mdat", in: head) {
            let moovAt = mdat.start + mdat.size
            let marker = try await fetch(moovAt, 16)
            guard let next = box("moov", in: marker), next.start == 0 else { return [] }
            let boxData = try await fetch(moovAt, next.size)
            return moovOffsets(boxData, fileOffset: moovAt, header: next.header)
        }
        // moov sits in the header but the size chain did not line up. Search only that header.
        if head.range(of: Data("moov".utf8)) != nil { return offsets(in: head, fileOffset: 0) }
        return []
    }

    private static func box(_ type: String, in data: Data) -> (start: Int, size: Int, header: Int)? {
        let tag = [UInt8](type.utf8)
        let bytes = [UInt8](data)
        var index = 0
        while index + 8 <= bytes.count {
            let size = (Int(bytes[index]) << 24) | (Int(bytes[index + 1]) << 16)
                | (Int(bytes[index + 2]) << 8) | Int(bytes[index + 3])
            if Array(bytes[(index + 4)..<(index + 8)]) == tag, size >= 8 {
                return (index, size, 8)
            }
            if size >= 8, index + size <= bytes.count, index + size > index {
                index += size
            } else {
                break
            }
        }
        return nil
    }

    private static func moovOffsets(_ box: Data, fileOffset: Int, header: Int) -> [Int] {
        guard box.count > header else { return [] }
        let end = min(box.count, box.count)
        return offsets(in: box.subdata(in: header..<end), fileOffset: fileOffset + header)
    }
}
