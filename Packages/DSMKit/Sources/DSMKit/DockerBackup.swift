import Foundation

/// A saved container configuration, kept as JSON on the NAS so it survives reinstalling the app.
/// Data in mapped folders is not part of it; those folders stay where they are.
public struct ContainerBackup: Codable, Sendable, Equatable {
    public let container: String
    public let image: String
    public let created: Date
    public let note: String
    let profile: [String: JSONValue]

    public var settings: ContainerProfile { ContainerProfile(raw: profile) }
}

/// Steps reported while updating or restoring a container.
public enum ContainerJobStep: Sendable, Equatable {
    case backingUp, pulling(String), stopping, removing, creating, starting, done
}

extension DSMClient {
    public static let backupFolderParent = "/docker"
    public static let backupFolderName = "nashelper-backups"
    public static var backupFolder: String { "\(backupFolderParent)/\(backupFolderName)" }

    static func backupFileName(_ container: String, _ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(container)@\(f.string(from: date)).json"
    }

    static let backupEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let backupDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Backup

    /// Saves the container's current settings to /docker/nashelper-backups and returns the file's path.
    @discardableResult
    public func backupContainer(_ name: String, note: String = "") async throws -> String {
        let profile = try await containerProfile(name)
        let now = Date()
        let backup = ContainerBackup(container: name, image: profile.image, created: now, note: note, profile: profile.raw)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Self.backupEncoder.encode(backup).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        // Fails harmlessly when the folder already exists.
        try? await createFolder(in: Self.backupFolderParent, name: Self.backupFolderName)
        let fileName = Self.backupFileName(name, now)
        try await upload(fileAt: local, to: Self.backupFolder, as: fileName, overwrite: true)
        return "\(Self.backupFolder)/\(fileName)"
    }

    /// Backup files, newest first; only those of `container` when given.
    public func containerBackups(for container: String? = nil) async throws -> [RemoteFile] {
        let listing: FileListing
        do {
            listing = try await listFolder(Self.backupFolder, sort: .name, ascending: false)
        } catch DSMError.api(let code, _) where code == 408 || code == 400 || code == 401 {
            return []  // No backup folder yet.
        }
        return listing.files.filter { file in
            guard !file.isDirectory, file.name.hasSuffix(".json") else { return false }
            return container.map { file.name.hasPrefix("\($0)@") } ?? true
        }
    }

    public func loadBackup(at path: String) async throws -> ContainerBackup {
        let data = try await fileData(at: path)
        guard let backup = try? Self.backupDecoder.decode(ContainerBackup.self, from: data) else {
            throw DSMError.invalidResponse
        }
        return backup
    }

    // MARK: Create, update, restore

    public func createContainer(profile: [String: JSONValue], start: Bool) async throws {
        let json = String(data: try JSONEncoder().encode(profile), encoding: .utf8) ?? "{}"
        let _: EmptyData = try await call("SYNO.Docker.Container", method: "create", version: 1, params: [
            "profile": json, "is_run_instantly": start ? "true" : "false",
        ])
    }

    /// Pulls an image from its registry and waits until the NAS reports the pull finished.
    public func pullImage(_ reference: String, timeout: TimeInterval = 1800) async throws {
        let (repository, tag) = Self.splitImageReference(reference)
        struct Start: Decodable { let task_id: String }
        struct Status: Decodable { let finished: Bool? }
        let start: Start = try await call("SYNO.Docker.Image", method: "pull_start", version: 1, params: [
            "repository": FSParam.string(repository), "tag": FSParam.string(tag),
        ])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let s: Status = try await call("SYNO.Docker.Image", method: "pull_status", version: 1, params: [
                "task_id": FSParam.string(start.task_id),
            ])
            if s.finished == true { return }
        }
        throw DSMError.transport("拉取镜像超时")
    }

    /// "registry:5000/app:1.2" → ("registry:5000/app", "1.2"); no tag means "latest".
    static func splitImageReference(_ reference: String) -> (String, String) {
        if let colon = reference.lastIndex(of: ":"), !reference[colon...].contains("/") {
            return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
        }
        return (reference, "latest")
    }

    /// Pulls the container's image again and recreates the container with the same settings.
    /// The current settings are backed up first, so the update can be rolled back.
    public func updateContainerImage(_ name: String, onStep: @Sendable (ContainerJobStep) -> Void = { _ in }) async throws {
        onStep(.backingUp)
        try await backupContainer(name, note: "更新前自动备份")
        let profile = try await containerProfile(name)
        onStep(.pulling(profile.image))
        try await pullImage(profile.image)
        try await recreate(name, profile: profile.raw, onStep: onStep)
    }

    /// Recreates the container from a backup, optionally on a different image tag (to roll back
    /// an image update). The current settings are backed up first.
    public func restoreContainer(from backup: ContainerBackup, image: String? = nil,
                                 onStep: @Sendable (ContainerJobStep) -> Void = { _ in }) async throws {
        var profile = backup.profile
        if let image, !image.isEmpty, image != backup.image {
            profile["image"] = .string(image)
            onStep(.pulling(image))
            try await pullImage(image)
        }
        let exists = try await containers().contains { $0.name == backup.container }
        if exists {
            onStep(.backingUp)
            try await backupContainer(backup.container, note: "恢复前自动备份")
        }
        try await recreate(backup.container, profile: profile, exists: exists, onStep: onStep)
    }

    private func recreate(_ name: String, profile: [String: JSONValue], exists: Bool = true,
                          onStep: @Sendable (ContainerJobStep) -> Void) async throws {
        if exists {
            if try await containers().first(where: { $0.name == name })?.isRunning == true {
                onStep(.stopping)
                try await stopContainer(name)
            }
            onStep(.removing)
            try await deleteContainer(name, force: true)
        }
        onStep(.creating)
        var p = profile
        p["name"] = .string(name)
        try await createContainer(profile: p, start: false)
        onStep(.starting)
        try await startContainer(name)
        onStep(.done)
    }
}
