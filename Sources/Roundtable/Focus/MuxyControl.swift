import Foundation
import Darwin

/// Talks to muxy's command socket (`~/Library/Application Support/Muxy/muxy.sock`,
/// distinct from the notification socket in MUXY_SOCKET_PATH). Unidentified
/// clients are allowed the privileged verbs, same as muxy's own CLI wrapper, so
/// no extension or grant is needed. Line protocol: `verb|arg|arg`.
enum MuxyControl {

    static func socketPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Muxy/muxy.sock"
    }

    /// Fire-and-forget: send one command, don't wait for a reply.
    static func send(_ command: String) {
        guard let fd = openSocket() else { return }
        defer { close(fd) }
        writeLine(fd, command)
    }

    /// Send one command and read its reply (e.g. `read-screen`). Bounded by a
    /// short timeout so a wedged socket can't hang the caller.
    static func query(_ command: String, timeout: TimeInterval = 1.0) -> String? {
        guard let fd = openSocket() else { return nil }
        defer { close(fd) }
        writeLine(fd, command)

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
            if n < buf.count { break }   // drained what was ready
        }
        return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
    }

    // MARK: - Raw socket

    private static func openSocket() -> Int32? {
        let path = socketPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= cap else { close(fd); return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        guard ok == 0 else { close(fd); return nil }
        return fd
    }

    private static func writeLine(_ fd: Int32, _ message: String) {
        Array((message + "\n").utf8).withUnsafeBytes { _ = Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }
}
