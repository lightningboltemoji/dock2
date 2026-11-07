import Foundation

public typealias FolderListing = Result<[FileEntry], Error>

/// What folders hold, read off the main thread, since listing one takes as long as it has items. What a folder last held stands until a
/// new read lands, so one read again never shows empty. A read waits briefly, so a small folder is there on the frame that asked. One read
/// at a time for a folder: changes during it come to one more. A folder forgotten has its read told to stop.
@MainActor
public final class FolderListings {
    private struct Folder {
        var listing: FolderListing?
        /// Something changed since `listing` was read.
        var isStale = false
        /// The read out, by its number.
        var reading: Int?
        var arrival: Arrival?
        /// That read has taken long enough to say so.
        var isSlow = false
    }

    /// What a read hands back, to the main thread waiting on it or to the turn it sends there, and what tells it to stop.
    private final class Arrival: @unchecked Sendable {
        private let landed = DispatchSemaphore(value: 0)
        private var listing: FolderListing?
        private let stopped = NSLock()
        private var stop = false

        var isCancelled: Bool { stopped.withLock { stop } }

        func cancel() { stopped.withLock { stop = true } }

        func deliver(_ listing: FolderListing) {
            self.listing = listing
            landed.signal()
        }

        func wait(for time: DispatchTimeInterval) -> FolderListing? {
            landed.wait(timeout: .now() + time) == .success ? listing : nil
        }
    }

    private var folders: [URL: Folder] = [:]
    private var reads = 0
    private let wait: DispatchTimeInterval
    private let slowAfter: TimeInterval
    /// A read landed after the turn that asked, or has been out for `slowAfter`.
    public var onChange: ((URL) -> Void)?

    public init(wait: DispatchTimeInterval = .milliseconds(10), slowAfter: TimeInterval = 0.25) {
        self.wait = wait
        self.slowAfter = slowAfter
    }

    /// What `folder` holds as far as is known, reading it with `read` unless that is up to date: nil until a first read has landed.
    /// `read` is given what says it is no longer wanted.
    public func listing(_ folder: URL, read: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) -> FolderListing) -> FolderListing? {
        let known = folders[folder]
        if known?.reading == nil, known?.listing == nil || known?.isStale == true { start(folder, read: read) }
        return folders[folder]?.listing
    }

    /// Up to date: what is known was read since `folder` last changed.
    public func isCurrent(_ folder: URL) -> Bool {
        guard let known = folders[folder] else { return false }
        return known.listing != nil && !known.isStale && known.reading == nil
    }

    /// Its first read has been out for a while, so a column can say so.
    public func isSlow(_ folder: URL) -> Bool {
        folders[folder]?.isSlow == true
    }

    /// `folder` changed: the next asking reads it again, and what is known stands until that lands.
    public func refresh(_ folder: URL) {
        folders[folder]?.isStale = true
    }

    public func refreshAll() {
        for folder in folders.keys { refresh(folder) }
    }

    public func forget(_ folder: URL) {
        folders[folder]?.arrival?.cancel()
        folders[folder] = nil
    }

    /// Forgets all but `kept`.
    public func keep(_ kept: Set<URL>) {
        for folder in folders.keys where !kept.contains(folder) { forget(folder) }
    }

    private func start(_ folder: URL, read: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) -> FolderListing) {
        reads += 1
        let number = reads
        folders[folder, default: Folder()].reading = number
        folders[folder]?.isStale = false
        let arrival = Arrival()
        folders[folder]?.arrival = arrival
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listing = read { arrival.isCancelled }
            arrival.deliver(listing)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.land(listing, in: folder, read: number, inTime: false) }
            }
        }
        if let listing = arrival.wait(for: wait) {
            land(listing, in: folder, read: number, inTime: true)
            return
        }
        guard folders[folder]?.listing == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + slowAfter) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.folders[folder]?.reading == number else { return }
                self.folders[folder]?.isSlow = true
                self.onChange?(folder)
            }
        }
    }

    /// `inTime`, the turn that asked has it, and nothing needs telling. A read asked for no more does nothing.
    private func land(_ listing: FolderListing, in folder: URL, read number: Int, inTime: Bool) {
        guard folders[folder]?.reading == number else { return }
        folders[folder]?.listing = listing
        folders[folder]?.reading = nil
        folders[folder]?.arrival = nil
        folders[folder]?.isSlow = false
        if !inTime { onChange?(folder) }
    }
}
