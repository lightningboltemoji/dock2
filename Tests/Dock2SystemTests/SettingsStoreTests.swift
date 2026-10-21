import Dock2Core
import Dock2System
import Foundation
import Testing

@MainActor
@Suite struct SettingsStoreTests {
    private func store() -> SettingsStore {
        let name = "zip.tanner.dock2.tests.\(UUID().uuidString)"
        return SettingsStore(defaults: UserDefaults(suiteName: name)!)
    }

    @Test func readsTheDefaultUntilWritten() {
        let settings = store()
        #expect(settings[Settings.tileSize] == 48)
        #expect(!settings.isSet(Settings.tileSize))
        settings[Settings.tileSize] = 95
        #expect(settings[Settings.tileSize] == 95)
        #expect(settings.isSet(Settings.tileSize))
        settings.reset(Settings.tileSize)
        #expect(settings[Settings.tileSize] == 48)
    }

    @Test func aValueOfTheWrongTypeReadsAsTheDefault() {
        let settings = store()
        settings.defaults.set("big", forKey: Settings.tileSize.name)
        #expect(settings[Settings.tileSize] == 48)
    }

    @Test func observersHearChangesOnce() async throws {
        let settings = store()
        var heard: [Bool] = []
        let token = settings.observe(Settings.autohide) { heard.append($0) }
        settings[Settings.autohide] = true
        settings[Settings.autohide] = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(heard == [true])
        withExtendedLifetime(token) {}
    }
}
