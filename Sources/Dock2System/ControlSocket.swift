import Darwin
import Dock2Core
import Foundation

/// Why the control socket could not be dialed or served.
public enum ControlSocketError: Error, CustomStringConvertible, Equatable {
    /// Nothing listening: dock2 is not running, or runs from elsewhere with another socket.
    case unreachable(String)
    case timedOut
    case closedWithoutReply
    /// Something other than dock2's own socket is at the path, and is left alone.
    case pathTaken(String)
    case systemCall(String, Int32)

    public var description: String {
        switch self {
        case .unreachable(let path): "no dock2 is listening at \(path) — is it running?"
        case .timedOut: "dock2 did not answer in time"
        case .closedWithoutReply: "dock2 closed the connection without answering"
        case .pathTaken(let path): "\(path) is not dock2's socket; set \(ControlWire.socketEnvironmentKey) to choose another"
        case .systemCall(let name, let code): "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// The running dock2's end of the control socket: each connection one request, one reply, then closed. The
/// sockets live on a queue of their own and only the handler runs on the main thread, so a peer that never
/// finishes its line holds nothing but its own descriptor, for at most `timeout`.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (ControlCommand) -> ControlReply

    public let path: String
    private let handler: Handler
    private let timeout: TimeInterval
    /// Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "dock2.control")
    private var listener: DispatchSourceRead?
    /// By a count, not the descriptor: a descriptor is reused the moment it closes, and a deadline set for
    /// one connection must not end the next.
    private var connections: [UInt64: Connection] = [:]
    private var next: UInt64 = 0

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        /// Its request read and its reply on the way: reading has stopped, and the deadline spares it.
        var answering = false

        init(_ fd: Int32, _ source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    public init(path: String = ControlWire.socketPath(environment: LaunchEnvironment.variables), timeout: TimeInterval = 5,
                handler: @escaping Handler) {
        self.path = path
        self.timeout = timeout
        self.handler = handler
    }

    public func start() throws {
        try queue.sync { try listen() }
    }

    /// Closes everything and removes the socket; safe to call twice.
    public func stop() {
        queue.sync {
            for id in Array(connections.keys) { drop(id) }
            guard let listener else { return }
            listener.cancel()
            self.listener = nil
            unlink(path)
        }
    }

    private func listen() throws {
        guard listener == nil else { return }
        try claim()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.systemCall("socket", errno) }
        var address = try ControlClient.address(path)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        // Only this user may dial it.
        let mask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(mask)
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw ControlSocketError.systemCall("bind", code)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
    }

    /// The path is free, or holds a socket of this user's nobody answers — a dock2 that died — which goes.
    private func claim() throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw ControlSocketError.pathTaken(path) }
        guard !ControlClient.isListening(at: path) else { throw ControlSocketError.pathTaken(path) }
        unlink(path)
    }

    private func accept(on listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            next += 1
            let id = next
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(id) }
            source.setCancelHandler { close(fd) }
            connections[id] = Connection(fd, source)
            source.resume()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let connection = self.connections[id], !connection.answering else { return }
                self.drop(id)
            }
        }
    }

    private func read(_ id: UInt64) {
        guard let connection = connections[id] else { return }
        let fd = connection.fd
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count > 0 else {
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            return drop(id)
        }
        connection.buffer.append(contentsOf: chunk[0..<count])
        guard let end = connection.buffer.firstIndex(of: 0x0A) else {
            if connection.buffer.count > ControlWire.maxLineBytes { drop(id) }
            return
        }
        // One line is the whole request: stop reading, answer, close.
        connection.answering = true
        connection.source.suspend()
        let line = connection.buffer[connection.buffer.startIndex..<end]
        let command: ControlCommand
        do {
            command = try ControlWire.decode(ControlWire.Request.self, from: Data(line)).command
        } catch {
            return answer(id, .failed("\(error)"))
        }
        let handler = self.handler
        DispatchQueue.main.async { [weak self] in
            let reply = MainActor.assumeIsolated { handler(command) }
            self?.queue.async { self?.answer(id, reply) }
        }
    }

    private func answer(_ id: UInt64, _ reply: ControlReply) {
        guard let fd = connections[id]?.fd, let data = try? ControlWire.encode(ControlWire.Reply(reply)) else { return drop(id) }
        // Back to blocking, bounded: a reply is small and the peer is waiting for it.
        _ = fcntl(fd, F_SETFL, 0)
        var limit = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let n = write(fd, bytes.baseAddress! + sent, bytes.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
        drop(id)
    }

    private func drop(_ id: UInt64) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source.setEventHandler {}
        // A suspended source must be resumed to be cancelled; cancelling closes the descriptor.
        if connection.answering { connection.source.resume() }
        connection.source.cancel()
    }
}

/// The asking end: one request, one reply, blocking with a deadline — for `dock2 <verb>`, which has nothing
/// else to do while it waits.
public enum ControlClient {
    public static func send(_ command: ControlCommand, to path: String = ControlWire.socketPath(environment: LaunchEnvironment.variables),
                            timeout: TimeInterval = 5) throws -> ControlReply {
        let fd = try connect(path, timeout: timeout)
        defer { close(fd) }
        let request = try ControlWire.encode(ControlWire.Request(command))
        try request.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let n = write(fd, bytes.baseAddress! + sent, bytes.count - sent)
                guard n > 0 else { throw n < 0 && errno == EAGAIN ? ControlSocketError.timedOut : ControlSocketError.systemCall("write", errno) }
                sent += n
            }
        }
        shutdown(fd, SHUT_WR)
        var buffer = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if let end = buffer.firstIndex(of: 0x0A) {
                    return try ControlWire.decode(ControlWire.Reply.self, from: Data(buffer[buffer.startIndex..<end])).reply
                }
                guard buffer.count <= ControlWire.maxLineBytes else { throw ControlSocketError.closedWithoutReply }
                continue
            }
            if n == 0 { throw ControlSocketError.closedWithoutReply }
            if errno == EINTR { continue }
            throw errno == EAGAIN ? ControlSocketError.timedOut : ControlSocketError.systemCall("read", errno)
        }
    }

    /// Something answers at `path`.
    static func isListening(at path: String) -> Bool {
        guard let fd = try? connect(path, timeout: 0.5) else { return false }
        close(fd)
        return true
    }

    private static func connect(_ path: String, timeout: TimeInterval) throws -> Int32 {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.systemCall("socket", errno) }
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            close(fd)
            throw code == ENOENT || code == ECONNREFUSED ? ControlSocketError.unreachable(path) : ControlSocketError.systemCall("connect", code)
        }
        return fd
    }

    /// The address for `path`, which must fit: one that would be cut short names another socket.
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= ControlWire.maxPathBytes else { throw ControlSocketError.pathTaken(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}
