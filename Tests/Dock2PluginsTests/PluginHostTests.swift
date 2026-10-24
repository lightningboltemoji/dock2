import Dock2Core
@testable import Dock2Plugins
import Dock2System
import Dock2TOML
import Foundation
import Testing

@MainActor
final class Recorder: PluginHostDelegate {
    var toasts: [String] = []
    var views: [ViewNode] = []
    var results: [(Int, [PluginResult])] = []
    var disabled: [String] = []
    var summoning: [Bool] = []

    func plugin(_ id: String, show view: ViewNode, summoning: Bool) {
        views.append(view)
        self.summoning.append(summoning)
    }
    func plugin(_ id: String, update view: ViewNode, answering: Int?) { views.append(view) }
    func pluginPopView(_ id: String) {}
    func pluginCloseView(_ id: String) {}
    func pluginDismiss(_ id: String) {}
    func plugin(_ id: String, results: [PluginResult], for query: Int) { self.results.append((query, results)) }
    func plugin(_ id: String, tile: String, set node: TileNode?) {}
    func plugin(_ id: String, toast text: String) { toasts.append(text) }
    func pluginPaste(_ id: String) {}
    func pluginDisabled(_ id: String, because reason: String) { disabled.append(reason) }
    var showing = false
    func pluginIsShowing(_ id: String) -> Bool { showing }
}

