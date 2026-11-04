import Dock2Core
import Foundation
import Network

/// A redirect is a request too: followed only where the plugin may reach, else its answer is the redirect
/// itself, status and `Location`, for the plugin to read. `*` among the hosts reaches any.
class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowed: [String]

    init(allowed: [String]) {
        self.allowed = allowed
    }

    /// Over TLS, to a host it names: HTTPS, or a WebSocket's `wss`.
    static func mayReach(_ url: URL, _ allowed: [String]) -> Bool {
        guard ["https", "wss"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else { return false }
        return allowed.contains("*") || allowed.contains(host)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url.map { Self.mayReach($0, allowed) } == true ? request : nil
    }

    static func headers(_ response: URLResponse?) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in (response as? HTTPURLResponse)?.allHeaderFields ?? [:] {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return headers
    }
}

/// An answer read as it comes, to `deliver` on the main actor. Streamed: its status and headers as a part, its
/// body in parts, then its end as the `http` event with no body. Whole: the `http` event, its body up to
/// `bodyLimit`, past which the request is cancelled.
final class ResponseReader: RedirectGuard, URLSessionDataDelegate, @unchecked Sendable {
    /// A whole answer past this is refused: one that big streams.
    static let bodyLimit = 16 << 20

    private let request: String
    private let stream: Bool
    private let deliver: @MainActor @Sendable (PluginEvent) -> Void
    private var status: Int?
    private var headers: [String: String] = [:]
    private var body = Data()
    private var tooLong = false

    init(request: String, allowed: [String], stream: Bool, deliver: @escaping @MainActor @Sendable (PluginEvent) -> Void) {
        self.request = request
        self.stream = stream
        self.deliver = deliver
        super.init(allowed: allowed)
    }

    private func send(_ event: PluginEvent) {
        let deliver = deliver
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(event) } }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode
        headers = Self.headers(response)
        if stream { send(.httpPart(request: request, status: status, headers: headers, body: nil)) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stream else { return send(.httpPart(request: request, status: nil, headers: nil, body: data)) }
        guard body.count + data.count <= Self.bodyLimit else {
            tooLong = true
            return dataTask.cancel()
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let failure = tooLong ? "an answer past 16 MiB: ask for it streamed" : error?.localizedDescription
        send(.http(request: request, status: status, headers: headers, body: stream || tooLong ? nil : body, error: failure))
    }
}

/// A WebSocket a plugin holds open: its opening, each message and its closing go to `deliver` on the main actor,
/// with the socket they came from.
final class PluginWebSocket: RedirectGuard, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let id: String
    private let deliver: @MainActor @Sendable (PluginWebSocket, PluginEvent) -> Void
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var closed = false

    init(id: String, allowed: [String], deliver: @escaping @MainActor @Sendable (PluginWebSocket, PluginEvent) -> Void) {
        self.id = id
        self.deliver = deliver
        super.init(allowed: allowed)
    }

    func open(_ request: URLRequest, in session: URLSession) {
        let task = session.webSocketTask(with: request)
        task.delegate = self
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, case .success(let message) = result else { return }
            switch message {
            case .string(let text): self.send(.webSocketMessage(id: self.id, text: text, data: nil))
            case .data(let data): self.send(.webSocketMessage(id: self.id, text: nil, data: data))
            @unknown default: break
            }
            self.receive(on: task)
        }
    }

    func send(text: String?, data: Data?) {
        let message: URLSessionWebSocketTask.Message = text.map { .string($0) } ?? .data(data ?? Data())
        task?.send(message) { [weak self] error in
            guard let self, let error else { return }
            self.send(.error(request: self.id, message: "the WebSocket's message was not sent: \(error.localizedDescription)"))
        }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
    }

    private func send(_ event: PluginEvent) {
        let deliver = deliver
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(self, event) } }
    }

    /// Once, however it closes.
    private func closing(_ code: Int, _ reason: String?) {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        if first { send(.webSocketClosed(id: id, code: code, reason: reason)) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol chosen: String?) {
        send(.webSocketOpened(id: id, protocol: chosen))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith code: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        closing(code.rawValue, reason.map { String(decoding: $0, as: UTF8.self) })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        closing(URLSessionWebSocketTask.CloseCode.abnormalClosure.rawValue, error?.localizedDescription)
    }
}

/// Plain HTTP/1.1 for `local-network`: to a host and port on this Mac or the local network — the address it
/// reaches checked as local once connected — or over a Unix socket. One request a connection, read as it
/// arrives (`HTTPResponseParser`); a redirect is the answer, never followed.
final class LocalHTTP: @unchecked Sendable {
    enum Target: Sendable {
        case host(HostPort)
        case socket(String)
    }

    struct Request: Sendable {
        let id: String
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?
        let stream: Bool
    }

    /// Silence this long, connecting or reading, ends it.
    static let idleLimit: TimeInterval = 30

