import Dock2Core
import Foundation
import Testing

/// A key that was not set.
private let unset: PlistValue? = nil

@Suite struct DockOriginalTests {
    @Test func snapshotRecordsEveryOverriddenKeyIncludingAbsentOnes() {
        let original = DockOriginal.snapshot { key in key == "autohide" ? .bool(false) : nil }
        #expect(original.keys.count == Suppression.overrides.count)
        #expect(original.keys["autohide"] == .some(.bool(false)))
        #expect(original.keys["autohide-delay"] == .some(unset))
    }

    @Test func restorationSetsWhatWasSetAndRemovesWhatWasNot() {
        let original = DockOriginal(keys: ["autohide": .bool(true), "autohide-delay": unset])
        #expect(original.restoration == [.set("autohide", .bool(true)), .remove("autohide-delay")])
    }

    /// With the journal lost, a key that still holds dock2's value cannot be the user's: it goes back
    /// to unset. Anything else is the user's and stays.
    @Test func recoveryTreatsDock2sOwnValuesAsUnset() {
        let current: [String: PlistValue] = ["autohide": .bool(true), "autohide-delay": .real(0.2)]
        let original = DockOriginal.recovered { current[$0] }
        #expect(original.keys["autohide"] == .some(unset))
        #expect(original.keys["autohide-delay"] == .some(.real(0.2)))
    }

    /// An older dock2's journal lacks a key it did not override: the Dock still holds the user's value for
    /// it, which is read; what the journal has is kept, though the Dock now holds dock2's.
    @Test func completingReadsOnlyTheKeysTheOriginalLacks() {
        let older = DockOriginal(keys: ["autohide": .bool(false), "autohide-delay": unset])
        let current: [String: PlistValue] = ["autohide": .bool(true), "autohide-delay": .real(1000.0625),
                                             "minimize-to-application": .bool(true)]
        let completed = older.completed { current[$0] }
        #expect(completed.keys == ["autohide": .bool(false), "autohide-delay": unset, "minimize-to-application": .bool(true)])
        #expect(completed.completed { _ in .bool(false) } == completed)
    }

    @Test func roundTripsThroughItsPlist() {
        let original = DockOriginal(keys: ["autohide": .bool(false), "autohide-delay": unset])
        #expect(DockOriginal(original.plist) == original)
        #expect(DockOriginal(.string("nonsense")) == nil)
    }

    @Test func overridesHideTheDockForGood() {
        #expect(Suppression.overrides["autohide"] == .bool(true))
        guard case .real(let delay) = Suppression.overrides["autohide-delay"] else {
            Issue.record("the delay must be a real")
            return
        }
        #expect(delay >= 1000)
        #expect(Suppression.changes == [.set("autohide", .bool(true)), .set("autohide-delay", .real(1000.0625)),
                                        .set("minimize-to-application", .bool(false))])
        // The tip that hides the Dock for good is not dock2's mark.
        #expect(Suppression.mark.value != .real(1000))
    }
}

@Suite struct TakeoverJournalTests {
    @Test func idsRoundTripThroughTheirNames() {
        for id: TakeoverID in [.systemDock, .hotKey(64), .hotKey(1), .fileViewer] {
            #expect(TakeoverID(rawValue: id.rawValue) == id)
        }
        #expect(TakeoverID(rawValue: "hot-key.") == nil)
        #expect(TakeoverID(rawValue: "menu-bar") == nil)
    }

    /// Giving the Dock back restarts it, so it goes last.
    @Test func theSystemDockIsGivenBackLast() {
        let ids: [TakeoverID] = [.systemDock, .fileViewer, .hotKey(64), .hotKey(1)]
        #expect(ids.sorted() == [.fileViewer, .hotKey(1), .hotKey(64), .systemDock])
    }

    @Test func roundTripsThroughDisk() throws {
        let journal = TakeoverJournal(entries: [
            .systemDock: DockOriginal(keys: ["autohide": .bool(false), "autohide-delay": unset]).plist,
            .hotKey(64): HotKeyOriginal(enabled: true).plist,
            .fileViewer: DefaultOriginal(value: nil).plist,
        ])
        #expect(try TakeoverJournal.decode(journal.encoded()) == journal)
        #expect(try TakeoverJournal.decode(TakeoverJournal().encoded()) == TakeoverJournal())
    }

    /// The first dock2 wrote only the system Dock's keys, as version 1.
    @Test func readsTheFirstVersion() throws {
        let v1: [String: Any] = ["version": 1, "keys": ["autohide": ["value": false], "autohide-delay": [String: Any]()]]
        let data = try PropertyListSerialization.data(fromPropertyList: v1, format: .xml, options: 0)
        let journal = try TakeoverJournal.decode(data)
        #expect(journal.entries.keys.sorted() == [.systemDock])
        #expect(DockOriginal(journal.entries[.systemDock]!) == DockOriginal(keys: ["autohide": .bool(false), "autohide-delay": unset]))
    }

    @Test func anUnreadableJournalIsAnError() throws {
        #expect(throws: TakeoverJournal.JournalError.unreadable) { try TakeoverJournal.decode(Data("not a plist".utf8)) }
        let future = try PropertyListSerialization.data(fromPropertyList: ["version": 99, "takeovers": [String: Any]()],
                                                        format: .xml, options: 0)
        #expect(throws: TakeoverJournal.JournalError.unreadable) { try TakeoverJournal.decode(future) }
    }

    /// A newer dock2's takeover this one cannot give back: kept, and written back as it was.
    @Test func whatANewerDock2TookOverIsKept() throws {
        let newer = try PropertyListSerialization.data(fromPropertyList: ["version": 2, "takeovers": ["menu-bar": ["hidden": true],
                                                                                                       "file-viewer": [String: Any]()]],
                                                       format: .xml, options: 0)
        let journal = try TakeoverJournal.decode(newer)
        #expect(journal.entries.keys.sorted() == [.fileViewer] && journal.unknown == ["menu-bar": .dictionary(["hidden": .bool(true)])])
        var rest = journal
        rest.entries = [:]
        #expect(try TakeoverJournal.decode(rest.encoded()) == rest && !rest.isEmpty)
    }

    @Test func originalsRoundTrip() {
        #expect(HotKeyOriginal(HotKeyOriginal(enabled: false).plist) == HotKeyOriginal(enabled: false))
        #expect(DefaultOriginal(DefaultOriginal(value: .string("com.apple.finder")).plist)?.value == .string("com.apple.finder"))
        #expect(DefaultOriginal(DefaultOriginal(value: nil).plist)?.value == nil)
    }
}

@Suite struct PlistValueTests {
    /// The Dock reads `autohide` as a boolean; handing it back an integer would be a different value.
    @Test func valuesKeepTheirType() {
        #expect(PlistValue(true as NSNumber) == .bool(true))
        #expect(PlistValue(1 as NSNumber) == .integer(1))
        #expect(PlistValue(0.5 as NSNumber) == .real(0.5))
        #expect(PlistValue(["a": [1, "b"]]) == .dictionary(["a": .array([.integer(1), .string("b")])]))
        #expect(PlistValue(NSObject()) == nil)
    }
}
