@testable import Dock2System
import Dock2Core
import Dock2TOML
import Foundation
import Testing

/// A folder of its own for one test's config file, last-good copy, lock and state.
struct ScratchSettings {
    let folder: URL
    let file: SettingsFile

    init(config: URL? = nil) {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-settings-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = SettingsFile(url: config ?? folder.appendingPathComponent("config.toml"), lastGood: folder.appendingPathComponent("last-good.toml"),
                            lock: folder.appendingPathComponent("config.lock"), state: folder.appendingPathComponent("state.json"))
    }

    var text: String? { try? String(contentsOf: file.url, encoding: .utf8) }

    /// Writes the file as an editor would: a new file renamed over the old.
    func edit(_ text: String) throws {
        let temporary = folder.appendingPathComponent("editing-\(UUID().uuidString)")
        try text.write(to: temporary, atomically: false, encoding: .utf8)
        _ = rename(temporary.path, file.target.path)
    }
}

@MainActor
@Suite struct SettingsStoreTests {
    @Test func aMissingFileIsEveryDefaultAndIsNotCreatedForNothing() {
        let scratch = ScratchSettings()
        let settings = SettingsStore(file: scratch.file, watch: false)
        #expect(settings[Settings.tileSize] == 48)
        settings.flush()
        #expect(scratch.text == nil)
    }

    @Test func aChangeIsWrittenAndADefaultTakesItsLineAway() {
        let scratch = ScratchSettings()
        let settings = SettingsStore(file: scratch.file, watch: false)
        settings[Settings.autohide] = true
        #expect(settings[Settings.autohide])
        settings.flush()
        #expect(scratch.text == Settings.starter + "\n[dock]\nautohide = true\n")
        settings[Settings.autohide] = false
        settings.flush()
        #expect(scratch.text == Settings.starter + "\n[dock]\n")
    }

    @Test func commentsAndOrderSurviveAWrite() throws {
        let scratch = ScratchSettings()
        let text = "# mine\n[files]\nshow-hidden = true   # always\n\n[dock]\n# bigger\ntile-size = 56\nautohide = true\n"
        try scratch.edit(text)
        let settings = SettingsStore(file: scratch.file, watch: false)
        settings[Settings.tileSize] = 64
        settings.flush()
        #expect(scratch.text == text.replacingOccurrences(of: "tile-size = 56", with: "tile-size = 64"))
    }

    @Test func aHandEditIsHeardOnceAndDock2sOwnWriteNotAgain() async throws {
        let scratch = ScratchSettings()
        let settings = SettingsStore(file: scratch.file, watch: false)
        var heard: [Double] = []
        let token = settings.observe(Settings.tileSize) { heard.append($0) }
        try scratch.edit("[dock]\ntile-size = 60\n")
        settings.reload()
        settings.reload()
        try await Task.sleep(for: .milliseconds(50))
        settings[Settings.tileSize] = 70
        settings.flush()
        settings.reload()
        try await Task.sleep(for: .milliseconds(50))
        #expect(heard == [60, 70])
        withExtendedLifetime(token) {}
    }

    /// Edits not yet written land on top of whatever the file became meanwhile — an editor's, another Mac's.
    @Test func editsNotYetWrittenAreAppliedOverAHandEdit() throws {
        let scratch = ScratchSettings()
        let settings = SettingsStore(file: scratch.file, watch: false)
        settings[Settings.tileSize] = 64
        try scratch.edit("# by hand\n[files]\nshow-hidden = true\n")
        settings.flush()
        #expect(scratch.text == "# by hand\n[files]\nshow-hidden = true\n\n[dock]\ntile-size = 64\n")
        #expect(settings[Settings.showHiddenFiles])
        #expect(settings[Settings.tileSize] == 64)
    }

    /// Two processes — dock2 and `dock2 config` — each keep the other's edit.
    @Test func twoWritersKeepEachOthersEdits() {
        let scratch = ScratchSettings()
        let one = SettingsStore(file: scratch.file, watch: false)
        let other = SettingsStore(file: scratch.file, watch: false)
        one[Settings.autohide] = true
        other[Settings.tileSize] = 64
        one.flush()
        other.flush()
        #expect(scratch.text == Settings.starter + "\n[dock]\nautohide = true\ntile-size = 64\n")
    }

