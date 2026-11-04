import Dock2Core
@testable import Dock2Plugins
import Foundation
import Network
import Testing

/// An HTTP server of the test's own, on the loopback or a Unix socket: each request whole, answered in the
/// pieces `answer` gives, a twentieth of a second apart, then the connection closed.
final class LoopbackServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "zip.tanner.dock2.loopback")

    final class Received: @unchecked Sendable { var data = Data() }

    init(unix path: String? = nil, answer: @escaping @Sendable (String) -> [String]) throws {
        let parameters = NWParameters.tcp
        if let path {
            unlink(path)
            parameters.requiredLocalEndpoint = .unix(path: path)
        } else {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        }
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            let received = Received()
            @Sendable func send(_ pieces: [String]) {
                guard let first = pieces.first else {
                    return connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                }
                connection.send(content: Data(first.utf8), completion: .contentProcessed { _ in
                    queue.asyncAfter(deadline: .now() + 0.05) { send(Array(pieces.dropFirst())) }
                })
            }
            @Sendable func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    received.data.append(data ?? Data())
                    let text = String(decoding: received.data, as: UTF8.self)
                    guard let end = text.range(of: "\r\n\r\n") else { return receive() }
                    let length = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                    guard text[end.upperBound...].utf8.count >= length else { return receive() }
                    send(answer(text))
                }
            }
            receive()
        }
    }

    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state {
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                }
            }
            listener.start(queue: queue)
        }
    }

    /// "POST /echo?x=1 yes ping": the request line's first two words, its X-Test header and its body.
    static func echo(_ request: String) -> String {
        let lines = request.components(separatedBy: "\r\n")
        let line = lines.first?.split(separator: " ").prefix(2).joined(separator: " ") ?? ""
        let header = lines.first { $0.lowercased().hasPrefix("x-test:") }.map { $0.dropFirst("x-test:".count).trimmingCharacters(in: .whitespaces) }
        let body = request.components(separatedBy: "\r\n\r\n").dropFirst().joined()
        return [line, header, body.isEmpty ? nil : body].compactMap { $0 }.joined(separator: " ")
    }
}

