import Foundation

// Container Manager (DSM 7.2) and the older Docker package (DSM 6.2–7.1) share the SYNO.Docker.* APIs.

public struct DockerContainer: Decodable, Identifiable, Hashable, Sendable {
    public let name: String
    public let containerID: String?
    public let image: String
    public let status: String
    public let upStatus: String?
    public let created: Date?
    public let ports: [PortBinding]

    public var id: String { name }
    public var isRunning: Bool { status == "running" }
    public var statusLabel: String {
        switch status {
        case "running": return "运行中"
        case "stopped", "exited": return "已停止"
        case "paused": return "已暂停"
        case "restarting": return "重启中"
        case "created": return "已创建"
        case "dead": return "异常"
        default: return status
        }
    }

    enum CodingKeys: String, CodingKey { case name, id, image, status, up_status, created, ports }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        containerID = try c.decodeIfPresent(String.self, forKey: .id)
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        upStatus = try c.decodeIfPresent(String.self, forKey: .up_status)?.nilIfEmpty
        created = (try? c.decodeIfPresent(FlexInt.self, forKey: .created))?.map { Date(timeIntervalSince1970: TimeInterval($0.value)) } ?? nil
        ports = (try? c.decodeIfPresent([PortBinding].self, forKey: .ports)) ?? []
    }
}

public struct PortBinding: Codable, Hashable, Sendable {
    public var hostPort: Int?
    public var containerPort: Int
    public var proto: String

    public init(hostPort: Int?, containerPort: Int, proto: String = "tcp") {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }

    enum CodingKeys: String, CodingKey { case host_port, container_port, type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostPort = (try? c.decodeIfPresent(FlexInt.self, forKey: .host_port))??.value
        containerPort = try c.decode(FlexInt.self, forKey: .container_port).value
        proto = try c.decodeIfPresent(String.self, forKey: .type) ?? "tcp"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hostPort ?? 0, forKey: .host_port)
        try c.encode(containerPort, forKey: .container_port)
        try c.encode(proto, forKey: .type)
    }

    public var display: String { "\(hostPort.map(String.init) ?? "自动") → \(containerPort)/\(proto)" }
}

public struct VolumeBinding: Codable, Hashable, Sendable {
    public var hostPath: String
    public var mountPoint: String
    public var readOnly: Bool

    public init(hostPath: String, mountPoint: String, readOnly: Bool = false) {
        self.hostPath = hostPath
        self.mountPoint = mountPoint
        self.readOnly = readOnly
    }

    enum CodingKeys: String, CodingKey { case host_volume_file, mount_point, type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostPath = try c.decodeIfPresent(String.self, forKey: .host_volume_file) ?? ""
        mountPoint = try c.decodeIfPresent(String.self, forKey: .mount_point) ?? ""
        readOnly = (try c.decodeIfPresent(String.self, forKey: .type)) == "ro"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hostPath, forKey: .host_volume_file)
        try c.encode(mountPoint, forKey: .mount_point)
        try c.encode(readOnly ? "ro" : "rw", forKey: .type)
    }
}

public struct EnvVariable: Codable, Hashable, Sendable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    /// Names that usually hold secrets; their values are masked until the user reveals them.
    public var isSensitive: Bool {
        let k = key.uppercased()
        return ["PASS", "SECRET", "TOKEN", "KEY", "PWD", "CREDENTIAL", "AUTH", "PRIVATE"].contains { k.contains($0) }
    }
}

/// The editable configuration of a container ("profile" in Container Manager).
/// Unknown fields are kept so a save never drops settings this app doesn't show.
public struct ContainerProfile: Sendable, Equatable {
    public var name: String
    public var image: String
    public var command: String
    public var env: [EnvVariable]
    public var ports: [PortBinding]
    public var volumes: [VolumeBinding]
    public var networks: [String]
    public var autoRestart: Bool
    public var privileged: Bool
    /// Memory limit in bytes; 0 = unlimited.
    public var memoryLimit: Int64
    /// CPU priority 0–100 (Container Manager's "CPU 优先级"); 0 = default.
    public var cpuPriority: Int

    var raw: [String: JSONValue]

    init(raw: [String: JSONValue]) {
        self.raw = raw
        name = raw["name"]?.string ?? ""
        image = raw["image"]?.string ?? ""
        command = raw["cmd"]?.string ?? ""
        env = raw["env_variables"]?.array?.compactMap { v in
            guard let key = v["key"]?.string else { return nil }
            return EnvVariable(key: key, value: v["value"]?.string ?? "")
        } ?? []
        ports = raw["port_bindings"]?.decode([PortBinding].self) ?? []
        volumes = raw["volume_bindings"]?.decode([VolumeBinding].self) ?? []
        networks = raw["network"]?.array?.compactMap { $0["name"]?.string } ?? []
        autoRestart = raw["enable_restart_policy"]?.bool ?? false
        privileged = raw["privileged"]?.bool ?? false
        memoryLimit = raw["memory_limit"]?.int64 ?? 0
        cpuPriority = Int(raw["cpu_priority"]?.int64 ?? 0)
    }

