import Dock2Core
@testable import Dock2Plugins
import Foundation
import Testing

/// Against `Plugins/test-guest`, which `make plugins` builds into `.build/test-plugins`.
enum TestGuest {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/test-plugins/zip.tanner.dock2.test-guest.dock2plugin")

    static func plugin() throws -> InstalledPlugin {
        InstalledPlugin(folder: folder, manifest: try PluginStore.manifest(in: folder), isFirstParty: true)
    }
}

/// Collects what an instance answers, on the main actor.
@MainActor
final class Answers {
    var effects: [PluginEffect] = []
    var disabled: String?

    var toasts: [String] {
        effects.compactMap { if case .toast(let text) = $0 { text } else { nil } }
    }

    /// Lets the main queue run the instance's deliveries.
    func settle(_ instance: PluginInstance) async {
        instance.drain()
        await Task.yield()
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Suite(.serialized) struct PluginInstanceTests {
    let engine: PluginEngine
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-plugin-cache-\(UUID().uuidString)")

    init() throws {
        engine = try PluginEngine()
    }

    func instance(_ answers: Answers) throws -> PluginInstance {
        let instance = PluginInstance(plugin: try TestGuest.plugin(), engine: engine, cache: cache)
        instance.onEffects = { effects, _ in MainActor.assumeIsolated { answers.effects += effects } }
        instance.onDisabled = { reason in MainActor.assumeIsolated { answers.disabled = reason } }
        return instance
    }

    @Test func startsOnItsFirstEventAndAnswers() async throws {
        let answers = Answers()
        let guest = try instance(answers)
        guest.deliver(.command(id: "echo"), settings: ["a": "1", "b": "2"])
        guest.deliver(.command(id: "echo"), settings: [:])
        await answers.settle(guest)
        #expect(answers.toasts == ["started with 2 settings", "echo 2", "echo 3"])
        guest.deliver(.query(id: 4, text: "an"), settings: [:])
        guest.deliver(.command(id: "view"), settings: [:])
        await answers.settle(guest)
        #expect(answers.effects.contains(.results(query: 4, items: [PluginResult(id: "banana", title: "banana")])))
        guard case .showView(.list(let list)) = answers.effects.last else {
            Issue.record("no view")
            return
        }
        #expect(list.title == "Things" && list.sections.first?.items.map(\.title) == ["First", "Second"])
    }

    @Test func aCallPastItsBudgetIsStoppedAndTheNextStartsAfresh() async throws {
        let answers = Answers()
        let guest = try instance(answers)
        let start = Date()
        guest.deliver(.command(id: "spin"), settings: [:])
        guest.drain()
        let took = Date().timeIntervalSince(start)
        // Within the interactive budget's ticks, the start's compile aside.
        #expect(took < 2)
        guest.deliver(.command(id: "echo"), settings: [:])
        await answers.settle(guest)
        #expect(answers.toasts.last == "echo 2" && answers.disabled == nil)
    }

    @Test func runningOutOfMemoryOrTrappingIsSurvived() async throws {
        let answers = Answers()
        let guest = try instance(answers)
        guest.deliver(.command(id: "grow"), settings: [:])
        guest.deliver(.command(id: "echo"), settings: [:])
        guest.deliver(.command(id: "trap"), settings: [:])
        guest.deliver(.command(id: "echo"), settings: [:])
        await answers.settle(guest)
        #expect(answers.toasts.filter { $0.hasPrefix("echo") }.count == 2)
    }

    @Test func fiveFailuresInAMinuteSwitchItOff() async throws {
        let answers = Answers()
        let guest = try instance(answers)
        for _ in 0..<5 { guest.deliver(.command(id: "trap"), settings: [:]) }
        guest.deliver(.command(id: "echo"), settings: [:])
        await answers.settle(guest)
        #expect(answers.disabled?.contains("5 times") == true)
        #expect(!answers.toasts.contains { $0.hasPrefix("echo") })
    }

    @Test func theCompiledModuleIsCachedAndReadBack() async throws {
        let answers = Answers()
        let first = try instance(answers)
        first.deliver(.command(id: "echo"), settings: [:])
        await answers.settle(first)
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        #expect(files.count == 1 && files[0].hasSuffix(".cwasm"))
        let second = try instance(answers)
        second.deliver(.command(id: "time"), settings: [:])
        await answers.settle(second)
        #expect(answers.toasts.last == "true")
    }
}

/// Bitwarden's own module in the engine: a large vault — RSA for an organization's key, AES and HMAC for
/// every field — opened a slice an event, no event outrunning a background budget.
@MainActor
@Suite struct BitwardenBudgetTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func aLargeVaultOpensInSlicesEachWithinTheBudget() async throws {
        let folder = Self.root.appendingPathComponent(".build/plugins/zip.tanner.dock2.bitwarden.dock2plugin")
        let vectors = Self.root.appendingPathComponent("Plugins/bitwarden/vectors")
        func vector(_ name: String) throws -> String {
            try String(contentsOf: vectors.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let plugin = InstalledPlugin(folder: folder, manifest: try PluginStore.manifest(in: folder), isFirstParty: true)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-bw-\(UUID().uuidString)")
        let instance = PluginInstance(plugin: plugin, engine: try PluginEngine(), cache: cache)
        let answers = Answers()
        instance.onEffects = { effects, _ in MainActor.assumeIsolated { answers.effects += effects } }

        // Unlocked, from what the secrets hold: the user key the vectors' items are sealed with.
        let keyHex = try vector("key.hex")
        let keyBytes = Data(stride(from: 0, to: keyHex.count, by: 2).map {
            UInt8(keyHex[keyHex.index(keyHex.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
        })
        let unlocked = #"{"key":"\#(keyBytes.base64EncodedString())","until":\#(Int(Date().timeIntervalSince1970 * 1000) + 600_000)}"#
        for (request, value) in [("load-session", nil), ("load-key", unlocked), ("load-device", "d"), ("load-vault", nil)] as [(String, String?)] {
            instance.deliver(request.hasSuffix("session") || request.hasSuffix("key") ? .secret(request: request, key: "", value: value)
                                                                                      : .storage(request: request, key: "", value: value), settings: [:])
        }
        var ciphers: [[String: Any]] = []
        for index in 0..<3000 {
            ciphers.append(["id": "own\(index)", "name": try vector("sealed.txt"), "login": ["username": try vector("sealed.txt"), "password": try vector("sealed.txt")]])
        }
        ciphers.append(["id": "org", "name": try vector("org_item.txt"), "organizationId": "org"])
        let sync: [String: Any] = ["profile": ["privateKey": try vector("org_private.txt"), "organizations": [["id": "org", "key": try vector("org_key.txt")]]],
                                   "ciphers": ciphers]
        instance.drain()

        // The sync, then each slice the plugin asks for with its timer, timed one by one.
        var event = PluginEvent.http(request: "sync", status: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: sync), error: nil)
        var longest: TimeInterval = 0, slices = 0
        while true {
            answers.effects = []
            let start = Date()
            instance.deliver(event, settings: [:])
            instance.drain()
            longest = max(longest, Date().timeIntervalSince(start))
            await answers.settle(instance)
            guard answers.effects.contains(.timer(id: "open", ms: 100, repeats: false)) else { break }
            event = .timer(id: "open")
            slices += 1
        }
        print("bitwarden: 3,001 items with an organization in \(slices + 1) events, the longest \(Int(longest * 1000)) ms")
        #expect(longest < Double(PluginInstance.backgroundBudget) / 1000 * 0.8)
        #expect(slices > 1)
    }
}