    private let target: Target
    private let request: Request
    private let deliver: @MainActor @Sendable (PluginEvent) -> Void
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "zip.tanner.dock2.plugin-local-http")
    // Touched only on `queue`.
    private var parser: HTTPResponseParser
    private var head: HTTPResponseParser.Head?
    private var body = Data()
    private var finished = false
    private var idle: DispatchWorkItem?

    init(_ target: Target, _ request: Request, deliver: @escaping @MainActor @Sendable (PluginEvent) -> Void) {
        self.target = target
        self.request = request
        self.deliver = deliver
        parser = HTTPResponseParser(method: request.method)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(Self.idleLimit)
        let parameters = NWParameters(tls: nil, tcp: tcp)
        switch target {
        case .host(let address):
            connection = NWConnection(to: .hostPort(host: NWEndpoint.Host(address.host), port: NWEndpoint.Port(rawValue: address.port)!), using: parameters)
        case .socket(let path):
            connection = NWConnection(to: .unix(path: path), using: parameters)
        }
    }

    /// The bytes it sends: a request line, the plugin's headers but those dock2 writes, and its body.
    static func bytes(_ request: Request, host: String) throws -> Data {
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        let path = (components?.percentEncodedPath).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        let target = components?.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
        var lines = ["\(request.method.uppercased()) \(target) HTTP/1.1", "Host: \(host)"]
        guard HTTPSyntax.isToken(request.method) else { throw PluginFailure("“\(request.method)” is not a method") }
        let own: Set<String> = ["host", "content-length", "connection", "transfer-encoding"]
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) {
            guard HTTPSyntax.isToken(name), HTTPSyntax.isFieldValue(value) else { throw PluginFailure("the header “\(name)” is not one HTTP can carry") }
            if !own.contains(name.lowercased()) { lines.append("\(name): \(value)") }
        }
        if let body = request.body { lines.append("Content-Length: \(body.count)") }
        lines.append("Connection: close")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + (request.body ?? Data())
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.ready()
            case .failed(let error), .waiting(let error): self.fail(error.localizedDescription)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.async { self.touch() }
    }

    func cancel() {
        queue.async { [self] in
            finished = true
            idle?.cancel()
            connection.cancel()
        }
    }

    // MARK: - On the queue

    private func ready() {
        if case .host = target {
            guard let reached = Self.reachedAddress(connection) else { return fail("it reached an address dock2 cannot read") }
            guard HostPort.isLocalAddress(reached) == true else { return fail("it reached \(reached), which is neither this Mac nor the local network") }
        }
        let host: String = switch target {
        case .host(let address): address.port == 80 ? address.host : address.spelled
        case .socket: "localhost"
        }
        let bytes: Data
        do { bytes = try Self.bytes(request, host: host) } catch { return fail(error.localizedDescription) }
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(error.localizedDescription) } else { self?.read() }
        })
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            self.touch()
            do {
                if let data, !data.isEmpty { try self.take(self.parser.feed(data)) }
                if isComplete, !self.finished { try self.take(self.parser.finish()) }
            } catch {
                return self.fail(error.localizedDescription)
            }
            if let error, !self.finished { return self.fail(error.localizedDescription) }
            if !self.finished { self.read() }
        }
    }

    private func take(_ pieces: [HTTPResponseParser.Piece]) throws {
        for piece in pieces {
            switch piece {
            case .head(let head):
                self.head = head
                if request.stream { send(.httpPart(request: request.id, status: head.status, headers: head.headers, body: nil)) }
            case .body(let data):
                if request.stream {
                    send(.httpPart(request: request.id, status: nil, headers: nil, body: data))
                } else {
                    guard body.count + data.count <= ResponseReader.bodyLimit else {
                        throw PluginFailure("an answer past 16 MiB: ask for it streamed")
                    }
                    body.append(data)
                }
            case .end:
                finish(.http(request: request.id, status: head?.status, headers: head?.headers ?? [:], body: request.stream ? nil : body, error: nil))
            }
        }
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finish(.http(request: request.id, status: head?.status, headers: head?.headers ?? [:], body: nil, error: message))
    }

    private func finish(_ event: PluginEvent) {
        guard !finished else { return }
        finished = true
        idle?.cancel()
        connection.cancel()
        send(event)
    }

    private func touch() {
        idle?.cancel()
        let idle = DispatchWorkItem { [weak self] in self?.fail("no answer in \(Int(Self.idleLimit)) seconds") }
        self.idle = idle
        queue.asyncAfter(deadline: .now() + Self.idleLimit, execute: idle)
    }

    private func send(_ event: PluginEvent) {
        let deliver = deliver
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(event) } }
    }

    /// The address a connection reached, without its interface: `192.168.1.5`, `fe80::1`.
    static func reachedAddress(_ connection: NWConnection) -> String? {
        guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint else { return nil }
        let spelled: String = switch host {
        case .ipv4(let address): "\(address)"
        case .ipv6(let address): "\(address)"
        case .name(let name, _): name
        @unknown default: "\(host)"
        }
        return spelled.split(separator: "%").first.map(String.init)
    }
}
