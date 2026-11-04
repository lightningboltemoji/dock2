import CoreServices
import Foundation

/// FSEvents on a set of folders: `onChange` hears, on the main queue, what changed under them — each file's
/// path with `files`, else the folders' — at most once per latency window.
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor ([String]) -> Void

    public convenience init(paths: [String], latency: TimeInterval = 1, onChange: @escaping @MainActor () -> Void) {
        self.init(paths: paths, latency: latency, files: false) { _ in onChange() }
    }

    public init(paths: [String], latency: TimeInterval = 1, files: Bool, onChange: @escaping @MainActor ([String]) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: CFArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { watcher.onChange(changed) }
        }
        let flags = kFSEventStreamCreateFlagUseCFTypes | (files ? kFSEventStreamCreateFlagFileEvents : 0)
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, FSEventStreamCreateFlags(flags))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    /// Hears nothing more.
    public func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit { stop() }
}
