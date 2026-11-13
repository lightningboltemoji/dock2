import AppKit
import Dock2Core

/// Where an app is, what it is called, and what it looks like — looked up once per app and kept. What it looks
/// like is the icon dock2 shows for it: one the user gave it (`[icons]`), else its own
/// ([icons](product/icons.md)).
@MainActor
public final class AppDirectory {
    public struct Entry {
        public let url: URL
        public let name: String
        /// What dock2 shows it wearing.
        public fileprivate(set) var icon: NSImage
        /// What it wears everywhere else: Finder's, ⌘⇥'s.
        public let own: NSImage
        /// The build it was looked up at.
        public let version: String?
    }

    private var entries: [AppRef: Entry] = [:]
    public let files: TileIconFiles
    /// Draws one of Cairo's pictures, at whatever size it is drawn.
    private let picture: @MainActor (PictureIcon) -> NSImage?
    /// Draws the Files tile's own icon.
    private let filesTileOwn: @MainActor () -> NSImage?
    public private(set) var icons = TileIcons.none
    private var filesTile: NSImage?
    /// An icon changed: the user gave a tile another, or a file it names was checked.
    public var onIconsChange: (() -> Void)?

    public init(files: TileIconFiles = TileIconFiles(), picture: @escaping @MainActor (PictureIcon) -> NSImage? = { _ in nil },
                filesTile: @escaping @MainActor () -> NSImage? = { nil }) {
        self.files = files
        self.picture = picture
        filesTileOwn = filesTile
        files.onChange = { [weak self] in self?.iconsChanged() }
    }

    /// Nil when nothing with the app's bundle identifier is installed and nothing is at its path.
    public func entry(_ app: AppRef) -> Entry? {
        if let entry = entries[app] { return entry }
        guard let url = Self.locate(app) else { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        let own = NSWorkspace.shared.icon(forFile: url.path)
        let entry = Entry(url: url, name: name, icon: icon(for: .app(app)) ?? own, own: own, version: AppCatalog.version(of: url))
        entries[app] = entry
        return entry
    }

    /// The Files tile's own icon: dock2's, never Finder's, which Finder's own tile wears beside it.
    public var filesOwn: NSImage {
        filesTileOwn() ?? NSWorkspace.shared.icon(for: .folder)
    }

    /// The Files tile's: the `files` entry, else its own.
    public var filesIcon: NSImage {
        if let filesTile { return filesTile }
        let icon = icon(for: .files) ?? filesOwn
        filesTile = icon
        return icon
    }

    /// The app at `url` as dock2 shows it, where it is listed by its location: Open With.
    public func icon(ofAppAt url: URL) -> NSImage {
        let app = AppRef(bundleIdentifier: Bundle(url: url)?.bundleIdentifier, path: url.path)
        return icon(for: .app(app)) ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    /// What the user gave the tile to wear, drawn; nil for its own, or a file not yet checked or refused.
    public func icon(for key: TileIconKey) -> NSImage? {
        icons[key].flatMap { draw($0, for: key) }
    }

    /// `icon` drawn as `key`'s tile wears it: a file through the shim its entry was checked into.
    public func draw(_ icon: TileIcon, for key: TileIconKey) -> NSImage? {
        switch icon {
        case .picture(let icon): picture(icon)
        case .file: files.shim(for: key).map { NSWorkspace.shared.icon(forFile: $0.path) }
        // Its own, never what it wears itself, so two entries cannot lead round to each other.
        case .app(let app): Self.locate(app).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }

    /// Takes `[icons]` as the settings now read, their paths relative to `base`: the settings file's folder.
    public func setIcons(_ icons: TileIcons, base: URL) {
        let changed = icons != self.icons
        self.icons = icons
        if files.update(icons, base: base) || changed { iconsChanged() }
    }

    private func iconsChanged() {
        filesTile = nil
        for (app, entry) in entries { entries[app]?.icon = icon(for: .app(app)) ?? entry.own }
        onIconsChange?()
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
