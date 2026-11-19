import Foundation

/// A reply to write, and what to do once it's written (for clients that don't report delivery).
struct Reply: @unchecked Sendable {
    let data: Data
    var written: (@MainActor () -> Void)? = nil
}

struct HelperError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// Unix-socket server speaking newline-delimited JSON: {"id", "client", "cmd", "session", "params", "done",
/// "lost"} → {"id", "ok", "result"|"error"}. A client that hangs up cancels its request (`Connection`).
/// A connection's requests run one at a time, on the main actor; different connections (sessions) run
/// side by side, taking turns at their awaits, with `AppLocks` keeping two off the same app.
final class Server {
    let path: String
    private let fd: Int32

    init(path: String) throws {
        self.path = path
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperError("socket() failed") }
        var addr = Server.address(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { throw HelperError("bind(\(path)) failed: errno \(errno)") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { throw HelperError("listen failed") }
    }

    static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }

    static func isAlive(_ path: String) -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(s) }
        var addr = address(path)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    func start() {
        // A client that hangs up before its reply fails the write (EPIPE) rather than ending the helper.
        signal(SIGPIPE, SIG_IGN)
        let listenFD = fd
        Thread.detachNewThread {
            while true {
                let client = accept(listenFD, nil, nil)
                if client < 0 { continue }
                Thread.detachNewThread { Server.serve(client) }
            }
        }
    }

    private static func serve(_ client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if line.isEmpty { continue }
                // Nothing to write when the client gave up on it (it has hung up).
                guard let reply = handle(line, client) else { continue }
                var out = reply.data
                out.append(0x0A)
                let ok = out.withUnsafeBytes { raw -> Bool in
                    var off = 0
                    while off < raw.count {
                        let w = write(client, raw.baseAddress! + off, raw.count - off)
                        if w <= 0 { return false }
                        off += w
                    }
                    return true
                }
                if !ok { return }
                if let written = reply.written {
                    DispatchQueue.main.async { MainActor.assumeIsolated { written() } }
                }
            }
        }
    }

    private final class Box: @unchecked Sendable { var reply: Reply? }

    private static func handle(_ line: Data, _ fd: Int32) -> Reply? {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.reply = await Handlers.dispatch(line, fd: fd)
            done.signal()
        }
        done.wait()
        return box.reply
    }
}
