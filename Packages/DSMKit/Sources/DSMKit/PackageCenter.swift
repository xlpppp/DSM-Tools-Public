import Foundation

/// An installed package (SYNO.Core.Package).
public struct InstalledPackage: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String?
    public let status: String
    /// Whether DSM lets the user start/stop it (system packages cannot be stopped).
    public let startable: Bool

    public var isRunning: Bool { status == "running" }

    public var statusLabel: String {
        switch status {
        case "running": return "运行中"
        case "stop", "stopped": return "已停止"
        case "broken", "error": return "异常"
        case "installing", "upgrading": return "安装中"
        default: return status.isEmpty ? "—" : status
        }
    }

    enum CodingKeys: String, CodingKey { case id, name, version, additional }
    struct Additional: Decodable {
        let description: String?
        let status: String?
        let startable: Bool?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        let a = try c.decodeIfPresent(Additional.self, forKey: .additional)
        description = a?.description?.nilIfEmpty
        status = a?.status ?? ""
        startable = a?.startable ?? true
    }
}

/// A package offered by the package server, used for icons and to spot available updates.
public struct CatalogPackage: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let summary: String?
    public let iconURL: URL?
    public let category: String?

    enum CodingKeys: String, CodingKey { case id, dname, version, desc, thumbnail, category }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .dname) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .desc)?.nilIfEmpty
        let thumbs = (try? c.decodeIfPresent([String].self, forKey: .thumbnail)) ?? nil
        // The last thumbnail is the largest.
        iconURL = thumbs?.last.flatMap(URL.init(string:))
        category = (try? c.decodeIfPresent([String].self, forKey: .category))??.first
    }
}

extension DSMClient {
    public func installedPackages() async throws -> [InstalledPackage] {
        struct R: Decodable { let packages: [InstalledPackage] }
        let r: R = try await call("SYNO.Core.Package", method: "list", version: 2, params: [
            "additional": FSParam.strings(["description", "status", "startable"]),
        ])
        return r.packages.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Packages offered for this NAS by Synology's package server (queried by the NAS itself).
    public func packageCatalog() async throws -> [CatalogPackage] {
        struct R: Decodable { let packages: [CatalogPackage]? }
        let r: R = try await call("SYNO.Core.Package.Server", method: "list", version: 2, params: [
            "blforcereload": "false",
            "blloadothers": "false",
        ])
        return r.packages ?? []
    }

    public func startPackage(_ id: String) async throws {
        let _: EmptyData = try await call("SYNO.Core.Package.Control", method: "start", version: 1, params: ["id": id])
    }

    public func stopPackage(_ id: String) async throws {
        let _: EmptyData = try await call("SYNO.Core.Package.Control", method: "stop", version: 1, params: ["id": id])
    }
}

/// Compares dotted/dashed package versions such as "3.9.2-2620" numerically.
public func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    func parts(_ v: String) -> [Int] {
        v.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
    let a = parts(candidate), b = parts(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}
