import Dock2Core
import Foundation

/// One item in a folder, with what a row and the preview show.
public struct FileEntry: Sendable, Equatable, Identifiable {
    public let url: URL
    /// The name Finder shows: an extension the user hid stays hidden.
    public let name: String
    /// Opens in the next column: a folder, or a link to one — not a package such as an app.
    public let isFolder: Bool
    public let isPackage: Bool
    public let isHidden: Bool
    public let size: Int64?
    public let modified: Date?
    public let created: Date?
    /// "Swift Source", "Folder".
    public let kind: String?
    /// In iCloud and not on this Mac: opening or copying it downloads it.
    public let isCloudOnly: Bool
    /// A mounted volume's root, which ⌘E ejects.
    public let isVolume: Bool

    public var id: URL { url }
}

/// A folder's items in Finder's order ([files](product/files/README.md#layout)).
public enum DirectoryListing {
    static let keys: [URLResourceKey] = [
        .localizedNameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .fileSizeKey,
        .totalFileSizeKey, .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey,
        .ubiquitousItemDownloadingStatusKey, .isVolumeKey,
    ]

    /// Throws what the file system said: `CocoaError.fileReadNoPermission` for a place macOS keeps closed.
    /// Each item's URL is the folder's as given with its name added — the URL listing would return resolves
    /// links on the way, `/tmp` becoming `/private/tmp`, and would match nothing Files holds.
    public static func list(_ folder: URL, showsHidden: Bool, foldersFirst: Bool = true, closed: (URL) -> Bool) throws -> [FileEntry] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let entries = names.compactMap { entry(folder.appendingPathComponent($0), closed: closed) }.filter { showsHidden || !$0.isHidden }
        return FinderOrder.sorted(entries, name: \.name, isFolder: { foldersFirst && $0.isFolder })
    }

    /// `closed` says which folders are closed to dock2: a link into one is taken for a folder, what it leads to
    /// unread — opened, it shows locked.
    public static func entry(_ url: URL, closed: (URL) -> Bool) -> FileEntry? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        var isFolder = values.isDirectory == true && values.isPackage != true
        if values.isSymbolicLink == true, let target = linkTarget(url), closed(target) {
            isFolder = true
        } else if values.isSymbolicLink == true {
            let target = url.resolvingSymlinksInPath()
            let resolved = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            isFolder = resolved?.isDirectory == true && resolved?.isPackage != true
        }
        return FileEntry(
            url: url.canonical, name: values.localizedName ?? url.lastPathComponent, isFolder: isFolder,
            isPackage: values.isPackage == true, isHidden: values.isHidden == true || url.lastPathComponent.hasPrefix("."),
            size: (values.totalFileSize ?? values.fileSize).map(Int64.init), modified: values.contentModificationDate,
            created: values.creationDate, kind: values.localizedTypeDescription,
            isCloudOnly: values.ubiquitousItemDownloadingStatus == .notDownloaded, isVolume: values.isVolume == true)
    }

    /// Where a link leads, read from the link alone — its `..` left for `closed` to follow where links lead.
    private static func linkTarget(_ url: URL) -> URL? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        let path = destination.hasPrefix("/") ? destination : url.deletingLastPathComponent().path + "/" + destination
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// A folder watched for items added, removed or renamed in it — not below it: a kqueue vnode source, which
/// hears at once. None for a folder closed to dock2 (`FileAccess.isClosed`): opening one to watch it raises
/// macOS's prompt, and waits on it.
public final class DirectoryWatch: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject?

    public init?(_ folder: URL, choice: FileAccessChoice, onChange: @escaping @MainActor () -> Void) {
        guard !FileAccess.isClosedReached(folder, choice: choice) else { return nil }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            source = nil
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
