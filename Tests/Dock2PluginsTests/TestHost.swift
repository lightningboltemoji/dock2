@testable import Dock2Plugins
import Dock2System
import Foundation

/// A host over the test guest, switched on, in a folder of its own: its config file, data and secrets.
@MainActor
enum TestHost {
    static let id = "zip.tanner.dock2.test-guest"

    static func make(_ recorder: Recorder, in directory: URL, settings: [String: String] = [:]) -> PluginHost {
        let file = SettingsFile(url: directory.appendingPathComponent("config.toml"), lastGood: nil, lock: directory.appendingPathComponent("config.lock"),
                                state: directory.appendingPathComponent("state.json"))
        let store = PluginStore(settings: SettingsStore(file: file, watch: false), firstParty: TestGuest.folder.deletingLastPathComponent(), directory: directory)
        store.update(id) { $0.enabled = true }
        for (key, value) in settings { store.setSetting(id, key, value) }
        let host = PluginHost(store: store, nowPlaying: NowPlaying(helpers: nil))
        host.delegate = recorder
        return host
    }

    /// Until `done` holds, or `seconds` pass: the instance's queue, then the main queue's effects, perhaps more.
    static func settle(until done: () -> Bool = { false }, seconds: Double = 0.2) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(20))
            if done() { return }
        }
    }
}
