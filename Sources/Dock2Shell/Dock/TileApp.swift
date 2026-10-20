import AppKit
import Dock2Core

/// The application behind a tile: where it is, what it is called, and what it looks like.
@MainActor
final class TileApp {
    let item: DockItem
    let url: URL
    let name: String
    let icon: NSImage

    /// Nil when nothing with the item's bundle identifier is installed.
    init?(_ item: DockItem) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleIdentifier) else {
            warn("no application with bundle identifier \(item.bundleIdentifier) is installed; leaving it out")
            return nil
        }
        self.item = item
        self.url = url
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        self.name = name
        icon = NSWorkspace.shared.icon(forFile: url.path)
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleIdentifier).isEmpty
    }

    /// Launches the app, or brings it forward — reopening a window if it has none, as the Dock does.
    func open(completion: @escaping @MainActor (Bool) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [name] _, error in
            if let error { warn("could not open \(name): \(error.localizedDescription)") }
            Task { @MainActor in completion(error == nil) }
        }
    }
}
