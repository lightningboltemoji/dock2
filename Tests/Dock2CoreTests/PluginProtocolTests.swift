import Dock2Core
import Foundation
import Testing

@Suite struct PluginProtocolTests {
    let manifestJSON = """
    {"id": "zip.tanner.dock2.bitwarden", "name": "Bitwarden", "version": "1.0.0", "api": 1, "module": "plugin.wasm",
     "capabilities": ["network", "secrets", "clipboard.write"], "hosts": ["api.bitwarden.com", "$server"],
     "commands": [{"id": "search", "title": "Search Vault", "icon": {"symbol": "key"}}],
     "results": {"title": "Bitwarden", "minimumQuery": 2, "onByDefault": false},
     "settings": [{"id": "server", "title": "Server", "kind": "text", "default": "https://vault.bitwarden.com"}]}
    """

    @Test func aManifestDecodesValidatesAndNamesItsHosts() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON.utf8))
        try manifest.validate()
        #expect(manifest.capabilities == [.network, .secrets, .clipboardWrite])
        #expect(manifest.settings?.first?.defaultValue == "https://vault.bitwarden.com")
        #expect(manifest.allowedHosts(settings: ["server": "https://Vault.Example.org/base"]) == ["api.bitwarden.com", "vault.example.org"])
        #expect(PluginCapability.network.describe(hosts: ["api.bitwarden.com"]) == "Connects to api.bitwarden.com")
    }

    @Test func installRefusesWhatItCannotRun() throws {
        var manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON.utf8))
        manifest.id = "bitwarden"
        #expect(throws: PluginManifest.Problem.badID) { try manifest.validate() }
        manifest.id = "zip.tanner.dock2.bitwarden"
        manifest.api = 2
        #expect(throws: PluginManifest.Problem.unsupportedAPI(2)) { try manifest.validate() }
        manifest.api = 1
        manifest.version = "1.0"
        #expect(throws: PluginManifest.Problem.badVersion) { try manifest.validate() }
        manifest.version = "1.0.0"
        manifest.module = "../evil.wasm"
        #expect(throws: PluginManifest.Problem.noModule) { try manifest.validate() }
        manifest.module = "plugin.wasm"
        manifest.commands = [.init(id: "a", title: "A"), .init(id: "a", title: "B")]
        #expect(throws: PluginManifest.Problem.duplicate("a")) { try manifest.validate() }
    }

    @Test func eventsAndEffectsTravelAsTaggedJSON() throws {
        let events: [PluginEvent] = [
            .started(settings: ["server": "x"]), .stopped, .command(id: "search"), .query(id: 7, text: "git"),
            .action(action: "copy", item: "1", view: "vault", result: nil, tile: nil), .submit(view: "login", values: ["email": "a"]),
            .http(request: "r1", status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8), error: nil),
            .nowPlaying(NowPlayingInfo(title: "Song", playing: true, elapsed: 3)), .error(request: "r2", message: "not granted"),
        ]
        for event in events {
            #expect(try JSONDecoder().decode(PluginEvent.self, from: JSONEncoder().encode(event)) == event)
        }
        // As a plugin writes them.
        let effects = try JSONDecoder().decode([PluginEffect].self, from: Data("""
        [{"type": "toast", "text": "Synced"}, {"type": "http", "request": "sync", "url": "https://api.bitwarden.com/sync"},
         {"type": "timer", "id": "tick", "ms": 1000, "repeat": true}, {"type": "copy", "text": "hunter2", "concealed": true},
         {"type": "setTile", "id": "player", "tile": {"label": "Song — Artist", "progress": 0.5, "image": {"symbol": "music.note"}}},
         {"type": "showView", "view": {"type": "detail", "id": "d", "body": "Hi"}}, {"type": "setCommands", "shown": ["search", "lock"]}]
        """.utf8))
        #expect(effects[1] == .http(request: "sync", method: "GET", url: "https://api.bitwarden.com/sync", headers: [:], body: nil))
        #expect(effects[2] == .timer(id: "tick", ms: 1000, repeats: true))
        #expect(effects[6] == .setCommands(shown: ["search", "lock"]))
        #expect(effects.map(\.needs) == [nil, .network, nil, .clipboardWrite, nil, nil, nil])
        #expect(effects[1].request == "sync")
        for effect in effects {
            #expect(try JSONDecoder().decode(PluginEffect.self, from: JSONEncoder().encode(effect)) == effect)
        }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PluginEffect.self, from: Data(#"{"type": "exec", "cmd": "rm"}"#.utf8)) }
        #expect(PluginEvent.query(id: 1, text: "").isInteractive && !PluginEvent.timer(id: "t").isInteractive)
    }

    /// A filter names its id, and an answer the filter it answers, as the SDK writes them.
    @Test func aFiltersAnswerNamesIt() throws {
        let filter = String(decoding: try JSONEncoder().encode(PluginEvent.filter(view: "v", text: "ab", id: 7)), as: UTF8.self)
        #expect(filter.contains(#""id":7"#))
        let answer = try JSONDecoder().decode(PluginEffect.self, from: Data(#"{"type":"updateView","view":{"type":"detail","id":"v"},"answering":7}"#.utf8))
        guard case .updateView(_, let answering) = answer else { Issue.record("not an update"); return }
        #expect(answering == 7)
        let plain = try JSONDecoder().decode(PluginEffect.self, from: Data(#"{"type":"updateView","view":{"type":"detail","id":"v"}}"#.utf8))
        guard case .updateView(_, nil) = plain else { Issue.record("an answer from nothing"); return }
    }
}
