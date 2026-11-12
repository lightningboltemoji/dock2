import Dock2Core
import Foundation
import Testing

@Suite struct PluginProtocolTests {
    let manifestJSON = """
    {"id": "zip.tanner.dock2.bitwarden", "name": "Bitwarden", "version": "1.0.0", "api": 1, "module": "plugin.wasm",
     "capabilities": {"network": {"hosts": ["api.bitwarden.com", "$server"], "reason": "Syncs your vault."},
                      "secrets": {"reason": "Keeps your session."}, "clipboard.write": {"reason": "Copies passwords."}},
     "commands": [{"id": "search", "title": "Search Vault", "icon": {"symbol": "key"}}],
     "results": {"title": "Bitwarden", "minimumQuery": 2, "onByDefault": false},
     "settings": [{"id": "server", "title": "Server", "kind": "text", "default": "https://vault.bitwarden.com"}]}
    """

    @Test func aManifestDecodesValidatesAndNamesItsHosts() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON.utf8))
        try manifest.validate()
        #expect(manifest.capabilities.declared == [.network, .clipboardWrite, .secrets])
        #expect(manifest.capabilities.reason(.secrets) == "Keeps your session.")
        #expect(manifest.settings?.first?.defaultValue == "https://vault.bitwarden.com")
        #expect(manifest.allowedHosts(settings: ["server": "https://Vault.Example.org/base"]) == ["api.bitwarden.com", "vault.example.org"])
        #expect(manifest.lines(.network, settings: ["server": "https://vault.example.org"]) == ["Connects to api.bitwarden.com and vault.example.org"])
        #expect(manifest.lines(.network, settings: [:]) == ["Connects to api.bitwarden.com and the server you set in Server"])
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
        manifest.commands = nil
        for path in ["../icon.png", "/tmp/icon.png", "art/../../icon.png", "icon.svg", "art//icon.png"] {
            manifest.icon = .image(path)
            #expect(throws: PluginManifest.Problem.badImage(path)) { try manifest.validate() }
        }
        manifest.icon = .image("art/icon.png")
        try manifest.validate()
    }

    /// An image in its folder becomes the picture it holds as the plugin loads; one that is not there refuses it.
    @Test func aManifestsImagesAreReadFromItsFolder() throws {
        var manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON.utf8))
        manifest.icon = .image("icon.png")
        manifest.commands?.append(.init(id: "lock", title: "Lock", icon: .image("lock.png")))
        let read = try manifest.readingImages { Data($0.utf8) }
        #expect(read.icon == .png(Data("icon.png".utf8)))
        #expect(read.commands?.map(\.icon) == [.symbol("key"), .png(Data("lock.png".utf8))])
        #expect(throws: PluginManifest.Problem.badImage("icon.png")) {
            try manifest.readingImages { _ in throw CocoaError(.fileReadNoSuchFile) }
        }
    }

    @Test func eventsAndEffectsTravelAsTaggedJSON() throws {
        let events: [PluginEvent] = [
            .started(settings: ["server": "x"], granted: [.network, .secrets]), .granted([.network]), .stopped, .command(id: "search"),
            .query(id: 7, text: "git"),
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

    /// Storage's effects as the SDK writes them — the single-key three among them — and its answers, each
    /// under its request; none needs a capability.
    @Test func storageTravelsAsTheSDKWritesIt() throws {
        let effects = try JSONDecoder().decode([PluginEffect].self, from: Data("""
        [{"type": "storageWrite", "request": "sync", "ops": [{"deletePrefix": "item/"}, {"set": "item/1", "value": "one"}, {"delete": "meta/old"}]},
         {"type": "storageWrite", "ops": []},
         {"type": "storageList", "request": "page", "prefix": "item/", "after": "item/1", "limit": 500, "reverse": true, "keysOnly": true},
         {"type": "storageList", "request": "all"},
         {"type": "storageRead", "request": "both", "keys": ["a", "b"]},
         {"type": "storageGet", "request": "one", "key": "a"}, {"type": "storageSet", "key": "a", "value": "1"}, {"type": "storageDelete", "key": "a"}]
        """.utf8))
        #expect(effects == [
            .storageWrite(request: "sync", ops: [.deletePrefix("item/"), .set(key: "item/1", value: "one"), .delete(key: "meta/old")]),
            .storageWrite(request: nil, ops: []),
            .storageList(StorageListing(request: "page", prefix: "item/", after: "item/1", limit: 500, reverse: true, keysOnly: true)),
            .storageList(StorageListing(request: "all")),
            .storageRead(request: "both", keys: ["a", "b"]),
            .storageGet(request: "one", key: "a"), .storageSet(key: "a", value: "1"), .storageDelete(key: "a"),
        ])
        #expect(effects.map(\.request) == ["sync", nil, "page", "all", "both", "one", nil, nil])
        #expect(effects.allSatisfy { $0.needs == nil })
        for effect in effects {
            #expect(try JSONDecoder().decode(PluginEffect.self, from: JSONEncoder().encode(effect)) == effect)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PluginEffect.self, from: Data(#"{"type": "storageWrite", "ops": [{"put": "a", "value": "1"}]}"#.utf8))
        }

        let events: [PluginEvent] = [
            .storageRead(request: "both", entries: [StorageEntry(key: "a", value: "1")]),
            .storageListed(request: "page", entries: [StorageEntry(key: "item/1", value: "one"), StorageEntry(key: "item/2")], more: true),
            .storageWritten(request: "sync"),
        ]
        for event in events {
            #expect(try JSONDecoder().decode(PluginEvent.self, from: JSONEncoder().encode(event)) == event)
        }
        #expect(events.map(\.request) == ["both", "page", "sync"] && !events.contains(where: \.isInteractive))
        let listed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(events[1])) as? [String: Any]
        #expect(listed?["more"] as? Bool == true && (listed?["entries"] as? [[String: Any]])?.last?["value"] == nil)
    }

    /// A view closed says the item it had selected, as the SDK reads it, and nothing for a view with no selection.
    @Test func aClosedViewSaysWhatItHadSelected() throws {
        let closed = PluginEvent.viewClosed(view: "agenda", selected: "d142")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(closed)) as? [String: Any]
        #expect(json?["type"] as? String == "viewClosed" && json?["selected"] as? String == "d142")
        #expect(try JSONDecoder().decode(PluginEvent.self, from: JSONEncoder().encode(closed)) == closed)
        let form = try JSONDecoder().decode(PluginEvent.self, from: Data(#"{"type":"viewClosed","view":"sign-in"}"#.utf8))
        #expect(form == .viewClosed(view: "sign-in", selected: nil))
    }

    /// A scope chosen names its option and an id an answer can name, as the SDK reads them; the user waits on it, but it
    /// is no action: its answer opens nothing.
    @Test func aScopeChosenNamesItsOptionAndItsID() throws {
        let event = PluginEvent.scope(view: "shares", value: "nas", id: 3)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        #expect(json?["type"] as? String == "scope" && json?["value"] as? String == "nas" && json?["id"] as? Int == 3)
        #expect(try JSONDecoder().decode(PluginEvent.self, from: JSONEncoder().encode(event)) == event)
        #expect(event.isInteractive && !event.isAction)
    }
}
