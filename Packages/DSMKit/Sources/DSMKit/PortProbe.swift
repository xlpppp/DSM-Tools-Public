import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Whether `host:port` accepts a TCP connection. This does not speak HTTP or TLS, so a
/// self-signed DSM certificate cannot make a reachable address look down.
public enum PortProbe {
    public static func isOpen(host: String, port: Int, timeout: TimeInterval = 2) async -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, (1...65535).contains(port) else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { connect(host, port, timeout) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64((timeout + 1) * 1_000_000_000))
                return false
            }
            let opened = await group.next() ?? false
            group.cancelAll()
            return opened
        }
    }

    private static func connect(_ host: String, _ port: Int, _ timeout: TimeInterval) -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = streamSocket
        hints.ai_family = AF_UNSPEC
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let info else { return false }
        defer { freeaddrinfo(info) }
        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let ai = cursor {
            let fd = socket(ai.pointee.ai_family, streamSocket, 0)
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let started = systemConnect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
                if started == 0 || errno == EINPROGRESS {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let waited = waitForConnect(&pfd, timeout)
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    close(fd)
                    if started == 0 || (waited > 0 && err == 0) { return true }
                } else {
                    close(fd)
                }
            }
            cursor = ai.pointee.ai_next
        }
        return false
    }

    /// Linux imports `SOCK_STREAM` as an enum; Darwin imports it as `Int32`.
    private static var streamSocket: Int32 {
        #if os(Linux)
        Int32(SOCK_STREAM.rawValue)
        #else
        SOCK_STREAM
        #endif
    }

    private static func waitForConnect(_ pfd: UnsafeMutablePointer<pollfd>, _ timeout: TimeInterval) -> Int32 {
        #if os(Linux)
        poll(pfd, nfds_t(1), Int32(timeout * 1000))
        #else
        poll(pfd, 1, Int32(timeout * 1000))
        #endif
    }

    private static func systemConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>?, _ len: socklen_t) -> Int32 {
        #if os(Linux)
        Glibc.connect(fd, addr, len)
        #else
        Darwin.connect(fd, addr, len)
        #endif
    }
}
