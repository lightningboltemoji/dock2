import Dock2Core
import Foundation

/// The system Dock's own settings, for the first launch to copy ([settings](product/settings.md)).
public struct SystemDockSettings: Equatable {
    public var pinned: [AppRef]
    public var tileSize: Double
    public var autohide: Bool
    public var revealDelay: Double?
    public var slideTimeModifier: Double?
    public var bounce: Bool
    public var minimizeToApp: Bool

    /// Read through `read`, which answers for the keys dock2 overrides with the user's own values when the
    /// system Dock is suppressed — they are in the journal then, not in the Dock's preferences.
    public static func read(_ read: (String) -> PlistValue?) -> SystemDockSettings {
        func number(_ key: String) -> Double? {
            switch read(key) {
            case .real(let value): value
            case .integer(let value): Double(value)
            default: nil
            }
        }
        func bool(_ key: String) -> Bool? {
            switch read(key) {
            case .bool(let value): value
            case .integer(let value): value != 0
            default: nil
            }
        }
        return SystemDockSettings(pinned: pinnedApps(read("persistent-apps")),
                                  tileSize: number("tilesize") ?? DockMetrics.defaultTileSize,
                                  autohide: bool("autohide") ?? false,
                                  revealDelay: number("autohide-delay"),
                                  slideTimeModifier: number("autohide-time-modifier"),
                                  bounce: bool("launchanim") ?? true,
                                  minimizeToApp: bool("minimize-to-application") ?? false)
    }

    /// `persistent-apps`: each app tile's bundle identifier and file URL. Spacers and anything without an
    /// app are skipped.
    static func pinnedApps(_ value: PlistValue?) -> [AppRef] {
        guard case .array(let tiles)? = value else { return [] }
        return tiles.compactMap { tile in
            guard case .dictionary(let fields) = tile, case .dictionary(let data)? = fields["tile-data"] else { return nil }
            var bundleIdentifier: String?
            if case .string(let id)? = data["bundle-identifier"] { bundleIdentifier = id }
            var path: String?
            if case .dictionary(let file)? = data["file-data"], case .string(let string)? = file["_CFURLString"] {
                path = URL(string: string).map(\.path) ?? string
            }
            guard bundleIdentifier != nil || path != nil else { return nil }
            return AppRef(bundleIdentifier: bundleIdentifier, path: path ?? "")
        }
    }

    /// Writes these as dock2's own settings: the first launch's copy. A setting the config file already
    /// writes — another Mac's, or the person's own — keeps the file's value.
    @MainActor
    public func copy(into settings: SettingsStore) {
        func fill<Value>(_ key: SettingKey<Value>, _ value: Value?) {
            guard let value, !settings.isWritten(key) else { return }
            settings[key] = value
        }
        var seen = Set<AppRef>()
        fill(Settings.pinned, pinned.filter { $0 != .finder && seen.insert($0).inserted })
        fill(Settings.tileSize, tileSize)
        fill(Settings.autohide, autohide)
        fill(Settings.revealDelay, revealDelay)
        fill(Settings.slideTimeModifier, slideTimeModifier)
        fill(Settings.bounce, bounce)
        fill(Settings.minimizeToApp, minimizeToApp)
    }
}

extension Takeovers {
    /// The system Dock's preferences as the user set them: from the journal for the keys dock2 overrides
    /// while it holds them, from the Dock's domain for the rest.
    public func usersDockPreference(_ key: String) -> PlistValue? {
        if let entry = journal.entries[.systemDock], let original = DockOriginal(entry), let value = original.keys[key] {
            return value
        }
        return SystemDock.read(key)
    }
}
