import Dock2Core
import Foundation
import Testing

@Suite struct SettingValueTests {
    @Test func scalarsRoundTripAndRefuseOtherTypes() {
        #expect(Bool(propertyList: true.propertyList) == true)
        #expect(Bool(propertyList: 1 as NSNumber) == nil)
        #expect(Double(propertyList: 95 as NSNumber) == 95)
        #expect(Double(propertyList: true as NSNumber) == nil)
        #expect(Int(propertyList: 3 as NSNumber) == 3)
        #expect(String(propertyList: "x") == "x")
        #expect([String](propertyList: ["a", 1]) == nil)
    }

    /// Codable settings are stored as structured property lists, so `defaults read` shows them.
    @Test func codableSettingsAreStructuredPropertyLists() throws {
        let pinned = [AppRef(bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app")]
        let object = pinned.propertyList
        let array = try #require(object as? [[String: Any]])
        #expect(array.first?["bundleIdentifier"] as? String == "com.apple.Safari")
        #expect([AppRef](propertyList: object) == pinned)

        for shortcut: Shortcut in [.commandSpace, .none, .chord(KeyChord(keyCode: 49, modifiers: KeyChord.option))] {
            #expect(Shortcut(propertyList: shortcut.propertyList) == shortcut)
        }
    }

    /// ⌃⌘V stored with bit 13 for ⌃ reads back as ⌃⌘V.
    @Test func aControlStoredAsBit13ReadsAsControl() {
        let stored: [String: Any] = ["chord": ["_0": ["keyCode": 9, "modifiers": 8448]]]
        #expect(Shortcut(propertyList: stored) == .chord(KeyChord(keyCode: 9, modifiers: KeyChord.command | KeyChord.control)))
        let current = Shortcut.chord(KeyChord(keyCode: 9, modifiers: KeyChord.command | KeyChord.control))
        #expect(Shortcut(propertyList: current.propertyList) == current)
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
