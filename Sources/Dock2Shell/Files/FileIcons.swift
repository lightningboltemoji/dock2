import AppKit
import Dock2System
import UniformTypeIdentifiers

/// The icon Finder shows for a row, a crumb or a pill — what the network has none of a file's for: a server's
/// display, a share's group folder, Network's globe.
@MainActor
enum FileIcons {
    static func icon(for entry: FileEntry) -> NSImage {
        switch entry.remote {
        case .server: server
        case .share: share
        case nil: NSWorkspace.shared.icon(forFile: entry.url.path)
        }
    }

    static func icon(for url: URL) -> NSImage {
        if url == Servers.network { return network }
        if Servers.isServer(url) { return server }
        if Servers.isShare(url) { return share }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static let server = NSWorkspace.shared.icon(for: UTType("com.apple.mac") ?? .folder)
    private static let share = NSImage(contentsOfFile: resources + "GroupFolder.icns") ?? NSWorkspace.shared.icon(for: .folder)
    private static let network = NSImage(contentsOfFile: resources + "GenericNetworkIcon.icns") ?? NSWorkspace.shared.icon(for: .folder)
    private static let resources = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
}
