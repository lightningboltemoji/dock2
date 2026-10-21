import AppKit
import Dock2Core

/// Where an app is, what it is called, and what it looks like — looked up once per app and kept.
@MainActor
public final class AppDirectory {
    public struct Entry {
        public let url: URL
        public let name: String
        public let icon: NSImage
        /// The build it was looked up at.
        public let version: String?
    }

    private var entries: [AppRef: Entry] = [:]

    public init() {}

    /// Nil when nothing with the app's bundle identifier is installed and nothing is at its path.
    public func entry(_ app: AppRef) -> Entry? {
        if let entry = entries[app] { return entry }
        guard let url = Self.locate(app) else { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        let entry = Entry(url: url, name: name, icon: NSWorkspace.shared.icon(forFile: url.path), version: AppCatalog.version(of: url))
        entries[app] = entry
        return entry
    }

    /// Forgets each app the catalog now finds changed since it was looked up: moved, replaced by a copy
    /// elsewhere, or updated in place, its icon perhaps new. True if it forgot any.
    @discardableResult
    public func forgetChanged(_ catalog: [AppCatalog.App]) -> Bool {
        let changed = catalog.filter { app in
            entries[app.ref].map { $0.url.standardizedFileURL != app.url.standardizedFileURL || $0.version != app.version } ?? false
        }
        for app in changed { entries[app.ref] = nil }
        return !changed.isEmpty
    }

    /// The installed copy LaunchServices prefers for the bundle identifier, else whatever is at the path.
    public static func locate(_ app: AppRef) -> URL? {
        if let id = app.bundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return url
        }
        return FileManager.default.fileExists(atPath: app.path) ? URL(fileURLWithPath: app.path) : nil
    }
}
