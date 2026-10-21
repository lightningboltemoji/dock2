import AppKit
import Dock2Core

/// "Show in Finder", sent to dock2: the global `NSFileViewer` default names the app AppKit's reveal calls
/// and `open -R` hand their items to.
public struct FileViewerTakeover: Takeover {
    public static let key = "NSFileViewer"
    public let id = TakeoverID.fileViewer

    public init() {}

    public func snapshot() -> PlistValue {
        DefaultOriginal(value: PreferenceDomain.global.read(Self.key)).plist
    }

    public func apply() {
        do { try PreferenceDomain.global.apply([.set(Self.key, .string(Dock2Identity.bundleIdentifier))]) } catch { warn("\(error)") }
    }

    public func restore(_ original: PlistValue) -> Bool {
        let value = DefaultOriginal(original)?.value
        do {
            try PreferenceDomain.global.apply([value.map { .set(Self.key, $0) } ?? .remove(Self.key)])
        } catch {
            warn("\(error)")
            return false
        }
        return PreferenceDomain.global.read(Self.key) == value
    }

    public func recovered() -> PlistValue? {
        PreferenceDomain.global.read(Self.key) == .string(Dock2Identity.bundleIdentifier) ? DefaultOriginal(value: nil).plist : nil
    }

    /// dock2's own "Show in Finder": the items selected in Finder. While dock2 is the file viewer a reveal
    /// comes back to Files, so the first item's folder opens in Finder instead — opening a folder is
    /// Finder's whatever `NSFileViewer` says — with nothing selected.
    @MainActor
    public static func showInFinder(_ urls: [URL]) {
        guard PreferenceDomain.global.read(key) == .string(Dock2Identity.bundleIdentifier) else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return
        }
        guard let first = urls.first else { return }
        openInFinder(first.parentFolder)
    }

    /// A folder itself, open in Finder, whatever `NSFileViewer` says.
    @MainActor
    public static func openInFinder(_ folder: URL) {
        NSWorkspace.shared.open([folder], withApplicationAt: URL(fileURLWithPath: AppRef.finder.path), configuration: NSWorkspace.OpenConfiguration())
    }
}
