import Dock2Core
@testable import Dock2Plugins
import Dock2System
import Foundation
import Testing
import XPC

/// A service of the test's own, on an anonymous listener: it answers each message with the plugin id it was
/// told and the `n` it was sent, then sends a note unasked.
final class TestService: @unchecked Sendable {
    let listener: xpc_connection_t
    let endpoint: xpc_endpoint_t
    private let queue = DispatchQueue(label: "zip.tanner.dock2.test-service")

    init() {
        listener = xpc_connection_create(nil, queue)
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            xpc_connection_set_event_handler(peer) { message in
                guard xpc_get_type(message) == XPC_TYPE_DICTIONARY, let reply = xpc_dictionary_create_reply(message) else { return }
                if let plugin = xpc_dictionary_get_value(message, "dock2.plugin") { xpc_dictionary_set_value(reply, "plugin", plugin) }
                if let n = xpc_dictionary_get_value(message, "n") { xpc_dictionary_set_value(reply, "n", n) }
                xpc_connection_send_message(peer, reply)
                let note = xpc_dictionary_create(nil, nil, 0)
                xpc_dictionary_set_string(note, "note", "hello")
                xpc_connection_send_message(peer, note)
            }
            xpc_connection_activate(peer)
        }
        xpc_connection_activate(listener)
        endpoint = xpc_endpoint_create(listener)
    }
}

@MainActor
@Suite(.serialized) struct PluginXPCTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-xpc-\(UUID().uuidString)", isDirectory: true)
    let id = "zip.tanner.dock2.test-guest"
    let service = TestService()

    func host(_ recorder: Recorder, team: Bool = false) -> PluginHost {
        let host = TestHost.make(recorder, in: directory)
        let endpoint = service.endpoint
        host.xpc.connect = { service in
            let connection = xpc_connection_create_from_endpoint(endpoint)
            if team { PluginXPC.require(team: service.team, of: connection) }
            return connection
        }
        return host
    }

    func settle(_ recorder: Recorder, until prefix: String) async throws {
        try await TestHost.settle(until: { recorder.toasts.contains { $0.hasPrefix(prefix) } }, seconds: 5)
    }

    /// The service is told which plugin speaks — dock2's word over the plugin's — and its int stays an int.
    @Test func aServiceIsToldWhichPluginSpeaksAndAnswers() async throws {
        let recorder = Recorder(), host = host(recorder)
        host.send(.command(id: "xpc"), to: id)
        try await settle(recorder, until: "unasked")
        #expect(recorder.toasts.contains("reply from zip.tanner.dock2.test-guest n=Some(Int(7))"))
        #expect(recorder.toasts.contains("unasked hello"))
        let connection = PluginResources.Key(.connection, "zip.tanner.dock2.test-service")
        #expect(host.resources.holds(connection, of: id))
        // Revoked, the connection goes.
        host.setGranted(id, .xpc, false)
        #expect(host.resources.isIdle(id))
    }

    /// A peer not signed by the team the manifest names is refused, by macOS, before it hears a word.
    @Test func aServiceNotSignedByItsTeamIsRefused() async throws {
        let recorder = Recorder(), host = host(recorder, team: true)
        host.send(.command(id: "xpc"), to: id)
        try await settle(recorder, until: "error")
        #expect(recorder.toasts.contains { $0.hasPrefix("error: zip.tanner.dock2.test-service: peer forbidden") })
        #expect(!recorder.toasts.contains { $0.hasPrefix("reply") })
    }

    @Test func onlyAServiceTheManifestNamesIsReached() async throws {
        let recorder = Recorder(), host = host(recorder)
        host.send(.command(id: "xpc-elsewhere"), to: id)
        try await settle(recorder, until: "error")
        #expect(recorder.toasts.contains("error: com.example.unnamed is not a service it names"))
    }

    /// What a plugin cannot hold is refused, whole.
    @Test func aReplyHoldingADescriptorIsRefused() throws {
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_fd(reply, "fd", 0)
        #expect(throws: XPCValue.Refusal.self) { try PluginXPC.value(reply) }
        let date = XPCValue.dictionary(["at": .date(42), "id": .uuid(UUID()), "bytes": .data(Data([9]))])
        #expect(try PluginXPC.value(PluginXPC.object(date)) == date)
    }
}
