import Foundation
import DSMKit

/// Changes the app made on any NAS, kept on this device only. Parameters arrive already
/// redacted by DSMKit (passwords, tokens and secret-looking env values become ***).
struct AuditRecord: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    let deviceID: UUID?
    let deviceName: String
    let event: AuditEvent

    /// A readable name for the operation, e.g. "停止容器".
    var title: String { AuditRecord.label(api: event.api, method: event.method) }

    var detail: String {
        let keys = ["name", "path", "id", "tasks", "uri", "dest_folder_path", "folder_path", "file"]
        let parts = keys.compactMap { k in event.parameters[k].map { "\(k)=\($0)" } }
        return parts.isEmpty ? "\(event.api) · \(event.method)" : parts.joined(separator: "  ")
    }

    static func label(api: String, method: String) -> String {
        let area: String
        switch api {
        case let a where a.hasPrefix("SYNO.Docker.Container"): area = "容器"
        case let a where a.hasPrefix("SYNO.Docker.Image"): area = "镜像"
        case let a where a.hasPrefix("SYNO.Docker.Project"): area = "Docker 项目"
        case let a where a.hasPrefix("SYNO.FileStation"): area = "文件"
        case let a where a.hasPrefix("SYNO.DownloadStation"): area = "下载任务"
        case let a where a.hasPrefix("SYNO.Core.Package"): area = "套件"
        case let a where a.hasPrefix("SYNO.Core.User"): area = "用户"
        case let a where a.hasPrefix("SYNO.Core.CurrentConnection"): area = "连接"
        case let a where a.hasPrefix("SYNO.Core.FileServ"): area = "文件服务"
        case let a where a.hasPrefix("SYNO.Core.TaskScheduler"): area = "计划任务"
        case let a where a.hasPrefix("SYNO.Virtualization"): area = "虚拟机"
        case "SYNO.Core.System": area = "系统"
        default: area = api.replacingOccurrences(of: "SYNO.", with: "")
        }
        let verb: String
        switch method {
        case "start", "start_stream", "poweron": verb = "启动"
        case "stop", "stop_stream", "shutdown", "poweroff": verb = method == "shutdown" && area == "系统" ? "关机" : "停止"
        case "restart": verb = "重启"
        case "reboot": verb = "重启"
        case "delete", "delete_task": verb = "删除"
        case "create", "create_task": verb = "创建"
        case "set", "set_enable": verb = "修改"
        case "upload": verb = "上传"
        case "rename": verb = "重命名"
        case "kick": verb = "断开"
        case "run": verb = "运行"
        case "pause": verb = "暂停"
        case "resume": verb = "继续"
        case "pull_start": verb = "拉取"
        default: verb = method
        }
        return verb + area
    }
}

final class AuditLog: @unchecked Sendable {
    static let shared = AuditLog()
    static let limit = 2000

    private let lock = NSLock()
    private var cache: [AuditRecord]?
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audit.json")
    }()

    func append(_ event: AuditEvent, deviceID: UUID?, deviceName: String) {
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        all.append(AuditRecord(deviceID: deviceID, deviceName: deviceName, event: event))
        if all.count > Self.limit { all.removeFirst(all.count - Self.limit) }
        cache = all
        saveLocked(all)
        NotificationCenter.default.post(name: .auditLogChanged, object: nil)
    }

    /// Newest first.
    func records() -> [AuditRecord] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().reversed()
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        cache = []
        saveLocked([])
        NotificationCenter.default.post(name: .auditLogChanged, object: nil)
    }

    /// CSV for sharing. Already redacted, so safe to export.
    func exportCSV() -> URL? {
        let f = ISO8601DateFormatter()
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["时间,设备,操作,结果,详情"]
        for r in records() {
            let result = r.event.succeeded ? "成功" : "失败\(r.event.errorCode.map { "(\($0))" } ?? "")"
            lines.append([f.string(from: r.event.date), r.deviceName, r.title, result, r.detail].map(esc).joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("操作审计.csv")
        do {
            // BOM so Excel opens the Chinese text correctly.
            try (Data([0xEF, 0xBB, 0xBF]) + Data(lines.joined(separator: "\n").utf8)).write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func loadLocked() -> [AuditRecord] {
        if let cache { return cache }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([AuditRecord].self, from: $0) } ?? []
        cache = loaded
        return loaded
    }

    private func saveLocked(_ records: [AuditRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

extension Notification.Name {
    static let auditLogChanged = Notification.Name("auditLogChanged")
}
