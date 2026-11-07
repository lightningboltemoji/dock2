@testable import Dock2System
import Foundation
import Testing

/// A read here is a closure that holds until told: what a slow disk or a share that won't answer looks like.
@MainActor
@Suite struct FolderListingsTests {
    /// Lets reads through one at a time, and counts them.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        private let open = DispatchSemaphore(value: 0)
        var reads: Int { lock.withLock { started } }

        func read(_ entries: [FileEntry] = []) -> FolderListing {
            lock.withLock { started += 1 }
            open.wait()
            return .success(entries)
        }

        func release() { open.signal() }
    }

    let folder = URL(fileURLWithPath: "/tmp/folder/")

    nonisolated static func entry(_ name: String) -> FileEntry {
        FileEntry(remote: .server, url: URL(fileURLWithPath: "/tmp/folder/\(name)"), name: name, ejects: false)
    }

    private func names(_ listing: FolderListing?) -> [String]? {
        (try? listing?.get())?.map(\.name)
    }

    /// `onChange` until it has fired `times`, in a run loop turn of its own.
    private func changes(of listings: FolderListings, _ times: Int = 1) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var left = times
            listings.onChange = { _ in
                left -= 1
                if left == 0 { done.resume() }
            }
        }
    }

    @Test func aFolderReadInTimeIsThereOnTheFrameThatAsked() {
        var heard = 0
        let listings = FolderListings(wait: .seconds(2))
        listings.onChange = { _ in heard += 1 }
        let listing = listings.listing(folder) { _ in .success([Self.entry("a")]) }
        #expect(names(listing) == ["a"])
        #expect(listings.isCurrent(folder))
        #expect(heard == 0)
    }

    @Test func aFolderReadingSlowlyComesLaterAndNeverBlocks() async {
        let gate = Gate(), listings = FolderListings(wait: .milliseconds(1))
        let began = Date()
        #expect(listings.listing(folder) { _ in gate.read([Self.entry("a")]) } == nil)
        #expect(Date().timeIntervalSince(began) < 1)
        #expect(!listings.isCurrent(folder))
        async let landed: Void = changes(of: listings)
        await Task.yield()
        gate.release()
        await landed
        #expect(names(listings.listing(folder) { _ in .success([]) }) == ["a"])
        #expect(listings.isCurrent(folder))
    }

    @Test func aFolderReadAgainKeepsWhatItShowedUntilTheNewReadLands() async {
        let gate = Gate(), listings = FolderListings(wait: .milliseconds(1))
        _ = listings.listing(folder) { _ in .success([Self.entry("old")]) }
        await waitUntilCurrent(listings)
        listings.refresh(folder)
        #expect(!listings.isCurrent(folder))
        #expect(names(listings.listing(folder) { _ in gate.read([Self.entry("new")]) }) == ["old"])
        async let landed: Void = changes(of: listings)
        await Task.yield()
        gate.release()
        await landed
        #expect(names(listings.listing(folder) { _ in .success([]) }) == ["new"])
    }

    @Test func changesDuringAReadComeToOneMoreRead() async {
        let gate = Gate(), listings = FolderListings(wait: .milliseconds(1))
        let read: @Sendable (@escaping @Sendable () -> Bool) -> FolderListing = { _ in gate.read() }
        _ = listings.listing(folder, read: read)
        while gate.reads == 0 { await Task.yield() }
        for _ in 0..<5 {
            listings.refresh(folder)
            _ = listings.listing(folder, read: read)
        }
        #expect(gate.reads == 1)
        async let first: Void = changes(of: listings)
        await Task.yield()
        gate.release()
        await first
        // Changed since that read began, so it is not up to date, and the next asking reads again.
        #expect(!listings.isCurrent(folder))
        _ = listings.listing(folder, read: read)
        while gate.reads == 1 { await Task.yield() }
        async let second: Void = changes(of: listings)
        await Task.yield()
        gate.release()
        await second
        #expect(listings.isCurrent(folder))
        #expect(gate.reads == 2)
    }

    @Test func aReadOfAFolderForgottenDoesNothing() async {
        let gate = Gate(), listings = FolderListings(wait: .milliseconds(1))
        var heard = 0
        listings.onChange = { _ in heard += 1 }
        _ = listings.listing(folder) { _ in gate.read([Self.entry("a")]) }
        listings.forget(folder)
        gate.release()
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(heard == 0)
        #expect(!listings.isCurrent(folder))
    }

    /// Moving through large folders, each left behind stops reading, so the one wanted isn't queued behind them.
    @Test func aReadOfAFolderLeftBehindIsToldToStop() async {
        let listings = FolderListings(wait: .milliseconds(1))
        let stopped = StopWatch()
        _ = listings.listing(folder) { isCancelled in
            while !isCancelled() { usleep(1000) }
            stopped.record(true)
            return .failure(CancellationError())
        }
        listings.keep([])
        for _ in 0..<2000 where stopped.value == nil { try? await Task.sleep(nanoseconds: 1_000_000) }
        #expect(stopped.value == true)
    }

    @Test func aReadOfAFolderKeptIsLeftToFinish() async {
        let gate = Gate(), listings = FolderListings(wait: .milliseconds(1))
        let stopped = StopWatch()
        _ = listings.listing(folder) { isCancelled in
            let listing = gate.read()
            stopped.record(isCancelled())
            return listing
        }
        listings.keep([folder])
        async let landed: Void = changes(of: listings)
        await Task.yield()
        gate.release()
        await landed
        #expect(stopped.value == false)
    }

    final class StopWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: Bool?
        var value: Bool? { lock.withLock { seen } }
        func record(_ value: Bool) { lock.withLock { seen = value } }
    }

    @Test func onlyWhatIsKeptStays() {
        let other = URL(fileURLWithPath: "/tmp/other/")
        let listings = FolderListings(wait: .seconds(2))
        _ = listings.listing(folder) { _ in .success([]) }
        _ = listings.listing(other) { _ in .success([]) }
        listings.keep([other])
        #expect(!listings.isCurrent(folder) && listings.isCurrent(other))
    }

    @Test func aFirstReadStillOutSaysSoAndALaterReadDoesNot() async {
        let gate = Gate(), listings = FolderListings(wait: .milliseconds(1), slowAfter: 0.01)
        _ = listings.listing(folder) { _ in gate.read() }
        #expect(!listings.isSlow(folder))
        await changes(of: listings)
        #expect(listings.isSlow(folder))
        async let landed: Void = changes(of: listings)
        await Task.yield()
        gate.release()
        await landed
        #expect(!listings.isSlow(folder))
        // Known already, so a column has something to show, and nothing to say.
        listings.refresh(folder)
        let again = Gate()
        _ = listings.listing(folder) { _ in again.read() }
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(!listings.isSlow(folder))
        again.release()
    }

    private func waitUntilCurrent(_ listings: FolderListings) async {
        while !listings.isCurrent(folder) { await Task.yield() }
    }
}