    /// The full profile with this struct's edits applied on top of the original fields.
    var merged: [String: JSONValue] {
        var out = raw
        out["name"] = .string(name)
        out["image"] = .string(image)
        out["cmd"] = .string(command)
        out["env_variables"] = .array(env.map { .object(["key": .string($0.key), "value": .string($0.value)]) })
        out["port_bindings"] = JSONValue(encoding: ports)
        out["volume_bindings"] = JSONValue(encoding: volumes)
        out["enable_restart_policy"] = .bool(autoRestart)
        out["privileged"] = .bool(privileged)
        out["memory_limit"] = .number(Double(memoryLimit))
        out["cpu_priority"] = .number(Double(cpuPriority))
        return out
    }
}

public struct ContainerResource: Decodable, Sendable, Hashable {
    public let name: String
    public let cpuPercent: Double
    public let memoryBytes: Int64
    public let memoryPercent: Double

    enum CodingKeys: String, CodingKey { case name, cpu, memory, memoryPercent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        cpuPercent = (try? c.decodeIfPresent(Double.self, forKey: .cpu)) ?? Double((try? c.decodeIfPresent(FlexString.self, forKey: .cpu))??.value ?? "") ?? 0
        memoryBytes = Int64((try? c.decodeIfPresent(FlexString.self, forKey: .memory))??.value ?? "") ?? 0
        memoryPercent = (try? c.decodeIfPresent(Double.self, forKey: .memoryPercent)) ?? Double((try? c.decodeIfPresent(FlexString.self, forKey: .memoryPercent))??.value ?? "") ?? 0
    }
}

public struct ContainerLogLine: Decodable, Hashable, Sendable, Identifiable {
    public let created: String
    public let stream: String
    public let text: String
    public var id: String { created + stream + text }
    public var isError: Bool { stream == "stderr" }

    enum CodingKeys: String, CodingKey { case created, stream, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt: FlexString? = (try? c.decodeIfPresent(FlexString.self, forKey: .created)) ?? nil
        created = createdAt?.value ?? ""
        let streamName: String? = (try? c.decodeIfPresent(String.self, forKey: .stream)) ?? nil
        stream = streamName ?? "stdout"
        let message: String? = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil
        text = message ?? ""
    }
}

public struct DockerImage: Decodable, Identifiable, Hashable, Sendable {
    public let repository: String
    public let tags: [String]
    public let size: Int64
    public let created: Date?
    public let imageID: String?

    public var id: String { imageID ?? repository + tags.joined() }
    public var display: String { tags.isEmpty ? repository : "\(repository):\(tags.joined(separator: ", "))" }

    enum CodingKeys: String, CodingKey { case repository, tags, size, created, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repository = try c.decodeIfPresent(String.self, forKey: .repository) ?? ""
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? nil ?? []
        size = Int64((try? c.decodeIfPresent(FlexString.self, forKey: .size))??.value ?? "") ?? 0
        let createdAt: FlexInt? = (try? c.decodeIfPresent(FlexInt.self, forKey: .created)) ?? nil
        created = createdAt.map { Date(timeIntervalSince1970: TimeInterval($0.value)) }
        imageID = try c.decodeIfPresent(String.self, forKey: .id)
    }
}

/// A Container Manager project (docker compose).
public struct DockerProject: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String?
    public let status: String
    public let containerCount: Int

    public var isRunning: Bool { status.uppercased() == "RUNNING" }

    enum CodingKeys: String, CodingKey { case id, name, path, status, containerIds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        path = try c.decodeIfPresent(String.self, forKey: .path)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        containerCount = ((try? c.decodeIfPresent([String].self, forKey: .containerIds)) ?? nil)?.count ?? 0
    }
}

/// One compose project with its compose file, from SYNO.Docker.Project get.
public struct DockerProjectDetail: Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String?
    public let status: String
    /// The docker-compose.yml text.
    public let content: String
    /// Names of the containers the project created, when DSM lists them.
    public let containers: [String]

    public var isRunning: Bool { status.uppercased() == "RUNNING" }
    public var statusLabel: String {
        switch status.uppercased() {
        case "RUNNING": return "运行中"
        case "STOPPED": return "已停止"
        case "BUILDING": return "构建中"
        case "ERROR": return "异常"
        case "": return "未知"
        default: return status
        }
    }

    init(raw: [String: JSONValue]) {
        id = raw["id"]?.string ?? ""
        name = raw["name"]?.string ?? id
        path = (raw["path"]?.string ?? raw["share_path"]?.string)?.nilIfEmpty
        status = raw["status"]?.string ?? ""
        content = raw["content"]?.string ?? ""
        containers = raw["containers"]?.array?.compactMap { $0.string ?? $0["name"]?.string ?? $0["Name"]?.string } ?? []
    }
}

