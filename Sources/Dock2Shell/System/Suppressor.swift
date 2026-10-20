import Dock2Core
import Foundation

/// Hides the system Dock while dock2 runs and puts it back after, through `SuppressionJournal`.
///
/// Every entry point assumes its caller holds the `InstanceLock`: the journal has exactly one owner.
public enum Suppressor {
    /// Records the user's settings, unless a previous run's journal survives — then those are the
    /// user's, and the keys hold dock2's values — and replaces them with dock2's.
    public static func suppress() throws {
        do {
            if try loadJournal() == nil {
                try save(SuppressionJournal.snapshot(reading: SystemDock.read))
            } else {
                note("found the system Dock's settings from a previous run; keeping them for restoring")
            }
        } catch let error as SuppressionJournal.JournalError {
            warn("\(error); assuming the Dock's defaults for the keys dock2 changes")
            try save(SuppressionJournal.recovered(reading: SystemDock.read))
        }
        let overrides = Suppression.overrides.keys.sorted().map { SuppressionJournal.Step.set($0, Suppression.overrides[$0]!) }
        if SystemDock.apply(overrides) { SystemDock.restart() }
    }

    /// Writes the journal's settings back and restarts the Dock if anything changed. Returns false
    /// when there was nothing to restore.
    @discardableResult
    public static func restore() -> Bool {
        let journal: SuppressionJournal
        do {
            guard let saved = try loadJournal() else { return false }
            journal = saved
        } catch {
            warn("\(error); restoring the Dock's defaults for the keys dock2 changed")
            journal = .recovered(reading: SystemDock.read)
        }
        if SystemDock.apply(journal.restoration) { SystemDock.restart() }
        do {
            try FileManager.default.removeItem(at: Paths.journal)
        } catch {
            warn("restored the Dock but could not remove \(Paths.journal.path): \(error.localizedDescription)")
        }
        return true
    }

    /// Whether a journal is waiting: dock2 is running, or exited without restoring.
    public static var isSuppressed: Bool {
        FileManager.default.fileExists(atPath: Paths.journal.path)
    }

    private static func loadJournal() throws -> SuppressionJournal? {
        guard let data = try? Data(contentsOf: Paths.journal) else { return nil }
        return try SuppressionJournal.decode(data)
    }

    /// Atomically, so a crash mid-write leaves the old journal or the new one, never half of either.
    private static func save(_ journal: SuppressionJournal) throws {
        try Paths.ensureDirectory()
        try journal.encoded().write(to: Paths.journal, options: .atomic)
    }
}
