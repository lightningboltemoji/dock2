import AppKit
import Dock2Core
import Foundation

/// Where dock2's settings are kept: the config file, which a person may keep in a dotfiles repo and share
/// between Macs, and this Mac's own state beside the journal.
public struct SettingsFile: Sendable {
    /// The config file, as named — perhaps a link into a dotfiles repo.
    public let url: URL
    /// A copy of the last text that could be read, to start from when the file can't be; none for a file
    /// named by `DOCK2_CONFIG`, so a development run cannot overwrite the real one's.
    let lastGood: URL?
    /// Held by every writer from reading the file to replacing it, so two processes' edits cannot interleave.
    let lock: URL
    /// This Mac's state: the settings that never leave it (`SettingKey(machine:)`).
    let state: URL

    public init(url: URL, lastGood: URL?, lock: URL, state: URL) {
        self.url = url
        self.lastGood = lastGood
        self.lock = lock
        self.state = state
    }

    /// `DOCK2_CONFIG`, else `~/.config/dock2/config.toml`. `XDG_CONFIG_HOME` is not consulted: an app opened at
    /// login never sees a shell's environment, so honouring it would split the terminal's dock2 from the real one.
    public static var standard: SettingsFile {
        let override = LaunchEnvironment.variables["DOCK2_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
        let url = override.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/dock2/config.toml")
        return SettingsFile(url: url, lastGood: override == nil ? Paths.directory.appendingPathComponent("config.last-good.toml") : nil,
                            lock: Paths.directory.appendingPathComponent("config.lock"),
                            state: Paths.directory.appendingPathComponent("state.json"))
    }

    /// The file the name leads to, through any links.
    var target: URL { url.resolvingSymlinksInPath() }

    /// The file's text, or nil when there is none.
    func read() throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// Replaces the file the name leads to, atomically, keeping its permissions. Writing through the link
    /// matters: an atomic write *at* a link replaces the link, and the dotfiles copy never hears of it.
    func write(_ text: String) throws {
        let target = self.target
        let folder = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString)")
        try Data(text.utf8).write(to: temporary)
        if let permissions = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        }
        guard rename(temporary.path, target.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Runs `body` holding the writers' lock.
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR, 0o600)
        if descriptor >= 0 { flock(descriptor, LOCK_EX) }
        defer {
            if descriptor >= 0 {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }
        return try body()
    }

    func readLastGood() -> String? {
        lastGood.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    func keepLastGood(_ text: String) {
        guard let lastGood, readLastGood() != text else { return }
        try? FileManager.default.createDirectory(at: lastGood.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: lastGood, options: .atomic)
    }

    /// Opens the file in whatever opens TOML — created first, with its starter comments, if there is none —
    /// else shows it in Finder.
    @MainActor
    public func open() {
        if (try? read()) == .some(nil) {
            try? withLock { try write(Settings.starter) }
        }
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    var machine: JSONFile<[String: String]> {
        JSONFile(state.lastPathComponent, in: state.deletingLastPathComponent())
    }
}
