import Dock2Core
import Foundation
import Testing

/// The manifest's capabilities: each by name with what it reaches and why, validated, compared, said.
@Suite struct PluginCapabilityTests {
    static func manifest(_ capabilities: String, settings: String = "[]") throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data("""
        {"id": "com.example.notes", "name": "Notes", "version": "1.0.0", "api": 1, "module": "plugin.wasm",
         "capabilities": \(capabilities), "settings": \(settings)}
        """.utf8))
    }

    static let folders = #"[{"id": "notes", "title": "Notes", "kind": "folder"}, {"id": "server", "title": "Server", "kind": "text"}]"#

    @Test func everyScopeDecodes() throws {
        let manifest = try Self.manifest("""
        {"network": {"hosts": ["api.example.com", "$server"], "reason": "Syncs."},
         "local-network": {"hosts": ["localhost:11434"], "sockets": ["/var/run/docker.sock"], "reason": "Talks to Ollama."},
         "files": {"folders": ["$notes"], "write": true, "reason": "Edits notes."},
         "apps": {"schemes": ["zed"], "apps": ["dev.zed.Zed"], "reason": "Opens notes."},
         "xpc": {"services": [{"name": "com.example.agent", "team": "ABCDE12345"}], "reason": "Asks the agent."},
         "run": {"commands": [{"id": "status", "program": "/usr/bin/git", "args": ["-C", "{folder}", "status", "--porcelain"]},
                              {"id": "shell", "program": "/bin/zsh", "args": "*"}], "reason": "Runs git."},
         "query": {"reason": "Answers search."}}
        """, settings: Self.folders)
        try manifest.validate()
        #expect(manifest.capabilities.declared == [.network, .localNetwork, .query, .files, .apps, .xpc, .run])
        let status = try #require(manifest.capabilities.run?.command("status"))
        #expect(status.arguments == [.fixed("-C"), .slot(.folder), .fixed("status"), .fixed("--porcelain")])
        #expect(manifest.capabilities.run?.command("shell")?.arguments == nil && manifest.capabilities.runsAnything)
        // Written back as read.
        let again = try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(manifest))
        #expect(again == manifest)
    }

    /// The list form is refused rather than carried, and so is a name this dock2 does not know.
    @Test func theListFormAndUnknownNamesAreRefused() throws {
        #expect(throws: PluginManifest.Problem.capabilitiesAsList) { try Self.manifest(#"["network"]"#) }
        #expect(throws: PluginManifest.Problem.unknownCapability("telepathy")) { try Self.manifest(#"{"telepathy": {"reason": "x"}}"#) }
    }

    @Test func aCapabilityWithoutItsReasonRefusesTheInstall() throws {
        #expect(throws: PluginManifest.Problem.noReason(.query)) { try Self.manifest(#"{"query": {}}"#).validate() }
        #expect(throws: PluginManifest.Problem.noReason(.secrets)) { try Self.manifest(#"{"secrets": {"reason": "  "}}"#).validate() }
    }

    /// What each scope may not name.
    @Test func eachScopeNamesOnlyWhatItCanReach() throws {
        let refused: [(String, PluginCapability)] = [
            (#"{"network": {"hosts": [], "reason": "r"}}"#, .network),
            (#"{"network": {"hosts": ["https://api.example.com"], "reason": "r"}}"#, .network),
            (#"{"network": {"hosts": ["$notes"], "reason": "r"}}"#, .network),
            (#"{"local-network": {"hosts": ["example.com:80"], "reason": "r"}}"#, .localNetwork),
            (#"{"local-network": {"hosts": ["localhost"], "reason": "r"}}"#, .localNetwork),
            (#"{"local-network": {"sockets": ["docker.sock"], "reason": "r"}}"#, .localNetwork),
            (#"{"local-network": {"reason": "r"}}"#, .localNetwork),
            (#"{"files": {"folders": ["$server"], "reason": "r"}}"#, .files),
            (#"{"files": {"folders": ["/Users"], "reason": "r"}}"#, .files),
            (#"{"apps": {"schemes": ["https"], "reason": "r"}}"#, .apps),
            (#"{"apps": {"apps": ["com.apple.Terminal"], "reason": "r"}}"#, .apps),
            (#"{"xpc": {"services": [{"name": "com.apple.securityd", "team": "ABCDE12345"}], "reason": "r"}}"#, .xpc),
            (#"{"xpc": {"services": [{"name": "com.example.agent", "team": "abc"}], "reason": "r"}}"#, .xpc),
            (#"{"run": {"commands": [{"id": "a", "program": "git"}], "reason": "r"}}"#, .run),
            (#"{"run": {"commands": [{"id": "a", "program": "/usr/bin/../bin/git"}], "reason": "r"}}"#, .run),
            (#"{"run": {"commands": [{"id": "a", "program": "/bin/ls", "args": ["{file}"]}], "reason": "r"}}"#, .run),
            (#"{"run": {"commands": [{"id": "a", "program": "/bin/ls", "args": ["{text}", "{text}"]}], "reason": "r"}}"#, .run),
            (#"{"run": {"commands": [{"id": "a", "program": "/bin/ls", "args": ["x"], "team": "nope"}], "reason": "r"}}"#, .run),
        ]
        for (json, capability) in refused {
            #expect(throws: (any Error).self, "\(json)") { try Self.manifest(json, settings: Self.folders).validate() }
            do { try Self.manifest(json, settings: Self.folders).validate() } catch PluginManifest.Problem.scope(let named, _) {
                #expect(named == capability, "\(json)")
            } catch {}
        }
        // A path slot needs a folder setting to lie inside.
        #expect(throws: (any Error).self) {
            try Self.manifest(#"{"run": {"commands": [{"id": "a", "program": "/bin/ls", "args": ["{path}"]}], "reason": "r"}}"#).validate()
        }
        #expect(throws: PluginManifest.Problem.duplicate("a")) {
            try Self.manifest(#"{"run": {"commands": [{"id": "a", "program": "/bin/ls"}, {"id": "a", "program": "/bin/cat"}], "reason": "r"}}"#).validate()
        }
    }

    /// An update asks again for what it reaches beyond what was agreed: never for less, or for a reason reworded.
    @Test func theReachSaysWhatIsNew() throws {
        let agreed = try Self.manifest("""
        {"network": {"hosts": ["api.example.com"], "reason": "Syncs."}, "files": {"folders": ["$notes"], "reason": "Reads."},
         "run": {"commands": [{"id": "status", "program": "/usr/bin/git", "args": ["status"]}], "reason": "Runs git."}}
        """, settings: Self.folders).reach
        func beyond(_ json: String) throws -> [PluginCapability] { try Self.manifest(json, settings: Self.folders).reach.beyond(agreed) }
        #expect(try beyond(#"{"network": {"hosts": ["API.example.com"], "reason": "Reworded."}}"#) == [])
        #expect(try beyond(#"{"network": {"hosts": ["api.example.com", "cdn.example.com"], "reason": "r"}}"#) == [.network])
        #expect(try beyond(#"{"network": {"hosts": ["*"], "reason": "r"}}"#) == [.network])
        #expect(try beyond(#"{"files": {"folders": ["$notes"], "write": true, "reason": "r"}}"#) == [.files])
        #expect(try beyond(#"{"run": {"commands": [{"id": "renamed", "program": "/usr/bin/git", "args": ["status"]}], "reason": "r"}}"#) == [])
        #expect(try beyond(#"{"run": {"commands": [{"id": "status", "program": "/usr/bin/git", "args": ["status", "-u"]}], "reason": "r"}}"#) == [.run])
        #expect(try beyond(#"{"query": {"reason": "r"}, "secrets": {"reason": "r"}}"#) == [.query, .secrets])
        #expect(try Self.manifest(#"{"query": {"reason": "r"}}"#).reach.beyond(nil) == [.query])
        // The reach agreed to is kept, so it reads back.
        #expect(try JSONDecoder().decode(PluginManifest.Reach.self, from: JSONEncoder().encode(agreed)) == agreed)
    }

    /// dock2's lines say what it enforces: the hosts, folders, services and commands by name.
    @Test func linesSayWhatItReaches() throws {
        let manifest = try Self.manifest("""
        {"local-network": {"hosts": ["localhost:11434"], "sockets": ["/var/run/docker.sock"], "reason": "r"},
         "files": {"folders": ["$notes"], "write": true, "reason": "r"},
         "apps": {"schemes": ["zed", "obsidian"], "apps": ["dev.zed.Zed"], "reason": "r"},
         "xpc": {"services": [{"name": "com.example.agent", "team": "ABCDE12345"}], "reason": "r"},
         "run": {"commands": [{"id": "list", "program": "/bin/ls", "args": ["-la", "{text}"], "team": "ABCDE12345"},
                              {"id": "make", "program": "/usr/bin/make", "args": ["-C", "{folder}"]},
                              {"id": "shell", "program": "/bin/zsh", "args": "*"}], "reason": "r"}}
        """, settings: Self.folders)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(manifest.lines(.localNetwork, settings: [:]) == ["Connects to localhost:11434", "Connects to the socket /var/run/docker.sock"])
        #expect(manifest.lines(.files, settings: [:]) == ["Reads and writes files in the folder you pick for Notes"])
        #expect(manifest.lines(.files, settings: ["notes": home + "/Notes"]) == ["Reads and writes files in ~/Notes"])
        #expect(manifest.lines(.apps, settings: [:], appName: { $0 == "dev.zed.Zed" ? "Zed" : nil }) == ["Opens zed: and obsidian: links", "Opens files in Zed"])
        #expect(manifest.lines(.xpc, settings: [:]) == ["Talks to com.example.agent, signed by ABCDE12345"])
        #expect(manifest.lines(.run, settings: [:]) == [
            "Runs /bin/ls -la ‹text›, signed by ABCDE12345",
            // A folder it may write is one the program may run what the plugin put there.
            "Runs /usr/bin/make -C ‹folder› — it can do anything you can",
            "Runs /bin/zsh with any arguments — it can do anything you can",
        ])
    }

    /// A `$setting`'s default is part of what it reaches: changed, an update asks again. A folder has none, since
    /// the user picks it, and a setting's value that is not a host name reaches no host.
    @Test func aSettingsDefaultIsPartOfTheReach() throws {
        let server = #"[{"id": "server", "title": "Server", "kind": "text", "default": "https://vault.example.org"}]"#
        let moved = #"[{"id": "server", "title": "Server", "kind": "text", "default": "https://elsewhere.net"}]"#
        let network = #"{"network": {"hosts": ["$server"], "reason": "r"}}"#
        #expect(try Self.manifest(network, settings: moved).reach.beyond(Self.manifest(network, settings: server).reach) == [.network])
        #expect(try Self.manifest(network, settings: server).reach.beyond(Self.manifest(network, settings: server).reach) == [])
        #expect(throws: PluginManifest.Problem.folderDefault("notes")) {
            try Self.manifest(#"{"files": {"folders": ["$notes"], "reason": "r"}}"#,
                              settings: #"[{"id": "notes", "title": "Notes", "kind": "folder", "default": "/"}]"#).validate()
        }
        let star = try Self.manifest(network, settings: #"[{"id": "server", "title": "Server", "kind": "text", "default": "*"}]"#)
        #expect(star.allowedHosts(settings: ["server": "*"]).isEmpty && star.allowedHosts(settings: ["server": "https://a.example/"]) == ["a.example"])
        #expect(star.lines(.network, settings: ["server": "*"]) == ["Connects to the server you set in Server"])
    }

    @Test func aCommandWithAnyArgumentsIsTheEscape() throws {
        let manifest = try Self.manifest(#"{"run": {"commands": [{"id": "shell", "program": "/bin/zsh", "args": "*"}], "reason": "r"}}"#)
        #expect(manifest.capabilities.runsAnything)
        #expect(try !Self.manifest(#"{"run": {"commands": [{"id": "ls", "program": "/bin/ls"}], "reason": "r"}}"#).capabilities.runsAnything)
    }
}