public struct DockerNetwork: Decodable, Identifiable, Hashable, Sendable {
    public let name: String
    public let driver: String
    public let subnet: String?
    public let gateway: String?
    public let containers: [String]
    public var id: String { name }

    enum CodingKeys: String, CodingKey { case name, driver, subnet, gateway, containers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? ""
        subnet = try c.decodeIfPresent(String.self, forKey: .subnet)?.nilIfEmpty
        gateway = try c.decodeIfPresent(String.self, forKey: .gateway)?.nilIfEmpty
        containers = ((try? c.decodeIfPresent([String].self, forKey: .containers)) ?? nil) ?? []
    }
}

extension DSMClient {
    public var hasDocker: Bool { supports("SYNO.Docker.Container") }
    public var hasDockerProjects: Bool { supports("SYNO.Docker.Project") }

    public func containers() async throws -> [DockerContainer] {
        struct R: Decodable { let containers: [DockerContainer] }
        let r: R = try await call("SYNO.Docker.Container", method: "list", version: 1, params: [
            "limit": "-1", "offset": "0", "type": FSParam.string("all"),
        ])
        return r.containers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func containerResources() async throws -> [ContainerResource] {
        struct R: Decodable { let resources: [ContainerResource] }
        let r: R = try await call("SYNO.Docker.Container.Resource", method: "get", version: 1)
        return r.resources
    }

    public func startContainer(_ name: String) async throws { try await containerAction("start", name) }
    public func stopContainer(_ name: String) async throws { try await containerAction("stop", name) }
    public func restartContainer(_ name: String) async throws { try await containerAction("restart", name) }

    /// Removes the container (not its image or data on mapped folders).
    public func deleteContainer(_ name: String, force: Bool = false) async throws {
        let _: EmptyData = try await call("SYNO.Docker.Container", method: "delete", version: 1, params: [
            "name": FSParam.string(name), "force": force ? "true" : "false", "preserve_profile": "false",
        ])
    }

    private func containerAction(_ method: String, _ name: String) async throws {
        let _: EmptyData = try await call("SYNO.Docker.Container", method: method, version: 1, params: [
            "name": FSParam.string(name),
        ])
    }

    public func containerProfile(_ name: String) async throws -> ContainerProfile {
        struct R: Decodable { let profile: [String: JSONValue] }
        let r: R = try await call("SYNO.Docker.Container", method: "get", version: 1, params: ["name": FSParam.string(name)])
        return ContainerProfile(raw: r.profile)
    }

    /// Saves edited settings. Container Manager applies them by recreating the container,
    /// so it restarts if it was running. Data in mapped folders is kept.
    public func updateContainer(_ original: String, profile: ContainerProfile) async throws {
        let json = String(data: try JSONEncoder().encode(profile.merged), encoding: .utf8) ?? "{}"
        let _: EmptyData = try await call("SYNO.Docker.Container", method: "set", version: 1, params: [
            "name": FSParam.string(original), "profile": json,
        ])
    }

    /// Container Manager answers 114 (missing parameter) to some parameter shapes, and which one it
    /// wants differs between Docker and Container Manager builds. Plain values with only the needed
    /// fields come first (what DSM 7.2's own UI sends); the JSON-quoted shape is the fallback.
    public func containerLogs(_ name: String, keyword: String = "", offset: Int = 0, limit: Int = 200) async throws -> (lines: [ContainerLogLine], total: Int) {
        struct R: Decodable { let logs: [ContainerLogLine]; let total: FlexInt? }
        var plain = ["name": name, "sort_dir": "DESC", "offset": String(offset), "limit": String(limit)]
        if !keyword.isEmpty { plain["keyword"] = keyword }
        let quoted = [
            "name": FSParam.string(name),
            "from": "0", "to": "0",
            "level": FSParam.string(""),
            "keyword": FSParam.string(keyword),
            "sort_dir": FSParam.string("DESC"),
            "offset": String(offset), "limit": String(limit),
        ]
        let r: R = try await callTryingShapes("SYNO.Docker.Container.Log", method: "get", version: 1, shapes: [plain, quoted])
        return (r.logs, r.total?.value ?? r.logs.count)
    }

    /// Tries each parameter shape in turn while DSM rejects the parameters; any other error
    /// (session lost, no permission, network) is thrown right away.
    func callTryingShapes<T: Decodable>(_ api: String, method: String, version: Int,
                                       shapes: [[String: String]]) async throws -> T {
        var lastError: Error = DSMError.invalidResponse
        for params in shapes {
            do {
                return try await call(api, method: method, version: version, params: params)
            } catch let error as DSMError {
                guard case .api(let code, _) = error, Self.parameterErrorCodes.contains(code) else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    /// Codes DSM uses for missing or malformed parameters.
    static let parameterErrorCodes: Set<Int> = [100, 101, 114, 120]

    public func dockerImages() async throws -> [DockerImage] {
        struct R: Decodable { let images: [DockerImage] }
        let r: R = try await call("SYNO.Docker.Image", method: "list", version: 1, params: [
            "limit": "-1", "offset": "0", "show_dsm": "false",
        ])
        return r.images
    }

    public func dockerNetworks() async throws -> [DockerNetwork] {
        struct R: Decodable { let network: [DockerNetwork] }
        let r: R = try await call("SYNO.Docker.Network", method: "list", version: 1)
        return r.network
    }

    public func dockerProjects() async throws -> [DockerProject] {
        // Keyed by project id.
        let r: [String: DockerProject] = try await call("SYNO.Docker.Project", method: "list", version: 1)
        return r.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func startProject(_ id: String) async throws { try await projectStream("start_stream", fallback: "start", id) }
    public func stopProject(_ id: String) async throws { try await projectStream("stop_stream", fallback: "stop", id) }
    /// Pulls images and recreates the project's containers from its compose file (docker compose up --build).
    public func buildProject(_ id: String) async throws { try await projectStream("build_stream", fallback: "build", id) }

    public func projectDetail(_ id: String) async throws -> DockerProjectDetail {
        let raw: [String: JSONValue] = try await callTryingShapes("SYNO.Docker.Project", method: "get", version: 1,
                                                                  shapes: [["id": id], ["id": FSParam.string(id)]])
        return DockerProjectDetail(raw: raw)
    }

    /// Replaces the compose file. Running containers keep their old settings until the project is rebuilt.
    public func updateProject(_ id: String, content: String) async throws {
        let _: EmptyData = try await callTryingShapes("SYNO.Docker.Project", method: "update", version: 1, shapes: [
            ["id": id, "content": content],
            ["id": FSParam.string(id), "content": FSParam.string(content)],
        ])
    }

    /// Creates a project from a compose file in `sharePath` (e.g. "/docker/immich"); the folder must exist.
    public func createProject(name: String, sharePath: String, content: String) async throws {
        let _: EmptyData = try await callTryingShapes("SYNO.Docker.Project", method: "create", version: 1, shapes: [
            ["name": name, "share_path": sharePath, "content": content, "enable_service_portal": "false"],
            ["name": FSParam.string(name), "share_path": FSParam.string(sharePath), "content": FSParam.string(content),
             "enable_service_portal": "false"],
        ])
    }

    /// Removes the project and its containers. With `preserveContent` the folder and compose file stay on the NAS.
    public func deleteProject(_ id: String, preserveContent: Bool = true) async throws {
        let flag = preserveContent ? "true" : "false"
        let _: EmptyData = try await callTryingShapes("SYNO.Docker.Project", method: "delete", version: 1, shapes: [
            ["id": id, "preserve_content": flag],
            ["id": FSParam.string(id), "preserve_content": flag],
        ])
    }

    /// The *_stream methods (what Container Manager's UI uses) reply with progress text; older builds
    /// only have the plain method, which answers with a normal JSON envelope.
    private func projectStream(_ method: String, fallback: String, _ id: String) async throws {
        do {
            try await streamAction(method, id)
        } catch DSMError.api(let code, _) where code == 103 || Self.parameterErrorCodes.contains(code) {
            let _: EmptyData = try await callTryingShapes("SYNO.Docker.Project", method: fallback, version: 1,
                                                          shapes: [["id": id], ["id": FSParam.string(id)]])
        }
    }

    /// Success is HTTP 200 unless the body is a JSON error.
    private func streamAction(_ method: String, _ id: String) async throws {
        let api = "SYNO.Docker.Project"
        guard let d = apis[api], let v = version(of: api, preferred: 1) else { throw DSMError.apiUnavailable(api) }
        let request = try makeRequest(path: d.path, api: api, method: method, version: v,
                                      params: ["id": FSParam.string(id)], authenticated: true)
        do {
            let (data, response) = try await transport.send(request)
            guard (200..<300).contains(response.statusCode) else { throw DSMError.transport("HTTP \(response.statusCode)") }
            if let envelope = try? JSONDecoder().decode(Envelope<EmptyData>.self, from: data), !envelope.success {
                throw DSMError.api(code: envelope.error?.code ?? 100, api: api)
            }
            audit(api, method, ["id": id], error: nil)
        } catch {
            audit(api, method, ["id": id], error: error)
            throw error
        }
    }
}
