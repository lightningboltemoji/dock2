import Foundation

/// Where dock2 keeps the little state it has, in `~/Library/Application Support/dock2`.
public enum Paths {
    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/dock2", isDirectory: true)

    /// The user's own state for every takeover dock2 holds (`TakeoverJournal`).
    static let journalName = "takeovers.plist"
    /// The journal as the first dock2 named it, read once and replaced.
    static let legacyJournalName = "system-dock.plist"

    /// Held by whichever process owns the journal: a running dock2, or its guard while it restores.
    static let lock = directory.appendingPathComponent("dock2.lock")

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
