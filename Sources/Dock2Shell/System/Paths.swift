import Foundation

/// Where dock2 keeps the little state it has, in `~/Library/Application Support/dock2`.
enum Paths {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/dock2", isDirectory: true)

    /// The user's own Dock settings while dock2 has replaced them (`SuppressionJournal`).
    static let journal = directory.appendingPathComponent("system-dock.plist")

    /// Held by whichever process owns the journal: a running dock2, or its guard while it restores.
    static let lock = directory.appendingPathComponent("dock2.lock")

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
