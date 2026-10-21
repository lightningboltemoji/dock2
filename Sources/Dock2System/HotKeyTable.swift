import Dock2Core
import Foundation

/// The window server's live table of system hot keys (SkyLight, private). Switching an entry off is
/// session-wide and immediate, writes no preference, and outlives the process that did it.
public enum HotKeyTable {
    /// Spotlight's ⌘space.
    public static let spotlight = 64

    private typealias IsEnabled = @convention(c) (Int32) -> Bool
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32

    nonisolated(unsafe) private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let isEnabledFunction = skyLight.flatMap { dlsym($0, "SLSIsSymbolicHotKeyEnabled") }
        .map { unsafeBitCast($0, to: IsEnabled.self) }
    private static let setEnabledFunction = skyLight.flatMap { dlsym($0, "SLSSetSymbolicHotKeyEnabled") }
        .map { unsafeBitCast($0, to: SetEnabled.self) }

    /// False on a macOS without the table's functions: no hot key can be taken over there.
    public static var isAvailable: Bool { isEnabledFunction != nil && setEnabledFunction != nil }

    public static func isEnabled(_ entry: Int) -> Bool {
        isEnabledFunction?(Int32(entry)) ?? true
    }

    /// Switched off in Keyboard Shortcuts: `com.apple.symbolichotkeys`, which the table is loaded from and
    /// dock2 never writes, says so.
    public static func isOffByUser(_ entry: Int) -> Bool {
        guard case .dictionary(let entries)? = PreferenceDomain("com.apple.symbolichotkeys").read("AppleSymbolicHotKeys"),
              case .dictionary(let fields)? = entries[String(entry)] else { return false }
        return fields["enabled"] == .bool(false) || fields["enabled"] == .integer(0)
    }

    @discardableResult
    public static func setEnabled(_ entry: Int, _ enabled: Bool) -> Bool {
        guard let setEnabledFunction else { return false }
        let error = setEnabledFunction(Int32(entry), enabled)
        if error != 0 { warn("could not \(enabled ? "enable" : "disable") system hot key \(entry): error \(error)") }
        return error == 0
    }
}

/// One system hot key, switched off so the chord reaches dock2 alone.
public struct HotKeyTakeover: Takeover {
    public let entry: Int
    public var id: TakeoverID { .hotKey(entry) }

    public init(entry: Int) {
        self.entry = entry
    }

    public func snapshot() -> PlistValue {
        HotKeyOriginal(enabled: HotKeyTable.isEnabled(entry)).plist
    }

    public func apply() {
        HotKeyTable.setEnabled(entry, false)
    }

    public func restore(_ original: PlistValue) -> Bool {
        let enabled = HotKeyOriginal(original)?.enabled ?? true
        HotKeyTable.setEnabled(entry, enabled)
        return HotKeyTable.isEnabled(entry) == enabled
    }

    /// Off in the table while the user's preference leaves it on: switched off by dock2, whose switch writes
    /// no preference — the user's, in Keyboard Shortcuts, does.
    public func recovered() -> PlistValue? {
        HotKeyTable.isEnabled(entry) || HotKeyTable.isOffByUser(entry) ? nil : HotKeyOriginal(enabled: true).plist
    }
}
