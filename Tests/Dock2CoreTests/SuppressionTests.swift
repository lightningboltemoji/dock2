import Dock2Core
import Foundation
import Testing

/// A key that was not set.
private let unset: PlistValue? = nil

@Suite struct SuppressionTests {
    @Test func snapshotRecordsEveryOverriddenKeyIncludingAbsentOnes() {
        let journal = SuppressionJournal.snapshot { key in key == "autohide" ? .bool(false) : nil }
        #expect(journal.originals.count == Suppression.overrides.count)
        #expect(journal.originals["autohide"] == .some(.bool(false)))
        #expect(journal.originals["autohide-delay"] == .some(unset))
    }

    @Test func restorationSetsWhatWasSetAndRemovesWhatWasNot() {
        let journal = SuppressionJournal(originals: ["autohide": .bool(true), "autohide-delay": unset])
        let expected: [SuppressionJournal.Step] = [.set("autohide", .bool(true)), .remove("autohide-delay")]
        #expect(journal.restoration == expected)
    }

    /// With the journal lost, a key that still holds dock2's value cannot be the user's: it goes back
    /// to unset. Anything else is the user's and stays.
    @Test func recoveryTreatsDock2sOwnValuesAsUnset() {
        let current: [String: PlistValue] = ["autohide": .bool(true), "autohide-delay": .real(0.2)]
        let journal = SuppressionJournal.recovered { current[$0] }
        #expect(journal.originals["autohide"] == .some(unset))
        #expect(journal.originals["autohide-delay"] == .some(.real(0.2)))
    }

    @Test func journalRoundTripsThroughDisk() throws {
        let journal = SuppressionJournal(originals: ["autohide": .bool(false), "autohide-delay": .real(0.25)])
        #expect(try SuppressionJournal.decode(journal.encoded()) == journal)
        let absent = SuppressionJournal(originals: ["autohide": unset, "autohide-delay": unset])
        #expect(try SuppressionJournal.decode(absent.encoded()) == absent)
    }

    @Test func unreadableJournalIsAnError() {
        #expect(throws: (any Error).self) { try SuppressionJournal.decode(Data("not a plist".utf8)) }
        let wrongVersion = try! PropertyListSerialization.data(fromPropertyList: ["version": 99, "keys": [String: Any]()],
                                                              format: .xml, options: 0)
        #expect(throws: SuppressionJournal.JournalError.self) { try SuppressionJournal.decode(wrongVersion) }
    }

    /// The Dock reads `autohide` as a boolean; handing it back an integer would be a different value.
    @Test func plistValuesKeepTheirType() {
        #expect(PlistValue(true as NSNumber) == .bool(true))
        #expect(PlistValue(1 as NSNumber) == .integer(1))
        #expect(PlistValue(0.5 as NSNumber) == .real(0.5))
        #expect(PlistValue(["a": [1, "b"]]) == .dictionary(["a": .array([.integer(1), .string("b")])]))
        #expect(PlistValue(NSObject()) == nil)
    }

    @Test func overridesHideTheDockForGood() {
        #expect(Suppression.overrides["autohide"] == .bool(true))
        guard case .real(let delay) = Suppression.overrides["autohide-delay"] else {
            Issue.record("the delay must be a real")
            return
        }
        #expect(delay >= 1000)
    }
}

@Suite struct DockItemTests {
    @Test func environmentOverridesThePinnedItems() {
        #expect(DockItem.pinned(environment: [:]) == DockItem.pinned)
        #expect(DockItem.pinned(environment: ["DOCK2_ITEMS": "com.apple.calculator, com.apple.Notes"])
                == [DockItem(bundleIdentifier: "com.apple.calculator"), DockItem(bundleIdentifier: "com.apple.Notes")])
    }
}