    /// An atomic write at a link would replace the link, and the dotfiles copy would never hear of it.
    @Test func aWriteGoesThroughALink() throws {
        let dotfiles = ScratchSettings()
        try "[dock]\nautohide = true\n".write(to: dotfiles.file.url, atomically: true, encoding: .utf8)
        let linked = ScratchSettings(config: FileManager.default.temporaryDirectory.appendingPathComponent("dock2-link-\(UUID().uuidString).toml"))
        try FileManager.default.createSymbolicLink(at: linked.file.url, withDestinationURL: dotfiles.file.url)
        let settings = SettingsStore(file: linked.file, watch: false)
        #expect(settings[Settings.autohide])
        settings[Settings.tileSize] = 64
        settings.flush()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linked.file.url.path) == dotfiles.file.url.path)
        #expect(dotfiles.text == "[dock]\nautohide = true\ntile-size = 64\n")
    }

    @Test func aFileThatCantBeReadAtLaunchRunsOnTheLastThatCouldAndRefusesWrites() throws {
        let scratch = ScratchSettings()
        try scratch.edit("[dock]\ntile-size = 64\n")
        _ = SettingsStore(file: scratch.file, watch: false)
        try scratch.edit("[dock]\ntile-size = 64\nautohide = \n")
        let settings = SettingsStore(file: scratch.file, watch: false)
        #expect(settings.unreadable?.description == "line 3: missing value after '='")
        #expect(settings[Settings.tileSize] == 64)
        var refused: [SettingsDiagnostic] = []
        settings.onRefused = { refused.append($0) }
        settings[Settings.autohide] = true
        settings.flush()
        #expect(refused.count == 1)
        #expect(!settings[Settings.autohide])
        #expect(scratch.text == "[dock]\ntile-size = 64\nautohide = \n")
    }

    @Test func aFileBrokenOnReloadChangesNothingUntilItIsFixed() throws {
        let scratch = ScratchSettings()
        try scratch.edit("[dock]\ntile-size = 64\n")
        let settings = SettingsStore(file: scratch.file, watch: false)
        var heard: [SettingsDiagnostic] = []
        settings.onUnreadable = { heard.append($0) }
        try scratch.edit("[dock\ntile-size = 20\n")
        settings.reload()
        #expect(settings.unreadable != nil)
        #expect(heard.count == 1)
        #expect(settings[Settings.tileSize] == 64)
        try scratch.edit("[dock]\ntile-size = 20\n")
        settings.reload()
        #expect(settings.unreadable == nil)
        #expect(settings[Settings.tileSize] == 20)
    }

    /// A key from a newer dock2 is reported and kept: an older one writing the file leaves it alone.
    @Test func anUnknownKeyIsReportedAndSurvivesAWrite() throws {
        let scratch = ScratchSettings()
        try scratch.edit("[dock]\nmagnify-on-hover = true\n")
        let settings = SettingsStore(file: scratch.file, watch: false)
        #expect(settings.diagnostics.map(\.description) == ["line 2: unknown setting 'dock.magnify-on-hover'"])
        settings[Settings.autohide] = true
        settings.flush()
        #expect(scratch.text == "[dock]\nmagnify-on-hover = true\nautohide = true\n")
    }

    @Test func thisMacsSettingsStayOutOfTheFile() throws {
        let scratch = ScratchSettings()
        let settings = SettingsStore(file: scratch.file, watch: false)
        settings[Settings.fileAccess] = .folders
        settings.flush()
        #expect(scratch.text == nil)
        #expect(scratch.file.machine.load() == ["fileAccess": "folders"])
        #expect(SettingsStore(file: scratch.file, watch: false)[Settings.fileAccess] == .folders)
    }

    @Test func theFileIsWatched() async throws {
        let scratch = ScratchSettings()
        try scratch.edit("[dock]\ntile-size = 56\n")
        let settings = SettingsStore(file: scratch.file, watch: true)
        try scratch.edit("[dock]\ntile-size = 60\n")
        try await Task.sleep(for: .milliseconds(400))
        #expect(settings[Settings.tileSize] == 60)
        try "[dock]\ntile-size = 62\n".write(to: scratch.file.url, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(400))
        #expect(settings[Settings.tileSize] == 62)
    }
}

