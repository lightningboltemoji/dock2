import AppKit
import Dock2Core
@testable import Dock2System
import Foundation
import Testing

/// A system with one boolean per takeover, standing in for the Dock's preferences or a hot key.
private final class FakeSystem {
    /// dock2's state is `true`; the user's starts as `user`.
    var state: [TakeoverID: Bool]
    var log: [String] = []
    /// What will not take its original back.
    var refusing: Set<TakeoverID> = []

    init(user: [TakeoverID: Bool]) {
        state = user
    }

    func takeover(_ id: TakeoverID) -> Takeover { Fake(id: id, system: self) }

    struct Fake: Takeover {
        let id: TakeoverID
        let system: FakeSystem

        func snapshot() -> PlistValue { .bool(system.state[id] ?? false) }
        func apply() {
            system.state[id] = true
            system.log.append("apply \(id)")
        }
        func restore(_ original: PlistValue) -> Bool {
            guard case .bool(let value) = original, !system.refusing.contains(id) else { return false }
            system.state[id] = value
            system.log.append("restore \(id)")
            return true
        }
        func recovered() -> PlistValue? { system.state[id] == true ? .bool(false) : nil }
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct TakeoversTests {
    @Test func engagingJournalsTheUsersStateFirstAndReleasingGivesItBack() throws {
        let directory = try temporaryDirectory()
        let system = FakeSystem(user: [.systemDock: false, .hotKey(64): false])
        let takeovers = Takeovers(directory: directory, make: system.takeover)
        try takeovers.engage(.systemDock)
        try takeovers.engage(.hotKey(64))
        #expect(system.state == [.systemDock: true, .hotKey(64): true])
        #expect(Takeovers.journalExists(in: directory))

        takeovers.release(.hotKey(64))
        #expect(system.state[.hotKey(64)] == false)
        #expect(!takeovers.holds(.hotKey(64)))
        #expect(takeovers.releaseAll().isEmpty)
        #expect(system.state == [.systemDock: false, .hotKey(64): false])
        #expect(!Takeovers.journalExists(in: directory))
    }

    /// What the system will not take back stays journaled, for the guard, `--restore` or the next run.
    @Test func whatWillNotGoBackIsKept() throws {
        let directory = try temporaryDirectory()
        let system = FakeSystem(user: [.systemDock: false, .hotKey(64): false])
        let takeovers = Takeovers(directory: directory, make: system.takeover)
        try takeovers.engage(.systemDock)
        try takeovers.engage(.hotKey(64))
        system.refusing = [.systemDock]
        #expect(takeovers.releaseAll() == [.systemDock])
        #expect(system.state == [.systemDock: true, .hotKey(64): false])
        system.refusing = []
        let next = Takeovers(directory: directory, make: system.takeover)
        #expect(next.journal.entries.keys.sorted() == [.systemDock])
        #expect(next.releaseAll().isEmpty && system.state[.systemDock] == false && !Takeovers.journalExists(in: directory))
    }

    /// No journal, yet the system shows dock2's mark: the user's state is recovered, not dock2's journaled.
    @Test func aMarkWithNoJournalIsRecoveredNotSnapshotted() throws {
        let directory = try temporaryDirectory()
        let system = FakeSystem(user: [.systemDock: true, .hotKey(64): false])
        let takeovers = Takeovers(directory: directory, make: system.takeover)
        #expect(takeovers.journal.entries == [.systemDock: .bool(false)])
        try takeovers.engage(.systemDock)
        #expect(takeovers.releaseAll().isEmpty && system.state[.systemDock] == false)
    }

    /// A mark recovered but not written down is no journal: nothing is taken over on the strength of it.
    @Test func aRecoveryNotWrittenTakesNothingOver() throws {
        let directory = try temporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let system = FakeSystem(user: [.systemDock: true])
        let takeovers = Takeovers(directory: directory, make: system.takeover)
        system.log = []
        #expect(throws: (any Error).self) { try takeovers.engage(.systemDock) }
        #expect(system.log.isEmpty && !Takeovers.journalExists(in: directory))
    }

    /// A newer dock2's takeover is kept for it: the journal stays.
    @Test func aNewerDock2sTakeoverOutlivesGivingBack() throws {
        let directory = try temporaryDirectory()
        let newer: [String: Any] = ["version": 2, "takeovers": ["menu-bar": ["hidden": true], "file-viewer": false]]
        try PropertyListSerialization.data(fromPropertyList: newer, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent(Paths.journalName))
        let system = FakeSystem(user: [.fileViewer: true])
        let takeovers = Takeovers(directory: directory, make: system.takeover)
        #expect(takeovers.releaseAll().isEmpty && system.state[.fileViewer] == false)
        #expect(Takeovers.journalExists(in: directory))
        #expect(Takeovers(directory: directory, make: system.takeover).journal.unknown.keys.sorted() == ["menu-bar"])
    }

    /// A run that died left its journal: the system holds dock2's state, and the journal the user's. The
    /// next run must keep the journal, not snapshot dock2's own state as the user's.
    @Test func aSurvivingJournalIsKeptNotReplaced() throws {
        let directory = try temporaryDirectory()
        let system = FakeSystem(user: [.systemDock: false])
        try Takeovers(directory: directory, make: system.takeover).engage(.systemDock)
        #expect(system.state[.systemDock] == true)

        let next = Takeovers(directory: directory, make: system.takeover)
        #expect(next.holds(.systemDock))
        try next.engage(.systemDock)
        next.releaseAll()
        #expect(system.state[.systemDock] == false)
    }

    /// Switched off in Settings before the crash: the next run gives it back at once.
    @Test func whatTheNextRunDoesNotWantIsGivenBack() throws {
        let directory = try temporaryDirectory()
        let system = FakeSystem(user: [.systemDock: false, .hotKey(64): false])
        let first = Takeovers(directory: directory, make: system.takeover)
        try first.engage(.systemDock)
        try first.engage(.hotKey(64))

        let next = Takeovers(directory: directory, make: system.takeover)
        next.release(allBut: [.systemDock])
        #expect(system.state == [.systemDock: true, .hotKey(64): false])
        #expect(next.journal.entries.keys.sorted() == [.systemDock])
    }

    @Test func theSystemDockIsGivenBackLast() throws {
        let directory = try temporaryDirectory()
        let system = FakeSystem(user: [:])
        let takeovers = Takeovers(directory: directory, make: system.takeover)
        for id: TakeoverID in [.systemDock, .fileViewer, .hotKey(64)] { try takeovers.engage(id) }
        system.log = []
        takeovers.releaseAll()
        #expect(system.log == ["restore file-viewer", "restore hot-key.64", "restore system-dock"])
    }

    /// The journal cannot be written: nothing is taken over.
    @Test func anUnwritableJournalChangesNothing() throws {
        let directory = try temporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let system = FakeSystem(user: [.systemDock: false])
        let takeovers = Takeovers(directory: directory, make: system.takeover)
        #expect(throws: (any Error).self) { try takeovers.engage(.systemDock) }
        #expect(system.state[.systemDock] == false)
    }

    @Test func anUnreadableJournalIsRecoveredFromTheSystem() throws {
        let directory = try temporaryDirectory()
        try Data("garbage".utf8).write(to: directory.appendingPathComponent(Paths.journalName))
        // dock2's state still in place for the system Dock; the hot key shows no trace.
        let system = FakeSystem(user: [.systemDock: true, .hotKey(64): false])
        let takeovers = Takeovers(directory: directory, make: system.takeover)
        #expect(takeovers.journal.entries.keys.sorted() == [.systemDock])
        takeovers.releaseAll()
        #expect(system.state[.systemDock] == false)
        // Set aside, not deleted: it may hold what recovery cannot know.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("takeovers-unreadable-") })
    }

    /// The first dock2's journal, `system-dock.plist`, is read and replaced.
    @Test func theFirstVersionsJournalIsReadAndReplaced() throws {
        let directory = try temporaryDirectory()
        let v1: [String: Any] = ["version": 1, "keys": ["autohide": ["value": false], "autohide-delay": [String: Any]()]]
        try PropertyListSerialization.data(fromPropertyList: v1, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent(Paths.legacyJournalName))
        let system = FakeSystem(user: [:])
        let takeovers = Takeovers(directory: directory, make: system.takeover)
        #expect(takeovers.holds(.systemDock))
        try takeovers.engage(.hotKey(64))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(Paths.legacyJournalName).path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(Paths.journalName).path))
    }
}

@Suite struct SystemDockTests {
    /// The restart finds the Dock in the process table, where a Dock just started already is.
    @Test func theProcessTableHasTheRunningDock() {
        let listed = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").map(\.processIdentifier)
        #expect(!listed.isEmpty && Set(SystemDock.processes(running: SystemDock.executable)) == Set(listed))
    }
}
