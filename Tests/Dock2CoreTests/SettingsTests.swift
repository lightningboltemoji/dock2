import Dock2Core
import Dock2TOML
import Foundation
import Testing

@Suite struct SettingsSchemaTests {
    static func read(_ text: String, previous: [String: any Sendable] = [:]) throws -> SettingsReading {
        Settings.read(try TOMLTable.parse(text), previous: previous)
    }

    /// The text `key` writes for `value`, as the one line of a fresh file.
    static func written<Value>(_ key: SettingKey<Value>, _ value: Value) throws -> String {
        var document = try TOMLDocument("")
        for edit in key.edits(for: value) { try document.apply(edit) }
        return document.rendered
    }

    @Test func anEmptyFileIsEveryDefault() throws {
        let reading = try Self.read("")
        #expect(reading[Settings.tileSize] == 48)
        #expect(reading[Settings.clipboardIgnored] == ClipboardPolicy.ignoredByDefault)
        #expect(reading[Settings.finderIcon] == FinderIcon())
        #expect(reading.diagnostics.isEmpty)
    }

    @Test func everyKindOfValueReadsBackWhatItWrites() throws {
        func roundTrip<Value>(_ key: SettingKey<Value>, _ value: Value, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let text = try Self.written(key, value)
            #expect(try Self.read(text)[key] == value, "\(text)", sourceLocation: sourceLocation)
        }
        try roundTrip(Settings.autohide, true)
        try roundTrip(Settings.tileSize, 64)
        try roundTrip(Settings.tileSize, 50.5)
        try roundTrip(Settings.clipboardRetentionDays, 7)
        try roundTrip(Settings.dockStyle, .snowLeopard)
        try roundTrip(Settings.fieldForm, .lavaLamp)
        try roundTrip(Settings.searchSourcesOff, ["Apps", "Files"])
        try roundTrip(Settings.searchExcluded, [NSHomeDirectory() + "/Library", "/Volumes/Backup"])
        try roundTrip(Settings.pinned, [AppRef(bundleIdentifier: "com.apple.Safari", path: ""), AppRef(bundleIdentifier: nil, path: "/Applications/Old.app")])
        try roundTrip(Settings.summon, .commandSpace)
        try roundTrip(Settings.summon, .chord(KeyChord(keyCode: KeyChord.space, modifiers: KeyChord.control | KeyChord.option)))
        try roundTrip(Settings.clipboardShortcut, .chord(KeyChord(keyCode: 9, modifiers: KeyChord.command | KeyChord.shift)))
        try roundTrip(Settings.clipboardShortcut, .none)
        try roundTrip(Settings.finderIcon, FinderIcon(picture: .palmTree, color: IconColor(red: 1, green: 0, blue: 0.2), filled: false))
    }