@MainActor
@Suite struct SettingsImportTests {
    private func domain() -> UserDefaults {
        UserDefaults(suiteName: "zip.tanner.dock2.tests.\(UUID().uuidString)")!
    }

    @Test func theDomainIsCarriedIntoTheFileOnceWritingOnlyWhatDiffers() throws {
        let scratch = ScratchSettings()
        let defaults = domain()
        defaults.set(true, forKey: "onboarded")
        defaults.set(64.0, forKey: "tileSize")
        defaults.set(30, forKey: "clipboardRetentionDays")
        defaults.set([["bundleIdentifier": "com.apple.Safari", "path": "/Applications/Safari.app"]], forKey: "pinnedApps")
        defaults.set(["chord": ["_0": ["keyCode": 9, "modifiers": 8448]]], forKey: "clipboardShortcut")
        defaults.set(["picture": "dog", "color": ["red": 0.0, "green": 0.0, "blue": 0.0]], forKey: "finderIcon")
        defaults.set("folders", forKey: "fileAccess")
        defaults.set(true, forKey: "magnification")
        SettingsImport.run(into: scratch.file, from: defaults, openAtLogin: true)
        #expect(scratch.text == Settings.starter + """

        [general]
        onboarded = true
        open-at-login = true

        [dock]
        pinned = ["com.apple.Safari"]
        tile-size = 64

        [clipboard]
        shortcut = "ctrl-cmd-v"

        [files]
        icon = "dog"
        icon-color = "#000000"

        """)
        #expect(scratch.file.machine.load() == ["fileAccess": "folders"])
        #expect(SettingsStore(file: scratch.file, watch: false).diagnostics.isEmpty)

        defaults.set(96.0, forKey: "tileSize")
        SettingsImport.run(into: scratch.file, from: defaults)
        #expect(scratch.text?.contains("tile-size = 64") == true)
    }

    @Test func aFileAnotherMacWroteWins() throws {
        let scratch = ScratchSettings()
        try scratch.edit("[dock]\nautohide = true\n")
        let defaults = domain()
        defaults.set(64.0, forKey: "tileSize")
        #expect(SettingsImport.run(into: scratch.file, from: defaults).isEmpty)
        #expect(scratch.text == "[dock]\nautohide = true\n")
    }

    @Test func aValueOfTheWrongTypeIsNotCarried() {
        let scratch = ScratchSettings()
        let defaults = domain()
        defaults.set("big", forKey: "tileSize")
        defaults.set(true, forKey: "autohide")
        #expect(SettingsImport.run(into: scratch.file, from: defaults) == ["autohide"])
    }

    @Test func legacyValuesReadAsTheDefaultsStoreReadThem() {
        #expect(Bool(propertyList: true as NSNumber) == true)
        #expect(Bool(propertyList: 1 as NSNumber) == nil)
        #expect(Double(propertyList: 95 as NSNumber) == 95)
        #expect(Double(propertyList: true as NSNumber) == nil)
        #expect([String](propertyList: ["a", 1]) == nil)
        // ⌃⌘V stored with bit 13 for ⌃ reads back as ⌃⌘V.
        #expect(Shortcut(propertyList: ["chord": ["_0": ["keyCode": 9, "modifiers": 8448]]])
                == .chord(KeyChord(keyCode: 9, modifiers: KeyChord.command | KeyChord.control)))
        #expect(Shortcut(propertyList: ["commandSpace": [String: Any]()]) == .commandSpace)
        // An icon stored without the fill is filled; a picture no longer known is not an icon.
        #expect(FinderIcon(propertyList: ["picture": "dog", "color": ["red": 0.5, "green": 0.5, "blue": 0.5]])
                == FinderIcon(picture: .dog, color: IconColor(red: 0.5, green: 0.5, blue: 0.5), filled: true))
        #expect(FinderIcon(propertyList: ["picture": "teapot", "color": ["red": 0.0, "green": 0.0, "blue": 0.0]]) == nil)
    }
}