@MainActor
@Suite(.serialized) struct PluginHostTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-plugins-\(UUID().uuidString)", isDirectory: true)
    let id = "zip.tanner.dock2.test-guest"

    /// The config file, in the test's own folder.
    var config: SettingsFile {
        SettingsFile(url: directory.appendingPathComponent("config.toml"), lastGood: nil, lock: directory.appendingPathComponent("config.lock"),
                     state: directory.appendingPathComponent("state.json"))
    }

    /// The config file as one process sees it; a second is another process, or dock2 launched again.
    func settings() -> SettingsStore {
        SettingsStore(file: config, watch: false)
    }

    func store(firstParty: Bool = true, settings: SettingsStore? = nil) -> PluginStore {
        PluginStore(settings: settings ?? self.settings(), firstParty: firstParty ? TestGuest.folder.deletingLastPathComponent() : nil, directory: directory)
    }

    var configText: String { (try? String(contentsOf: config.url, encoding: .utf8)) ?? "" }

    /// The test guest comes with this dock2, switched on.
    func host(_ recorder: Recorder) -> PluginHost {
        let store = store()
        store.update(id) { $0.enabled = true }
        let host = PluginHost(store: store, nowPlaying: NowPlaying(helpers: nil))
        host.delegate = recorder
        return host
    }

    /// Two hops: the instance's queue, then the main queue's effects, then perhaps another event.
    func settle() async throws {
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(40)) }
    }

    /// Off until the user switches it on, then holding what it declares.
    @Test func firstPartyPluginsStartOffHoldingWhatTheyDeclare() throws {
        let store = store()
        #expect(store.plugins.map(\.id) == [id] && !store.isEnabled(id) && !store.resultsOn(id))
        #expect(PluginCapability.allCases.filter { store.grants(id, $0) } == [.network, .query, .secrets])
        store.update(id) { $0.enabled = true }
        #expect(store.resultsOn(id))
        store.settings.flush()
        #expect(configText.hasSuffix("[plugins.\"zip.tanner.dock2.test-guest\"]\nenabled = true\n"))
    }

    /// The manifest's hidden commands wait for the plugin to show them; what it shows outlives dock2.
    @Test func aPluginShowsAndHidesItsCommands() throws {
        let recorder = Recorder(), host = host(recorder)
        #expect(host.store.commands(of: id).map(\.id) == ["echo", "view", "grid"])
        host.perform([.setCommands(shown: ["later", "echo", "nowhere"])], from: id, answering: .timer(id: "t"))
        #expect(host.store.commands(of: id).map(\.id) == ["echo", "later"])
        let again = store()
        #expect(again.commands(of: id).map(\.id) == ["echo", "later"])
    }

    /// An instance with nothing to do unloads once it has heard nothing for a while; one showing a view stays.
    @Test func anIdleInstanceUnloads() async throws {
        let recorder = Recorder(), host = host(recorder)
        host.send(.command(id: "keep"), to: id)
        try await settle()
        #expect(host.loaded.contains(id))
        host.unloadIdle(now: Date())
        #expect(host.loaded.contains(id))
        recorder.showing = true
        host.unloadIdle(now: Date().addingTimeInterval(PluginHost.idleAfter + 1))
        #expect(host.loaded.contains(id))
        recorder.showing = false
        host.unloadIdle(now: Date().addingTimeInterval(PluginHost.idleAfter + 1))
        #expect(!host.loaded.contains(id))
    }

    /// What the user did brings dock2 up, and so does the answer to a request it made; a timer's view does not.
    @Test func onlyTheUserOrWhatTheyAskedForSummons() async throws {
        let recorder = Recorder(), host = host(recorder)
        let view = ViewNode.list(ListNode(id: "v", sections: []))
        host.perform([.storageGet(request: "asked", key: "k")], from: id, answering: .tile(id: "t"))
        host.perform([.showView(view)], from: id, answering: .storage(request: "asked", key: "k", value: nil))
        host.perform([.showView(view)], from: id, answering: .storage(request: "asked", key: "k", value: nil))
        host.perform([.showView(view)], from: id, answering: .timer(id: "tick"))
        host.perform([.showView(view)], from: id, answering: .command(id: "c"))
        // The user dismissed dock2 before the answer came: it brings dock2 up no more than a timer's does.
        host.perform([.storageGet(request: "left", key: "k")], from: id, answering: .tile(id: "t"))
        host.userMovedOn()
        host.perform([.showView(view)], from: id, answering: .storage(request: "left", key: "k", value: nil))
        #expect(recorder.summoning == [true, false, false, true, false])
        try await settle()
    }

    @Test func whatIsNotGrantedIsRefusedBackToThePlugin() async throws {
        let recorder = Recorder()
        let host = host(recorder)
        host.send(.command(id: "forbidden"), to: id)
        try await settle()
        #expect(recorder.toasts.contains("error: clipboard.write is not granted"))
    }

    @Test func storageOutlivesTheInstance() async throws {
        let recorder = Recorder()
        let host = host(recorder)
        host.send(.command(id: "remember"), to: id)
        try await settle()
        host.stop(id)
        host.send(.command(id: "recall"), to: id)
        try await settle()
        // Its third event remembered: started, remember… then a fresh instance recalls it.
        #expect(recorder.toasts.contains("count=2"))
    }

    @Test func resultsAndViewsReachTheDelegate() async throws {
        let recorder = Recorder()
        let host = host(recorder)
        host.send(.query(id: 9, text: "err"), to: id)
        host.send(.command(id: "view"), to: id)
        try await settle()
        #expect(recorder.results.first?.0 == 9 && recorder.results.first?.1.map(\.id) == ["cherry"])
        #expect(recorder.views.count == 1)
    }

    @Test func aPluginSwitchedOffHearsNothing() async throws {
        let recorder = Recorder()
        let host = host(recorder)
        host.store.update(id) { $0.enabled = false }
        host.send(.command(id: "echo"), to: id)
        try await settle()
        #expect(recorder.toasts.isEmpty)
    }

    /// Off the main thread and back, in the order asked.
    @Test func secretsAreKeptAndReadBack() async throws {
        let recorder = Recorder()
        let host = host(recorder)
        host.send(.command(id: "keep"), to: id)
        host.send(.command(id: "find"), to: id)
        try await settle()
        #expect(recorder.toasts.contains("secret k=v"))
    }

    /// A plugin opens pages and documents, never programs.
    @Test func onlyDocumentsOpen() throws {
        let text = directory.appendingPathComponent("note.txt"), script = directory.appendingPathComponent("run.command")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: text)
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        #expect(PluginHost.isDocument(text))
        #expect(!PluginHost.isDocument(script))
        #expect(!PluginHost.isDocument(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        #expect(!PluginHost.isDocument(URL(fileURLWithPath: "/bin/ls")))
        for launcher in ["settings.terminal", "place.fileloc", "run.workflow", "profile.mobileconfig", "do.shortcut"] {
            let file = directory.appendingPathComponent(launcher)
            try Data("x".utf8).write(to: file)
            #expect(!PluginHost.isDocument(file), "\(launcher)")
        }
        let page = directory.appendingPathComponent("page.pdf")
        try Data("%PDF-1.4".utf8).write(to: page)
        #expect(PluginHost.isDocument(page))
    }

    /// A secure setting is a secret, never in the config file, and the plugin cannot reach it as one.
    @Test func aSecureSettingIsKeptAsASecret() async throws {
        let recorder = Recorder()
        let host = host(recorder)
        host.store.setSetting(id, "token", "s3cret")
        #expect(host.store.settings(for: id)["token"] == "s3cret")
        host.store.settings.flush()
        #expect(!configText.contains("s3cret"))
        host.store.drainSecrets()
        // Another store reads it off the main thread, and says when it has.
        let other = store()
        if other.settings(for: id)["token"] != "s3cret" {
            await withCheckedContinuation { continuation in other.onSecureSettings = { _ in continuation.resume() } }
        }
        #expect(other.settings(for: id)["token"] == "s3cret")
        host.send(.command(id: "peek"), to: id)
        try await settle()
        #expect(recorder.toasts.contains { $0.hasPrefix("error: secrets named dock2.setting.") })
    }

    @Test func aURLOpensOnlyInAnswerToSomethingTheUserDid() async throws {
        let recorder = Recorder()
        let host = host(recorder)
        host.send(.query(id: 1, text: "open"), to: id)
        try await settle()
        #expect(recorder.toasts.contains("error: a URL opens only in answer to something the user did"))
    }

    /// `dock2 plugin install` and `remove` are another process's store on the same files; the running
    /// dock2 hears the plugin's id and reads them again.
    @Test func whatTheCommandLineInstallsAndRemovesReachesARunningDock2() throws {
        let running = PluginHost(store: store(firstParty: false), nowPlaying: NowPlaying(helpers: nil))
        var changes = 0
        running.store.onChange = { changes += 1 }
        let commandLine = store(firstParty: false)

        try commandLine.install(TestGuest.folder)
        running.changedElsewhere(id)
        #expect(running.store.plugins.map { $0.id } == [id] && running.store.isEnabled(id) && running.store.resultsOn(id))
        #expect(changes == 1)

        try commandLine.remove(id)
        running.changedElsewhere(id)
        #expect(running.store.plugins.isEmpty && running.store.choices(id) == nil)
    }

    /// Installing again — an update, or `dock2 plugin dev` after a rebuild — keeps what the user chose.
    @Test func anUpdateKeepsWhatTheUserChose() throws {
        let store = store(firstParty: false)
        try store.install(TestGuest.folder)
        store.update(id) { choices in
            choices.revoked.append(.network)
            choices.enabled = false
        }
        try store.install(TestGuest.folder)
        #expect(!store.isEnabled(id) && !store.grants(id, .network) && store.grants(id, .query))
        store.settings.flush()
        #expect(configText.hasSuffix("[plugins.\"zip.tanner.dock2.test-guest\"]\nenabled = false\nrevoked = [\"network\"]\n"))
    }

    /// A second store's install — `dock2 plugin dev`'s — keeps what the running dock2 changed meanwhile.
    @Test func anInstallElsewhereKeepsWhatChangedHere() throws {
        let commandLine = store(firstParty: false)
        try commandLine.install(TestGuest.folder)
        let running = store(firstParty: false)
        running.update(id) { $0.enabled = false }
        running.settings.flush()
        try commandLine.install(TestGuest.folder)
        commandLine.settings.flush()
        #expect(store(firstParty: false).isEnabled(id) == false)
    }

    /// The choices outlive the code: a copy still installed on another Mac must not fall back to its defaults,
    /// which grant everything it declares.
    @Test func removingAPluginKeepsItsChoices() throws {
        let store = store(firstParty: false)
        try store.install(TestGuest.folder)
        store.update(id) { $0.revoked.append(.network) }
        try store.remove(id)
        store.settings.flush()
        #expect(configText.contains("revoked = [\"network\"]"))
        try store.install(TestGuest.folder)
        #expect(!store.grants(id, .network))
    }

    /// Another Mac's plugin, not installed here: its table is carried, untouched, through every write.
    @Test func aTableForAPluginNotInstalledHereSurvives() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "[plugins.\"com.example.elsewhere\"]\nenabled = false # not on this Mac\n".write(to: config.url, atomically: true, encoding: .utf8)
        let store = store()
        store.update(id) { $0.enabled = true }
        store.settings.flush()
        #expect(configText.hasPrefix("[plugins.\"com.example.elsewhere\"]\nenabled = false # not on this Mac\n"))
        #expect(store.diagnostics.isEmpty)
    }

    @Test func aSecureSettingWrittenInTheFileMovesToTheSecrets() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "[plugins.\"zip.tanner.dock2.test-guest\".settings]\ntoken = \"in-the-clear\"\n".write(to: config.url, atomically: true, encoding: .utf8)
        let store = store()
        store.drainSecrets()
        store.settings.flush()
        #expect(!configText.contains("in-the-clear"))
        #expect(PluginSecrets(plugin: id, directory: store.dataDirectory.appendingPathComponent(id)).get(PluginStore.secureKey("token")) == "in-the-clear")
    }

    /// Failing stops a plugin for the run; it never writes `enabled = false` over the person's choice.
    @Test func aFailingPluginIsSuspendedNotSwitchedOff() throws {
        let host = host(Recorder())
        host.store.settings.flush()
        let before = configText
        host.store.suspend(id, because: "it failed 5 times in a minute")
        #expect(!host.store.isEnabled(id) && host.store.choices(id)?.enabled == true)
        host.store.settings.flush()
        #expect(configText == before)
        host.resume(id)
        #expect(host.store.isEnabled(id))
    }

    /// `plugins.json` is carried in once, for a plugin the file says nothing about; what dock2 switched off
    /// for failing comes back on, since that was dock2's doing.
    @Test func pluginsJSONIsCarriedInOnce() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = #"{"zip.tanner.dock2.test-guest": {"enabled": false, "granted": ["query", "secrets"], "declared": ["query", "network", "secrets"], "#
            + #""disabledBecause": "It failed 5 times in a minute", "tiles": {}, "settings": {"token": "kept-secret"}}}"#
        try legacy.write(to: directory.appendingPathComponent("plugins.json"), atomically: true, encoding: .utf8)
        let store = store()
        #expect(store.isEnabled(id) && !store.grants(id, .network))
        store.settings.flush()
        #expect(configText.hasSuffix("[plugins.\"zip.tanner.dock2.test-guest\"]\nenabled = true\nrevoked = [\"network\"]\n"))
        // Once: taking the table out does not bring plugins.json back.
        try "".write(to: config.url, atomically: true, encoding: .utf8)
        #expect(!self.store().isEnabled(id))
    }

    /// A result's chord is under a view's rule: the field keeps ⌘C.
    @Test func aResultCannotTakeTheFieldsKeys() {
        let recorder = Recorder(), host = host(recorder)
        let result = PluginResult(id: "r", title: "Hunter", actions: [ActionNode(id: "copy", title: "Copy", key: "cmd+c"),
                                                                     ActionNode(id: "open", title: "Open", key: "cmd+shift+o")])
        host.perform([.results(query: 1, items: [result])], from: id, answering: .query(id: 1, text: "h"))
        #expect(recorder.results.first?.1.first?.actions?.map(\.key) == [nil, "cmd+shift+o"])
    }

    /// What an update declares anew is granted with it; what the user revoked is not given back.
    @Test func anUpdatesNewCapabilityIsGrantedARevokedOneIsNot() throws {
        let manifest = try PluginStore.manifest(in: TestGuest.folder)
        let choices = PluginChoices(enabled: true, revoked: [.network])
        #expect(!choices.grants(.network, in: manifest) && choices.grants(.query, in: manifest) && choices.grants(.secrets, in: manifest))
    }

    @Test func aPluginCannotBeInstalledOverOneThatComesWithDock2() {
        let recorder = Recorder(), host = host(recorder)
        #expect(throws: PluginManifest.Problem.comesWithDock2("Test Guest")) { try host.store.install(TestGuest.folder) }
    }
}