@MainActor
@Suite(.serialized) struct PluginNetworkTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-net-\(UUID().uuidString)", isDirectory: true)
    let id = TestHost.id

    func local() async throws -> (LoopbackServer, String) {
        let server = try LoopbackServer { request in
            if request.hasPrefix("GET /stream") {
                return ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", "3\r\none\r\n", "3\r\ntwo\r\n", "0\r\n\r\n"]
            }
            let body = LoopbackServer.echo(request)
            return ["HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"]
        }
        return (server, "http://127.0.0.1:\(await server.start())")
    }

    func toast(_ recorder: Recorder, _ prefix: String) -> String? {
        recorder.toasts.first { $0.hasPrefix(prefix) }
    }

    @Test func plainHTTPToAHostItNames() async throws {
        let (server, address) = try await local()
        defer { server.listener.cancel() }
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory, settings: ["local": address])
        host.send(.command(id: "local"), to: id)
        try await TestHost.settle(until: { toast(recorder, "http local") != nil }, seconds: 5)
        #expect(toast(recorder, "http local") == "http local Some(200) Some(\"POST /echo?x=1 yes ping\") None parts=[]")
    }

    /// Streamed, the head and each chunk come as they arrive; the end carries no body.
    @Test func aStreamedAnswerComesInParts() async throws {
        let (server, address) = try await local()
        defer { server.listener.cancel() }
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory, settings: ["local": address])
        host.send(.command(id: "local-stream"), to: id)
        try await TestHost.settle(until: { toast(recorder, "http stream") != nil }, seconds: 5)
        #expect(toast(recorder, "http stream") == "http stream Some(200) None None parts=[stream head 200, stream part one, stream part two]")
    }

    @Test func overASocketItNames() async throws {
        let server = try LoopbackServer(unix: "/tmp/dock2-test-guest.sock") { request in
            let body = LoopbackServer.echo(request)
            return ["HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"]
        }
        _ = await server.start()
        defer { server.listener.cancel() }
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory)
        host.send(.command(id: "local-socket"), to: id)
        try await TestHost.settle(until: { toast(recorder, "http socket") != nil }, seconds: 5)
        #expect(toast(recorder, "http socket") == "http socket Some(200) Some(\"GET /v1/info\") None parts=[]")
    }

    /// A port it does not name, or a host out on the internet, is refused before anything connects.
    @Test func onlyTheHostsAndPortsItNames() async throws {
        let (server, address) = try await local()
        defer { server.listener.cancel() }
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory, settings: ["local": address])
        host.send(.command(id: "local-elsewhere"), to: id)
        host.send(.command(id: "plain-internet"), to: id)
        try await TestHost.settle(until: { recorder.toasts.filter { $0.hasPrefix("error") }.count == 2 }, seconds: 5)
        #expect(recorder.toasts.contains("error: http://127.0.0.1:1/ is not on a host it may reach"))
        #expect(recorder.toasts.contains("error: http://example.com/ is not on a host it may reach"))
    }

    /// Revoked mid-stream, the plugin is told, and hears no more of it.
    @Test func revokingLocalNetworkEndsAStream() async throws {
        let server = try LoopbackServer { _ in ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"] + Array(repeating: "1\r\nx\r\n", count: 60) + ["0\r\n\r\n"] }
        let port = await server.start()
        defer { server.listener.cancel() }
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory, settings: ["local": "http://127.0.0.1:\(port)"])
        host.send(.command(id: "local-stream"), to: id)
        try await TestHost.settle(until: { !host.resources.keys(.request, of: id).isEmpty }, seconds: 3)
        try await TestHost.settle(seconds: 0.3)
        host.setGranted(id, .localNetwork, false)
        try await TestHost.settle(until: { toast(recorder, "error") != nil }, seconds: 3)
        #expect(recorder.toasts.contains("error: local-network was revoked"))
        #expect(toast(recorder, "http stream") == nil)
    }

    @Test func anyHostIsAStarAway() {
        #expect(RedirectGuard.mayReach(URL(string: "https://anything.example.net/x")!, ["*"]))
        #expect(RedirectGuard.mayReach(URL(string: "wss://api.example.com/socket")!, ["api.example.com"]))
        #expect(!RedirectGuard.mayReach(URL(string: "http://anything.example.net/")!, ["*"]))
        #expect(!RedirectGuard.mayReach(URL(string: "ws://api.example.com/")!, ["api.example.com"]))
    }

    /// A WebSocket's opening, its messages both ways, and its closing, against an echo of the test's own.
    @Test func aWebSocketOpensTalksAndCloses() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "zip.tanner.dock2.echo")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            @Sendable func echo() {
                connection.receiveMessage { content, context, _, error in
                    guard error == nil, let content, let context else { return }
                    connection.send(content: content, contentContext: context, completion: .contentProcessed { _ in echo() })
                }
            }
            echo()
        }
        let port = await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port?.rawValue ?? 0) }
            }
            listener.start(queue: queue)
        }
        defer { listener.cancel() }
        var events: [PluginEvent] = []
        let socket = PluginWebSocket(id: "s", allowed: []) { _, event in events.append(event) }
        socket.open(URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/")!), in: URLSession(configuration: .ephemeral))
        try await TestHost.settle(until: { events.contains { if case .webSocketOpened = $0 { true } else { false } } }, seconds: 5)
        socket.send(text: "hello", data: nil)
        try await TestHost.settle(until: { events.contains(.webSocketMessage(id: "s", text: "hello", data: nil)) }, seconds: 5)
        socket.close()
        try await TestHost.settle(until: { events.contains { if case .webSocketClosed = $0 { true } else { false } } }, seconds: 5)
        #expect(events.first == .webSocketOpened(id: "s", protocol: nil))
        #expect(events.contains(.webSocketMessage(id: "s", text: "hello", data: nil)))
        #expect(events.filter { if case .webSocketClosed = $0 { true } else { false } }.count == 1)
    }

    /// The host opens only a secure WebSocket, and only to a host the plugin names.
    @Test func aWebSocketIsSecureAndToAHostItNames() async throws {
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory)
        host.perform([.webSocketOpen(id: "a", url: "ws://example.com/", headers: [:], protocols: []),
                      .webSocketOpen(id: "b", url: "wss://elsewhere.net/", headers: [:], protocols: []),
                      .webSocketSend(id: "c", text: "hi", data: nil)], from: id, answering: .command(id: "c"))
        try await TestHost.settle(until: { recorder.toasts.filter { $0.hasPrefix("error") }.count == 3 }, seconds: 3)
        #expect(recorder.toasts.contains("error: ws://example.com/ is not a host it may reach over a secure WebSocket"))
        #expect(recorder.toasts.contains("error: wss://elsewhere.net/ is not a host it may reach over a secure WebSocket"))
        #expect(recorder.toasts.contains("error: no WebSocket c is open"))
    }
}

