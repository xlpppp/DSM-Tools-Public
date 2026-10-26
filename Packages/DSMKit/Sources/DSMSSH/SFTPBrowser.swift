import Foundation
import Citadel
import NIOCore

public struct SFTPItem: Identifiable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let size: Int64?
    public let modified: Date?
    /// e.g. "drwxr-xr-x", from the server's long listing.
    public let permissions: String?

    public var id: String { path }
}

/// File operations over SFTP, for paths outside File Station's shared folders (e.g. /volume1/@docker).
public actor SFTPBrowser {
    let sftp: SFTPClient
    /// SFTP packets are small; 32 KB keeps every request within what all servers accept.
    static let chunk = 32_000

    init(sftp: SFTPClient) { self.sftp = sftp }

    public func home() async throws -> String {
        try await sftp.getRealPath(atPath: ".")
    }

    public func list(_ path: String) async throws -> [SFTPItem] {
        let names = try await sftp.listDirectory(atPath: path)
        let base = path.hasSuffix("/") ? path : path + "/"
        return names.flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { c in
                let mode = c.attributes.permissions ?? 0
                let typeBits = mode & 0o170000
                let longPerm = c.longname.split(separator: " ").first.map(String.init)
                return SFTPItem(
                    path: base + c.filename,
                    name: c.filename,
                    isDirectory: typeBits == 0o040000 || longPerm?.hasPrefix("d") == true,
                    isSymlink: typeBits == 0o120000 || longPerm?.hasPrefix("l") == true,
                    size: c.attributes.size.map { Int64($0) },
                    modified: c.attributes.accessModificationTime?.modificationTime,
                    permissions: longPerm
                )
            }
            .sorted { a, b in
                a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// Copies a remote file to `local`, reporting the fraction done.
    public func download(_ path: String, to local: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let file = try await sftp.openFile(filePath: path, flags: .read)
        do {
            let total = try await file.readAttributes().size ?? 0
            _ = FileManager.default.createFile(atPath: local.path, contents: nil)
            let out = try FileHandle(forWritingTo: local)
            defer { try? out.close() }
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let buffer = try await file.read(from: offset, length: UInt32(Self.chunk))
                if buffer.readableBytes == 0 { break }
                out.write(Data(buffer: buffer))
                offset += UInt64(buffer.readableBytes)
                if total > 0 { progress?(Double(offset) / Double(total)) }
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    public func upload(_ local: URL, to path: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let total = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? 0
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        let file = try await sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
        do {
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let data = input.readData(ofLength: Self.chunk)
                if data.isEmpty { break }
                try await file.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
                if total > 0 { progress?(Double(offset) / Double(total)) }
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    public func createDirectory(_ path: String) async throws {
        try await sftp.createDirectory(atPath: path)
    }

    public func rename(_ path: String, to newPath: String) async throws {
        try await sftp.rename(at: path, to: newPath)
    }

    /// Removes a file or an empty folder.
    public func remove(_ item: SFTPItem) async throws {
        if item.isDirectory {
            try await sftp.rmdir(at: item.path)
        } else {
            try await sftp.remove(at: item.path)
        }
    }

    public func close() async {
        try? await sftp.close()
    }
}
