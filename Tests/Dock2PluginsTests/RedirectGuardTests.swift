@testable import Dock2Plugins
import Foundation
import Network
import Testing

/// Against a server of its own on the loopback: `/away` redirects to `/here`, which answers "ok".
@Suite struct RedirectGuardTests {
    final class Server: @unchecked Sendable {
        let listener: NWListener
        let queue = DispatchQueue(label: "redirect-test")

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [queue] connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    let request = String(decoding: data ?? Data(), as: UTF8.self)
                    let answer = request.hasPrefix("GET /away")
                        ? "HTTP/1.1 302 Found\r\nLocation: /here\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        : "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                    connection.send(content: Data(answer.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }

        func start() async -> UInt16 {
            await withCheckedContinuation { continuation in
                listener.stateUpdateHandler = { [listener] state in
                    if case .ready = state, let port = listener.port?.rawValue {
                        listener.stateUpdateHandler = nil
                        continuation.resume(returning: port)
                    }
                }
                listener.start(queue: queue)
            }
        }
    }

    func status(_ url: URL, guardedBy redirectGuard: RedirectGuard?) async throws -> Int? {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: url) { _, response, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (response as? HTTPURLResponse)?.statusCode) }
            }
            task.delegate = redirectGuard
            task.resume()
        }
    }

    @Test func aRedirectIsFollowedOnlyWhereThePluginMayReach() async throws {
        let server = try Server()
        let port = await server.start()
        defer { server.listener.cancel() }
        let away = URL(string: "http://127.0.0.1:\(port)/away")!
        // Unguarded, URLSession follows it; guarded — and plain HTTP is never allowed — the redirect is the answer.
        #expect(try await status(away, guardedBy: nil) == 200)
        #expect(try await status(away, guardedBy: RedirectGuard(allowed: ["127.0.0.1"])) == 302)
        #expect(RedirectGuard.mayReach(URL(string: "https://API.example.com:8443/x")!, ["api.example.com"]))
        #expect(!RedirectGuard.mayReach(URL(string: "https://example.com.evil.net/")!, ["example.com"]))
        #expect(!RedirectGuard.mayReach(URL(string: "https://example.com@evil.net/")!, ["example.com"]))
    }
}