/// A plugin's choices ⇄ its table in the config file, against a manifest with every kind of choice.
@Suite struct PluginChoicesTests {
    static let plugin: InstalledPlugin = {
        let manifest = #"""
        {"id": "com.example.weather", "name": "Weather", "version": "1.0.0", "api": 1, "module": "plugin.wasm",
         "capabilities": ["query", "network"], "results": {"title": "Weather"},
         "tiles": [{"id": "now", "title": "Now"}, {"id": "week", "title": "Week", "onDock": false}],
         "settings": [{"id": "city", "title": "City", "kind": "text", "default": "Oslo"},
                      {"id": "days", "title": "Days", "kind": "number", "default": "3"},
                      {"id": "metric", "title": "Metric", "kind": "toggle", "default": "true"},
                      {"id": "key", "title": "Key", "kind": "secure"}]}
        """#
        return InstalledPlugin(folder: URL(fileURLWithPath: "/tmp"), manifest: try! JSONDecoder().decode(PluginManifest.self, from: Data(manifest.utf8)),
                               isFirstParty: false)
    }()

    static func read(_ text: String) throws -> (PluginChoices, [SettingsDiagnostic]) {
        PluginChoices.read(try TOMLTable.parse(text).table(at: PluginChoices.path(plugin.id)), for: plugin)
    }

    /// Installed, with results off by default: on, `query` revoked — what the person was asked about.
    @Test func nothingWrittenIsTheManifestsDefaults() throws {
        let (choices, problems) = try Self.read("")
        #expect(choices == PluginChoices(enabled: true, revoked: [.query]))
        #expect(problems.isEmpty)
    }

    @Test func everyKeyReadsAsWritten() throws {
        let (choices, problems) = try Self.read("""
        [plugins."com.example.weather"]
        enabled = false
        revoked = []
        results = true
        tiles.week = true

        [plugins."com.example.weather".settings]
        city = "Bergen"
        days = 7
        metric = false
        """)
        #expect(choices == PluginChoices(enabled: false, revoked: [], results: true, tiles: ["week": true],
                                         settings: ["city": "Bergen", "days": "7", "metric": "false"]))
        #expect(problems.isEmpty)
    }

    @Test func aWrongValueIsADiagnosticAndAnUnknownKeyIsSaid() throws {
        let (choices, problems) = try Self.read("""
        [plugins."com.example.weather"]
        enabled = "yes"
        revoked = ["telepathy"]
        colour = "blue"
        """)
        #expect(choices.enabled)
        #expect(problems.map(\.description) == [
            "line 2: 'plugins.\"com.example.weather\".enabled' must be true or false, not a string",
            "line 3: 'plugins.\"com.example.weather\".revoked' names an unknown capability \"telepathy\"",
            "line 4: Weather has no setting 'plugins.\"com.example.weather\".colour'",
        ])
    }

    /// Only what changed is written, and what is back to the manifest's default is taken out.
    @Test func editsWriteWhatChangedAndUnwriteWhatIsDefault() throws {
        let defaults = PluginChoices.defaults(Self.plugin)
        var changed = defaults
        changed.enabled = false
        changed.tiles["now"] = false
        changed.settings["days"] = "7"
        changed.settings["metric"] = "true"
        let base = Settings.pluginsTable + [Self.plugin.id]
        #expect(changed.edits(from: defaults, for: Self.plugin) == [
            SettingsEdit(base + ["enabled"], .bool(false)),
            SettingsEdit(base + ["tiles", "now"], .bool(false)),
            SettingsEdit(base + ["settings", "days"], .number(7)),
        ])
        #expect(defaults.edits(from: changed, for: Self.plugin) == [
            SettingsEdit(base + ["enabled"], nil), SettingsEdit(base + ["tiles", "now"], nil), SettingsEdit(base + ["settings", "days"], nil),
        ])
    }
}

/// The native derivations, against Python's hashlib (`Plugins/bitwarden/vectors/make.py`).
@Suite struct DerivationTests {
    @Test func pbkdf2MatchesAnIndependentImplementation() throws {
        let vectors = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Plugins/bitwarden/vectors")
        let expected = try String(contentsOf: vectors.appendingPathComponent("master_key.hex"), encoding: .utf8)
        let key = PluginEngine.derive(Derivation(request: "r", function: .pbkdf2, password: "correct horse",
                                                 salt: Data("someone@example.com".utf8), iterations: 5000))
        #expect(key?.map { String(format: "%02x", $0) }.joined() == expected.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func argon2RunsAndUnreasonableParametersAreRefused() {
        let derivation = Derivation(request: "r", function: .argon2id, password: "pw", salt: Data(repeating: 1, count: 32),
                                    iterations: 3, memory: 64 * 1024, parallelism: 4)
        #expect(derivation.isReasonable && PluginEngine.derive(derivation)?.count == 32)
        #expect(!Derivation(request: "r", function: .pbkdf2, password: "", salt: Data(), iterations: 50_000_000).isReasonable)
        #expect(!Derivation(request: "r", function: .argon2id, password: "", salt: Data(), iterations: 3, memory: 4 << 20, parallelism: 4).isReasonable)
    }
}

@Suite struct PluginOrderTests {
    @Test func theUsersOrderFirstThenAsInstalled() throws {
        let manifest = try PluginStore.manifest(in: TestGuest.folder)
        func plugin(_ id: String) -> InstalledPlugin {
            var renamed = manifest
            renamed.id = id
            return InstalledPlugin(folder: TestGuest.folder, manifest: renamed, isFirstParty: false)
        }
        let installed = ["a.b.one", "a.b.two", "a.b.three"].map(plugin)
        #expect(installed.ordered(by: ["a.b.three"]).map(\.id) == ["a.b.three", "a.b.one", "a.b.two"])
        #expect(installed.ordered(by: []).map(\.id) == ["a.b.one", "a.b.two", "a.b.three"])
    }
}
