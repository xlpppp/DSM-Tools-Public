import Foundation

/// One change the app made on the NAS. Parameters are already redacted.
public struct AuditEvent: Codable, Hashable, Sendable {
    public let date: Date
    public let api: String
    public let method: String
    public let parameters: [String: String]
    public let succeeded: Bool
    public let errorCode: Int?

    public init(date: Date = Date(), api: String, method: String, parameters: [String: String],
                succeeded: Bool, errorCode: Int?) {
        self.date = date
        self.api = api
        self.method = method
        self.parameters = parameters
        self.succeeded = succeeded
        self.errorCode = errorCode
    }
}

public enum AuditPolicy {
    /// Read-only methods are not audited, so the log holds only changes.
    static let readMethods: Set<String> = [
        "list", "get", "info", "query", "getinfo", "get_info", "status", "load", "search", "stats",
        "list_share", "getconfig", "get_config", "logout", "login",
    ]
    static let readAPIs: Set<String> = [
        "SYNO.API.Auth", "SYNO.API.Info", "SYNO.FileStation.Search", "SYNO.FileStation.DirSize",
        "SYNO.FileStation.MD5", "SYNO.FileStation.Thumb", "SYNO.FileStation.BackgroundTask",
        "SYNO.Core.System.Utilization",
    ]

    public static func isWrite(api: String, method: String) -> Bool {
        if readAPIs.contains(api) || readMethods.contains(method) { return false }
        return !(method.hasPrefix("list") || method.hasPrefix("get"))
    }

    /// Hides values whose key suggests a secret, and shortens long values (container profiles, etc.).
    public static func redact(_ params: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in params where !["api", "method", "version", "_sid", "SynoToken"].contains(key) {
            out[key] = isSensitive(key) ? "***" : redactInline(value)
        }
        return out
    }

    static func isSensitive(_ key: String) -> Bool {
        let k = key.lowercased()
        return ["passw", "pwd", "token", "secret", "otp", "apikey", "api_key", "private", "cookie", "sid"]
            .contains { k.contains($0) }
    }

    /// JSON values can carry secrets too, e.g. container env variables: {"key":"DB_PASSWORD","value":"x"}.
    static func redactInline(_ value: String) -> String {
        var text = value
        if let regex = try? NSRegularExpression(
            pattern: #""(key|name)"\s*:\s*"([^"]*(?:PASS|SECRET|TOKEN|KEY)[^"]*)"\s*,\s*"value"\s*:\s*"[^"]*""#,
            options: [.caseInsensitive]) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: #""$1":"$2","value":"***""#)
        }
        if let regex = try? NSRegularExpression(
            pattern: #""([^"]*(?:passw|pwd|secret|token)[^"]*)"\s*:\s*"[^"]*""#, options: [.caseInsensitive]) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: #""$1":"***""#)
        }
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }
}

extension DSMClient {
    /// Receives every write the client makes. The app stores them with the device name.
    public func setAuditHandler(_ handler: (@Sendable (AuditEvent) -> Void)?) {
        auditHandler = handler
    }

    func audit(_ api: String, _ method: String, _ params: [String: String], error: Error?) {
        guard let auditHandler, AuditPolicy.isWrite(api: api, method: method) else { return }
        var code: Int?
        if case .api(let c, _)? = error as? DSMError { code = c }
        auditHandler(AuditEvent(api: api, method: method, parameters: AuditPolicy.redact(params),
                                succeeded: error == nil, errorCode: code))
    }
}
