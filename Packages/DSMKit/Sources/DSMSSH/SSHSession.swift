import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH

public enum SSHError: Error, Equatable, Sendable {
    /// First connection to this host: the user must confirm the fingerprint before we trust it.
    case unknownHostKey(fingerprint: String)
    /// The host presented a different key than the one the user trusted earlier.
    case hostKeyChanged(expected: String, actual: String)
    case authenticationFailed
    case unreachable(String)
    case failed(String)

    public var message: String {
        switch self {
        case .unknownHostKey: return "首次连接，请核对并信任主机指纹"
        case .hostKeyChanged: return "主机指纹与之前信任的不一致，可能遭到中间人攻击，已拒绝连接"
        case .authenticationFailed: return "SSH 用户名或密码错误"
        case .unreachable(let detail): return "无法连接 SSH：\(detail)"
        case .failed(let detail): return detail
        }
    }
}

/// SHA-256 fingerprint in OpenSSH's format ("SHA256:…", unpadded base64), from an
/// OpenSSH public key line such as "ssh-ed25519 AAAA… comment".
public func sshFingerprint(openSSHKey: String) -> String? {
    let parts = openSSHKey.split(separator: " ")
    guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
    let digest = Data(SHA256.hash(data: blob))
    return "SHA256:" + digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
}

/// Accepts only the host key whose fingerprint the user trusted; records what it saw either way.
final class FingerprintValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let trusted: String?
    private let lock = NSLock()
    private var _seen: String?

    init(trusted: String?) { self.trusted = trusted }

    var seen: String? {
        lock.lock(); defer { lock.unlock() }
        return _seen
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = sshFingerprint(openSSHKey: String(openSSHPublicKey: hostKey))
        lock.lock()
        _seen = fingerprint
        lock.unlock()
        if let trusted, let fingerprint, trusted == fingerprint {
            validationCompletePromise.succeed(())
        } else if let fingerprint {
            validationCompletePromise.fail(trusted == nil
                ? SSHError.unknownHostKey(fingerprint: fingerprint)
                : SSHError.hostKeyChanged(expected: trusted!, actual: fingerprint))
        } else {
            validationCompletePromise.fail(SSHError.failed("无法读取主机公钥"))
        }
    }
}

/// One authenticated SSH connection to the NAS. Used for the terminal, SFTP and Docker CLI.
public final class SSHSession: @unchecked Sendable {
    let client: SSHClient
    public let fingerprint: String

    init(client: SSHClient, fingerprint: String) {
        self.client = client
        self.fingerprint = fingerprint
    }

    /// Connects with password authentication. `trustedFingerprint` nil means "never connected
    /// before": the call fails with `.unknownHostKey` so the user can confirm, then retries with it.
    public static func connect(host: String, port: Int = 22, username: String, password: String,
                               trustedFingerprint: String?, timeout: Int64 = 10) async throws -> SSHSession {
        let validator = FingerprintValidator(trusted: trustedFingerprint)
        do {
            let client = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: .passwordBased(username: username, password: password),
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                connectTimeout: .seconds(timeout)
            )
            return SSHSession(client: client, fingerprint: validator.seen ?? trustedFingerprint ?? "")
        } catch {
            // The validator's verdict is the reliable signal; NIO may wrap the error it failed with.
            if let seen = validator.seen, seen != trustedFingerprint {
                if let trusted = trustedFingerprint { throw SSHError.hostKeyChanged(expected: trusted, actual: seen) }
                throw SSHError.unknownHostKey(fingerprint: seen)
            }
            if validator.seen != nil { throw SSHError.authenticationFailed }
            throw SSHError.unreachable(describeConnectFailure(error))
        }
    }

    /// NIO's errors read like "connectTimeout(…)" or "connection reset (error set): Connection refused
    /// (errno: 61)"; turn the common ones into something a user can act on.
    static func describeConnectFailure(_ error: Error) -> String {
        let text = String(describing: error)
        let lower = text.lowercased()
        if lower.contains("refused") {
            return "端口拒绝连接（SSH 未启用或端口不对）"
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return "连接超时（端口未放通，外网需在路由器转发 SSH 端口）"
        }
        if lower.contains("unreachable") || lower.contains("no route") {
            return "网络不可达"
        }
        if lower.contains("resolve") || lower.contains("nodename") || lower.contains("dns") {
            return "无法解析主机名"
        }
        return text
    }

    /// Runs a command and returns stdout and stderr merged. Throws if it exits non-zero.
    public func run(_ command: String) async throws -> String {
        let output = try await client.executeCommand(command, mergeStreams: true)
        return String(buffer: output)
    }

    @available(macOS 15.0, *)
    public func openTerminal(columns: Int, rows: Int) -> SSHTerminal {
        let terminal = SSHTerminal()
        terminal.start(client: client, columns: columns, rows: rows)
        return terminal
    }

    public func openSFTP() async throws -> SFTPBrowser {
        SFTPBrowser(sftp: try await client.openSFTP())
    }

    public func close() async {
        try? await client.close()
    }
}

/// An interactive shell in a pseudo-terminal. Feed keystrokes with `send`, render `onOutput`.
@available(macOS 15.0, *)
public final class SSHTerminal: @unchecked Sendable {
    enum Outgoing {
        case data(Data)
        case resize(columns: Int, rows: Int)
    }

    /// Called on a background thread with raw terminal output (including escape sequences).
    public var onOutput: (@Sendable (Data) -> Void)?
    /// Called once when the shell ends; the error is nil for a normal exit.
    public var onClose: (@Sendable (Error?) -> Void)?

    private let outgoing: AsyncStream<Outgoing>
    private let continuation: AsyncStream<Outgoing>.Continuation
    private var task: Task<Void, Never>?

    init() {
        (outgoing, continuation) = AsyncStream.makeStream(of: Outgoing.self)
    }

    func start(client: SSHClient, columns: Int, rows: Int) {
        let outgoing = self.outgoing
        task = Task { [weak self] in
            do {
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: columns,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:])
                )
                try await client.withPTY(request) { inbound, writer in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await item in outgoing {
                                switch item {
                                case .data(let data):
                                    try await writer.write(ByteBuffer(bytes: data))
                                case .resize(let c, let r):
                                    try await writer.changeSize(cols: c, rows: r, pixelWidth: 0, pixelHeight: 0)
                                }
                            }
                        }
                        for try await chunk in inbound {
                            switch chunk {
                            case .stdout(let buffer), .stderr(let buffer):
                                self?.onOutput?(Data(buffer: buffer))
                            }
                        }
                        group.cancelAll()
                    }
                }
                self?.onClose?(nil)
            } catch {
                self?.onClose?(error)
            }
        }
    }

    public func send(_ data: Data) { continuation.yield(.data(data)) }
    public func send(_ text: String) { send(Data(text.utf8)) }
    public func resize(columns: Int, rows: Int) { continuation.yield(.resize(columns: columns, rows: rows)) }

    public func close() {
        continuation.finish()
        task?.cancel()
    }
}