/// `apps`: what `open` comes to, decided without opening anything.
@Suite struct PluginOpeningTests {
    let apps = PluginManifest.Capabilities.Apps(schemes: ["zed"], apps: ["com.apple.TextEdit"], reason: "Opens notes.")
    let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    static let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    func opening(_ url: String, in app: String? = nil, apps: PluginManifest.Capabilities.Apps?,
                 handler: URL? = URL(fileURLWithPath: "/Applications/Zed.app")) -> Result<PluginHost.Opening, PluginFailure> {
        PluginHost.opening(url, in: app, apps: apps, appURL: { $0 == "com.apple.TextEdit" ? textEdit : nil }, handler: { _ in handler },
                           runs: { $0 == Self.terminal })
    }

    /// Read from the app itself: a Shell role, or a program it views; an editor of scripts runs none.
    @Test func anAppThatRunsWhatItOpensSaysSo() {
        #expect(PluginHost.runsWhatItOpens(Self.terminal))
        #expect(PluginHost.runsWhatItOpens(URL(fileURLWithPath: "/System/Library/CoreServices/JavaLauncher.app")))
        #expect(PluginHost.runsWhatItOpens(URL(fileURLWithPath: "/System/Applications/Utilities/Script Editor.app")))
        #expect(!PluginHost.runsWhatItOpens(textEdit))
        let ghostty = URL(fileURLWithPath: "/Applications/Ghostty.app")
        if FileManager.default.fileExists(atPath: ghostty.path) { #expect(PluginHost.runsWhatItOpens(ghostty)) }
    }

    /// What installs or launches something on opening is no document.
    @Test func profilesAndLaunchersAreNoDocuments() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.configprofile", "a.provisionprofile", "a.jnlp", "a.mobileconfig"] {
            let file = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: file)
            #expect(!PluginHost.isDocument(file), "\(name)")
        }
    }

    @Test func pagesAndDocumentsNeedNothing() throws {
        #expect(PluginEffect.open(url: "https://example.com").needs == nil)
        #expect(PluginEffect.open(url: "zed://file/x").needs == .apps)
        #expect(PluginEffect.open(url: "file:///tmp/a.txt", app: "com.apple.TextEdit").needs == .apps)
        #expect(try opening("https://example.com", apps: nil).get() == .url(URL(string: "https://example.com")!))
    }

    @Test func aSchemeItNamesOpensUnlessItsAppRunsWhatItOpens() throws {
        #expect(try opening("zed://file/x", apps: apps).get() == .url(URL(string: "zed://file/x")!))
        #expect(throws: PluginFailure.self) { try opening("obsidian://x", apps: apps).get() }
        #expect(throws: PluginFailure.self) { try opening("zed://x", apps: nil).get() }
        #expect(throws: PluginFailure("zed: links open in com.apple.Terminal, which runs what it opens")) {
            try opening("zed://x", apps: apps, handler: Self.terminal).get()
        }
        #expect(throws: PluginFailure("nothing on this Mac opens zed: links")) { try opening("zed://x", apps: apps, handler: nil).get() }
    }

    @Test func aFileInAnAppItNames() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-open-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        #expect(try opening(file.absoluteString, in: "com.apple.TextEdit", apps: apps).get() == .file(file, in: textEdit))
        #expect(throws: PluginFailure("com.apple.Terminal is not an app it names")) {
            try opening(file.absoluteString, in: "com.apple.Terminal", apps: apps).get()
        }
        #expect(throws: PluginFailure.self) { try opening("file:///nowhere/at/all.txt", in: "com.apple.TextEdit", apps: apps).get() }
    }
}
