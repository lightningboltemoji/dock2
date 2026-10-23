import Dock2Core
import Foundation

/// A system behaviour dock2 changes while it runs, and how to give it back.
public protocol Takeover {
    var id: TakeoverID { get }
    /// The user's state as it is now, journaled before `apply`.
    func snapshot() -> PlistValue
    /// A journaled `original`, with the user's state for whatever this dock2 takes over that the dock2 which
    /// journaled it did not.
    func completed(_ original: PlistValue) -> PlistValue
    /// Puts dock2's state in place.
    func apply()
    /// Puts the journaled `original` back; false unless the system, read back, holds it.
    func restore(_ original: PlistValue) -> Bool
    /// The user's state as well as the system's tells it, when the system shows dock2's mark — a state
    /// only dock2 leaves — and no journal has it; nil when there is no mark.
    func recovered() -> PlistValue?
}

extension Takeover {
    public func completed(_ original: PlistValue) -> PlistValue { original }
}

/// Every takeover dock2 holds, through the journal that can give each one back (IMPLEMENTATION.md §4).
///
/// Every call assumes its caller holds the `InstanceLock`: the journal has exactly one owner.
public final class Takeovers {
    /// Every takeover this dock2 can make: what a lost journal is recovered over.
    public static let known: [TakeoverID] = [.systemDock, .hotKey(HotKeyTable.spotlight), .fileViewer]

    /// The takeover a journal entry names.
    public static func standard(_ id: TakeoverID) -> Takeover {
        switch id {
        case .systemDock: SystemDockTakeover()
        case .hotKey(let entry): HotKeyTakeover(entry: entry)
        case .fileViewer: FileViewerTakeover()
        }
    }

    private let journalURL: URL
    private let legacyURL: URL
    private let make: (TakeoverID) -> Takeover
    public private(set) var journal: TakeoverJournal
    /// The journal in memory is the one on disk: false while a recovery could not be written.
    private var written = true

    /// Loads the journal a previous run left, if any: its entries are the user's state, the system dock2's.
    /// A takeover it lacks whose mark the system shows is recovered (`recovered()`), so dock2's state is never
    /// journaled as the user's; an unreadable journal is set aside and recovered the same way.
    public init(directory: URL = Paths.directory, make: @escaping (TakeoverID) -> Takeover = Takeovers.standard) {
        journalURL = directory.appendingPathComponent(Paths.journalName)
        legacyURL = directory.appendingPathComponent(Paths.legacyJournalName)
        self.make = make
        journal = TakeoverJournal()
        if let found = [journalURL, legacyURL].first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            do {
                journal = try TakeoverJournal.decode(Data(contentsOf: found))
                note("found dock2's journal from a previous run: \(journal.entries.keys.sorted()); keeping it for giving back")
            } catch {
                warn("\(error); setting it aside and recovering from the system's current state")
                setAside(found)
            }
        }
        var recovered = false
        for id in Self.known where journal.entries[id] == nil {
            guard let original = make(id).recovered() else { continue }
            warn("the system shows dock2's mark for \(id), and no journal has it; recovering the user's state")
            journal.entries[id] = original
            recovered = true
        }
        if recovered {
            do { try save() } catch {
                written = false
                warn("could not write the recovered journal: \(error.localizedDescription)")
            }
        }
    }

    /// Whether a journal is on disk: dock2 is running, or exited without giving everything back.
    public static func journalExists(in directory: URL = Paths.directory) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: directory.appendingPathComponent(Paths.journalName).path)
            || manager.fileExists(atPath: directory.appendingPathComponent(Paths.legacyJournalName).path)
    }

    public func holds(_ id: TakeoverID) -> Bool {
        journal.entries[id] != nil
    }

    /// Journals the user's state, unless a previous run already did — completing what it journaled — then
    /// takes it over. Throws, having changed nothing, when the journal cannot be written.
    public func engage(_ id: TakeoverID) throws {
        let takeover = make(id)
        let entry = journal.entries[id].map(takeover.completed) ?? takeover.snapshot()
        if journal.entries[id] != entry || !written {
            var next = journal
            next.entries[id] = entry
            try write(next)
            journal = next
            written = true
        }
        takeover.apply()
    }

    /// Gives one takeover back and forgets it — unless the system would not take it back: then it is kept,
    /// to be tried again by the guard, `--restore` or the next run. Returns whether it was given back.
    @discardableResult
    public func release(_ id: TakeoverID) -> Bool {
        guard let original = journal.entries[id] else { return true }
        guard make(id).restore(original) else {
            warn("could not give back \(id); keeping it in the journal to try again")
            return false
        }
        journal.entries[id] = nil
        do { try save() } catch { warn("gave back \(id) but could not update the journal: \(error.localizedDescription)") }
        return true
    }

    /// Gives back every takeover except `wanted`: what a previous run held that this one will not.
    public func release(allBut wanted: Set<TakeoverID>) {
        for id in journal.entries.keys.sorted() where !wanted.contains(id) { release(id) }
    }

    /// Gives everything back, the system Dock last; the journal goes once it holds nothing. Returns what
    /// the system would not take back, kept.
    @discardableResult
    public func releaseAll() -> [TakeoverID] {
        journal.entries.keys.sorted().filter { !release($0) }
    }

    // MARK: - On disk

    private func save() throws {
        try write(journal)
    }

    /// Beside the new one, not deleted: it may hold what recovery cannot know, the user's own reveal delay.
    private func setAside(_ url: URL) {
        let aside = url.deletingLastPathComponent().appendingPathComponent("takeovers-unreadable-\(Int(Date().timeIntervalSince1970)).plist")
        do { try FileManager.default.moveItem(at: url, to: aside) } catch { warn("could not set the journal aside: \(error.localizedDescription)") }
    }

    /// Atomically, so a crash mid-write leaves the old journal or the new one, never half of either. An
    /// empty journal is no file at all.
    private func write(_ journal: TakeoverJournal) throws {
        let manager = FileManager.default
        if journal.isEmpty {
            for url in [journalURL, legacyURL] where manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
            return
        }
        try manager.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try journal.encoded().write(to: journalURL, options: .atomic)
        if manager.fileExists(atPath: legacyURL.path) { try manager.removeItem(at: legacyURL) }
    }
}