    @Test func valuesAreSpelledForAPersonToRead() throws {
        #expect(try Self.written(Settings.dockStyle, .snowLeopard) == "[dock]\nstyle = \"snow-leopard\"\n")
        #expect(try Self.written(Settings.tileSize, 64) == "[dock]\ntile-size = 64\n")
        #expect(try Self.written(Settings.summon, .commandSpace) == "[general]\nsummon = \"cmd-space\"\n")
        #expect(try Self.written(Settings.clipboardShortcut, .chord(KeyChord(keyCode: 9, modifiers: KeyChord.command | KeyChord.shift | KeyChord.control)))
                == "[clipboard]\nshortcut = \"ctrl-shift-cmd-v\"\n")
        #expect(try Self.written(Settings.searchFirst, [NSHomeDirectory() + "/Developer"]) == "[search]\nfirst-folders = [\"~/Developer\"]\n")
        #expect(try Self.written(Settings.pinned, [AppRef(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app")])
                == "[dock]\npinned = [\"com.apple.Safari\"]\n")
        #expect(try Self.written(Settings.finderIcon, FinderIcon(picture: .eyeOfHorus, color: .violet))
                == "[files]\nicon = \"eye-of-horus\"\n")
    }

    /// An absent key already means the default; writing one down would pin it.
    @Test func aDefaultIsWrittenAsNoLineAtAll() throws {
        #expect(try Self.written(Settings.tileSize, 48) == "")
        #expect(Settings.tileSize.edits(for: 48) == [SettingsEdit(["dock", "tile-size"], nil)])
        let icon = FinderIcon(picture: nil, color: IconColor(red: 0, green: 0, blue: 0), filled: true)
        #expect(Settings.finderIcon.edits(for: icon).map(\.value?.spelled) == [nil, "\"#000000\"", nil])
    }

    @Test func spotlightsChordIsTheTakeoverOnlyForSummoning() throws {
        #expect(try Self.read("[general]\nsummon = \"command-space\"\n")[Settings.summon] == .commandSpace)
        #expect(try Self.read("[clipboard]\nshortcut = \"cmd-space\"\n")[Settings.clipboardShortcut]
                == .chord(KeyChord(keyCode: KeyChord.space, modifiers: KeyChord.command)))
    }

    @Test func aChordIsSpelledAndReadAsEmiraDoes() throws {
        let chord = KeyChord(keyCode: 49, modifiers: KeyChord.command | KeyChord.option)
        #expect(chord.spelled == "alt-cmd-space")
        #expect(try KeyChord(spelling: "cmd-opt-space") == chord)
        #expect(try KeyChord(spelling: "space-alt-cmd") == chord)
        #expect(KeyChord(keyCode: 0x52, modifiers: KeyChord.command).spelled == nil)
        #expect(throws: SettingProblem("spells the '.' key as itself; it is 'period'")) { try KeyChord(spelling: "cmd-.") }
        #expect(throws: SettingProblem("names only modifiers; it needs a key too")) { try KeyChord(spelling: "cmd-shift") }
        #expect(throws: SettingProblem("names 'command' twice")) { try KeyChord(spelling: "cmd-command-k") }
        #expect(throws: SettingProblem("names an unknown key or modifier 'fn'")) { try KeyChord(spelling: "fn-f1") }
    }

    /// A key the file gets wrong reads as its default — or, on a reload, as it was — and says which line.
    @Test func aBadValueIsADiagnosticNotARefusal() throws {
        let text = "[dock]\ntile-size = 400\nautohide = true\nstyle = \"aqua\"\n"
        let reading = try Self.read(text)
        #expect(reading[Settings.autohide])
        #expect(reading[Settings.tileSize] == 48)
        #expect(reading.diagnostics.map(\.description) == [
            "line 2: 'dock.tile-size' must be from 16 to 128",
            "line 4: 'dock.style' must be one of \"glass\", \"snow-leopard\", not \"aqua\"",
        ])
        let reloaded = try Self.read(text, previous: [Settings.tileSize.name: 72.0])
        #expect(reloaded[Settings.tileSize] == 72)
    }

    @Test func refusalsReadAsSentences() throws {
        func diagnostic(_ text: String) throws -> String? { try Self.read(text).diagnostics.first?.description }
        #expect(try diagnostic("[dock]\nautohide = \"yes\"\n") == "line 2: 'dock.autohide' must be true or false, not a string")
        #expect(try diagnostic("[dock]\nreveal-delay = -1\n") == "line 2: 'dock.reveal-delay' must be at least 0")
        #expect(try diagnostic("[dock]\nreveal-delay = inf\n") == "line 2: 'dock.reveal-delay' must be a finite number")
        #expect(try diagnostic("[clipboard]\nretention-days = 1.5\n") == "line 2: 'clipboard.retention-days' must be a whole number")
        #expect(try diagnostic("[dock]\npinned = \"com.apple.Safari\"\n") == "line 2: 'dock.pinned' must be a list in brackets, not a string")
        #expect(try diagnostic("[files]\nicon-color = \"violet\"\n") == "line 2: 'files.icon-color' must be a colour like \"#6A5CD8\", not \"violet\"")
        #expect(try diagnostic("[general]\nsummon = \"cmd-alt-zz\"\n") == "line 2: 'general.summon' names an unknown key or modifier 'zz'")
    }

    /// A key a newer dock2 wrote, or a typo: said, never fatal, and the rest of the file still applies.
    @Test func anUnknownKeyIsADiagnostic() throws {
        let reading = try Self.read("[dock]\ntile-sise = 60\nautohide = true\n\n[dok]\n")
        #expect(reading[Settings.autohide])
        #expect(reading.diagnostics.map(\.description) == ["line 2: unknown setting 'dock.tile-sise'", "line 5: unknown setting 'dok'"])
    }

    @Test func pluginsAreAnOpenTableForTheirStoreToRead() throws {
        let reading = try Self.read("[plugins.\"zip.tanner.dock2.bitwarden\"]\nenabled = true\nanything = 1\n")
        #expect(reading.diagnostics.isEmpty)
        #expect(reading.plugins.value(at: ["zip.tanner.dock2.bitwarden", "enabled"])?.asBool == true)
    }

    @Test func machineSettingsNeverReachTheFile() throws {
        #expect(Settings.fileAccess.isMachine)
        #expect(Settings.fileAccess.edits(for: .folders).isEmpty)
        #expect(Settings.fileAccess.machineString(.folders) == "folders")
        #expect(Settings.askedToPaste.machineValue("true") == true)
        #expect(try Self.read("[files]\nfileAccess = \"folders\"\n").diagnostics.map(\.message) == ["unknown setting 'files.fileAccess'"])
    }

    @Test func everySettingHasItsOwnName() {
        let names = Settings.all.map(\.name)
        #expect(Set(names).count == names.count)
        let paths = Settings.all.flatMap(\.parts).map { TOMLDocument.spell($0.path) }
        #expect(Set(paths).count == paths.count)
    }

    /// `config.example.toml` is the schema written out: generated, so it cannot drift from the reader, and
    /// golden, so it cannot change without the diff being read. `DOCK2_UPDATE_GOLDEN=1` rewrites it.
    @Test func theExampleIsTheDefaultsAndMatchesItsGolden() throws {
        let example = Settings.example
        let reading = try Self.read(example)
        #expect(reading.diagnostics.isEmpty)
        for setting in Settings.all where !setting.isMachine {
            #expect(setting.isEqual(reading.values[setting.name]!, setting.defaultValue), "\(setting.name)")
        }
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("config.example.toml")
        if ProcessInfo.processInfo.environment["DOCK2_UPDATE_GOLDEN"] == "1" {
            try example.write(to: golden, atomically: true, encoding: .utf8)
        }
        #expect(try String(contentsOf: golden, encoding: .utf8) == example, "config.example.toml is stale: make example")
    }

    @Test func appsAreTheSameAppByBundleIdentifier() {
        let a = AppRef(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app")
        let b = AppRef(bundleIdentifier: "com.apple.safari", path: "/Volumes/Old/Safari.app")
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        #expect(AppRef(bundleIdentifier: nil, path: "/x.app") != AppRef(bundleIdentifier: nil, path: "/y.app"))
    }
}

@Suite struct ReservedKeysTests {
    @Test func aGlobalShortcutOnAFilesKeyIsNamed() {
        // ⇧⌘V: the clipboard history's natural chord, and Files' move here.
        #expect(ReservedKeys.taken(by: KeyChord(keyCode: 9, modifiers: KeyChord.command | KeyChord.shift)) == "moving here in Files (⇧⌘V)")
        #expect(ReservedKeys.taken(by: KeyChord(keyCode: 18, modifiers: KeyChord.command)) == "opening tile 1 (⌘1)")
        #expect(ReservedKeys.taken(by: KeyChord(keyCode: 9, modifiers: KeyChord.command | KeyChord.control)) == nil)
        #expect(ReservedKeys.taken(by: KeyChord(keyCode: KeyChord.space, modifiers: KeyChord.option)) == nil)
    }
}
