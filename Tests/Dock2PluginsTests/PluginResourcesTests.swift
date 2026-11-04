@testable import Dock2Plugins
import Testing

@MainActor
@Suite struct PluginResourcesTests {
    let plugin = "com.example.weather"
    typealias Key = PluginResources.Key

    /// Holding again under a key ends what it held: a timer set again replaces the last.
    @Test func aKeyHoldsOneThing() {
        let resources = PluginResources()
        var ended: [String] = []
        resources.hold(Key(.timer, "tick"), of: plugin, under: nil) { ended.append("first") }
        resources.hold(Key(.timer, "tick"), of: plugin, under: nil) { ended.append("second") }
        #expect(ended == ["first"])
        #expect(resources.keys(.timer, of: plugin).count == 1)
    }

    /// Revoking ends only what the capability allowed; the rest stays held.
    @Test func revokingEndsWhatTheCapabilityAllowed() {
        let resources = PluginResources()
        var ended: [String] = []
        resources.hold(Key(.subscription, "nowPlaying"), of: plugin, under: .nowPlaying) { ended.append("subscription") }
        resources.hold(Key(.request, "sync"), of: plugin, under: .network) { ended.append("sync") }
        resources.hold(Key(.timer, "tick"), of: plugin, under: nil) { ended.append("tick") }
        resources.hold(Key(.request, "other"), of: "com.example.other", under: .nowPlaying) { ended.append("other") }
        #expect(resources.end(under: .nowPlaying, of: plugin) == [Key(.subscription, "nowPlaying")])
        #expect(ended == ["subscription"])
        #expect(resources.holds(Key(.request, "sync"), of: plugin) && resources.holds(Key(.request, "other"), of: "com.example.other"))
        resources.endAll(of: plugin)
        #expect(Set(ended) == ["subscription", "sync", "tick"] && resources.isIdle(plugin) && !resources.isIdle("com.example.other"))
    }

    /// What ended on its own is released without being ended; released after it was ended, it says so.
    @Test func aReleaseAfterAnEndIsNotTheirsAnyMore() {
        let resources = PluginResources()
        var ended = 0
        resources.hold(Key(.request, "r"), of: plugin, under: .network) { ended += 1 }
        #expect(resources.release(Key(.request, "r"), of: plugin) && ended == 0 && resources.isIdle(plugin))
        resources.hold(Key(.request, "r"), of: plugin, under: .network) { ended += 1 }
        resources.end(Key(.request, "r"), of: plugin)
        #expect(ended == 1 && !resources.release(Key(.request, "r"), of: plugin))
    }
}
