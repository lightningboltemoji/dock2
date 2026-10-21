import Darwin
import Dock2Core
@testable import Dock2System
import Foundation
import Testing

@Suite(.serialized) struct ControlSocketTests {
    private func path() -> String { "/tmp/dock2-test-\(UUID().uuidString.prefix(8)).sock" }

    @MainActor @Test func aRequestIsAnsweredOnTheMainThread() async throws {
        let path = path()
        let server = ControlServer(path: path) { command in
            MainActor.assertIsolated()
            return command == .status ? .json("{}") : .failed("not status")
        }
        try server.start()
        defer { server.stop() }
        let reply = try await Task.detached { try ControlClient.send(.status, to: path) }.value
        #expect(reply == .json("{}"))
        let refused = try await Task.detached { try ControlClient.send(.dismiss, to: path) }.value
        #expect(refused == .failed("not status"))
    }

    /// A connection's deadline is its own: one closed early never ends the next, which reuses its descriptor.
    @MainActor @Test func aDeadlineEndsOnlyItsOwnConnection() async throws {
        let path = path()
        let server = ControlServer(path: path, timeout: 0.5) { _ in .ok }
        try server.start()
        defer { server.stop() }
        let first = try await Task.detached { try ControlClient.send(.status, to: path) }.value
        #expect(first == .ok)
        // The next connection takes the first one's descriptor, and is quiet past the first's deadline but not
        // past its own.
        let reply = try await Task.detached { () throws -> String in
            usleep(300_000)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var address = try ControlClient.address(path)
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            usleep(300_000)
            let line = try ControlWire.encode(ControlWire.Request(.status))
            _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            var chunk = [UInt8](repeating: 0, count: 256)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            return n > 0 ? String(decoding: chunk[0..<n], as: UTF8.self) : ""
        }.value
        #expect(reply.contains("ok"))
    }

    @Test func stoppingRemovesTheSocket() throws {
        let path = path()
        let server = ControlServer(path: path) { _ in .ok }
        try server.start()
        #expect(FileManager.default.fileExists(atPath: path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: ControlSocketError.unreachable(path)) { try ControlClient.send(.status, to: path) }
    }

    @Test func aDeadDock2sSocketIsTakenOver() throws {
        let path = path()
        // Bound and abandoned, as a crash leaves it.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try ControlClient.address(path)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(fd)
        let server = ControlServer(path: path) { _ in .ok }
        try server.start()
        server.stop()
    }

    @Test func anythingElseAtThePathIsLeftAlone() throws {
        let path = path()
        try Data("mine".utf8).write(to: URL(fileURLWithPath: path))
        defer { unlink(path) }
        #expect(throws: ControlSocketError.pathTaken(path)) { try ControlServer(path: path) { _ in .ok }.start() }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "mine")
    }

    @Test func aLiveDock2KeepsItsSocket() throws {
        let path = path()
        let first = ControlServer(path: path) { _ in .ok }
        try first.start()
        defer { first.stop() }
        #expect(throws: ControlSocketError.pathTaken(path)) { try ControlServer(path: path) { _ in .ok }.start() }
    }
}
