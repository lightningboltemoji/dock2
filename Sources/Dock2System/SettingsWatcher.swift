import Dispatch
import Foundation

/// Vnode sources on each file and its folder, from emira's `ConfigWatcher`: an atomic save is a folder event
/// that ends a watch on the old inode, and an in-place write a file event the folder never sees. `onChange`
/// may fire several times for one save; coalescing is the caller's.
@MainActor
final class SettingsWatcher {
    private let files: [String]
    private let onChange: @MainActor () -> Void
    private var folderSources: [DispatchSourceFileSystemObject] = []
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]

    /// Watches each of `files`: the config file as named, and the file a link leads to.
    init(_ files: [URL], onChange: @escaping @MainActor () -> Void) {
        self.files = Array(Set(files.map(\.path))).sorted()
        self.onChange = onChange
        let folders = Set(self.files.map { ($0 as NSString).deletingLastPathComponent })
        for folder in folders.sorted() {
            if let source = source(for: folder, mask: [.write, .rename, .delete], handler: { [weak self] _ in
                guard let self else { return }
                // The file may have just been created, or replaced by one this isn't holding.
                for file in self.files where self.fileSources[file] == nil { self.arm(file) }
                self.onChange()
            }) {
                folderSources.append(source)
            }
        }
        for file in self.files { arm(file) }
    }

    isolated deinit {
        for source in folderSources { source.cancel() }
        for source in fileSources.values { source.cancel() }
    }

    /// Follows the path, not the inode, so an atomic save is survived.
    private func arm(_ file: String) {
        fileSources[file]?.cancel()
        fileSources[file] = source(for: file, mask: [.write, .extend, .rename, .delete, .attrib]) { [weak self] events in
            guard let self else { return }
            if events.contains(.rename) || events.contains(.delete) { self.arm(file) }
            self.onChange()
        }
    }

    private func source(for path: String, mask: DispatchSource.FileSystemEvent,
                        handler: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void) -> DispatchSourceFileSystemObject? {
        // `O_EVTONLY` doesn't keep an unmounting volume busy.
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler { [weak source] in
            let events = source?.data ?? []
            MainActor.assumeIsolated { handler(events) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
