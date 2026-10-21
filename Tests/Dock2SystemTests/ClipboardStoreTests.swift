import AppKit
import CryptoKit
import Dock2Core
@testable import Dock2System
import Foundation
import Testing

@MainActor
@Suite struct ClipboardStoreTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-clip-\(UUID().uuidString)", isDirectory: true)

    func store() -> ClipboardStore {
        ClipboardStore(directory: directory, keys: FileKeyStore(url: directory.appendingPathComponent("clipboard.key")))
    }

    @Test func theHistoryAndItsDataComeBackAndAreSealedOnDisk() async throws {
        var history = ClipHistory()
        let entry = ClipEntry(kind: .text, title: "secret words", digest: "d", date: Date(timeIntervalSince1970: 1_000),
                              types: ["public.utf8-plain-text"], size: 12)
        history.insert(entry)
        let first = store()
        first.save(history)
        first.save(["public.utf8-plain-text": Data("secret words".utf8)], for: entry.id)
        // One store's queue keeps its writes and reads in order; a second store then reads what it wrote.
        _ = await withCheckedContinuation { continuation in first.load { continuation.resume(returning: $0) } }
        let second = store()
        let loaded = await withCheckedContinuation { continuation in second.load { continuation.resume(returning: $0) } }
        #expect((try? loaded.get()) == history)
        // Data is read once the history is open, with the key it opened with: never a Keychain wait.
        #expect(second.data(for: entry.id)?["public.utf8-plain-text"] == Data("secret words".utf8))
        #expect(store().data(for: entry.id) == nil)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("secret"))
        }
        let key = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("clipboard.key").path)
        #expect((key[.posixPermissions] as? Int) == 0o600)
    }

    @Test func aWrongKeyOpensNothing() async throws {
        let first = store()
        first.save(ClipHistory(entries: [ClipEntry(kind: .text, title: "x", digest: "x", date: Date(), types: [], size: 1)]))
        _ = await withCheckedContinuation { continuation in first.load { continuation.resume(returning: $0) } }
        try Data(repeating: 7, count: 32).write(to: directory.appendingPathComponent("clipboard.key"))
        let loaded = await withCheckedContinuation { continuation in store().load { continuation.resume(returning: $0) } }
        // Opened with another key: a fresh history, the old one set aside rather than written over.
        #expect((try? loaded.get())?.entries.isEmpty == true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains("index.sealed") && names.contains { $0.hasPrefix("index-unreadable-") })
    }

    /// A key the Keychain withholds for now is no answer: the store says so, and opens once the key comes.
    @Test func aKeyWithheldIsReportedNotTakenForAnEmptyHistory() async throws {
        let first = store()
        first.save(ClipHistory(entries: [ClipEntry(kind: .text, title: "kept", digest: "k", date: Date(), types: [], size: 1)]))
        _ = await withCheckedContinuation { continuation in first.load { continuation.resume(returning: $0) } }
        let keys = WithheldKeyStore(file: FileKeyStore(url: directory.appendingPathComponent("clipboard.key")))
        let locked = ClipboardStore(directory: directory, keys: keys)
        let refused = await withCheckedContinuation { continuation in locked.load { continuation.resume(returning: $0) } }
        guard case .failure = refused else { Issue.record("an empty history in place of a refusal"); return }
        keys.withheld = false
        let opened = await withCheckedContinuation { continuation in locked.load { continuation.resume(returning: $0) } }
        #expect((try? opened.get())?.entries.map(\.title) == ["kept"])
    }

    /// What is on the clipboard as the watcher starts is not kept: who copied it is not known.
    @Test func theWatcherKeepsNothingCopiedBeforeItStarted() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("copied before", forType: .string)
        let watcher = PasteboardWatcher(pasteboard: pasteboard)
        var captured: [String] = []
        watcher.onCapture = { captured.append($0.entry.title) }
        watcher.start()
        defer { watcher.stop() }
        watcher.check()
        #expect(captured.isEmpty)
    }

    /// The source marker says who copied: what dock2 copies for the user is dock2's, another app's copy that app's.
    @Test func theSourceMarkerSaysWhoCopied() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let watcher = PasteboardWatcher(pasteboard: pasteboard)
        watcher.ignoredApps = { ["com.example.vault"] }
        var captured: [ClipCapture] = []
        watcher.onCapture = { captured.append($0) }
        watcher.start()
        defer { watcher.stop() }
        OwnWrite.write(to: pasteboard) { $0.setString("/Users/me/notes.txt", forType: .string) }
        watcher.check()
        #expect(captured.map(\.entry.sourceName) == ["dock2"])
        for source in ["com.example.editor", "com.example.vault"] {
            let item = NSPasteboardItem()
            item.setString("from \(source)", forType: .string)
            item.setString(source, forType: OwnWrite.sourceType)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            watcher.check()
        }
        #expect(captured.map(\.entry.sourceApp) == [Dock2Identity.bundleIdentifier, "com.example.editor"])
    }

    @Test func theWatcherKeepsCopiesButNotItsOwnWritesNorConcealedOnes() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let watcher = PasteboardWatcher(pasteboard: pasteboard)
        var captured: [ClipCapture] = []
        watcher.onCapture = { captured.append($0) }
        watcher.start()
        defer { watcher.stop() }

        pasteboard.clearContents()
        pasteboard.setString("Hello from a test\nsecond line", forType: .string)
        watcher.check()
        #expect(captured.map(\.entry.title) == ["Hello from a test"] && captured[0].entry.kind == .text)

        let count = Paster.write(captured[0].entry, data: captured[0].data, to: pasteboard)
        watcher.wrote(changeCount: count)
        watcher.check()
        #expect(captured.count == 1)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("hunter2", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])
        watcher.check()
        #expect(captured.count == 1)

        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL, URL(fileURLWithPath: "/tmp/b.txt") as NSURL])
        watcher.check()
        #expect(captured.last?.entry.kind == .files && captured.last?.entry.files == ["/tmp/a.txt", "/tmp/b.txt"])
    }
}

@MainActor
@Suite struct ClipImageTests {
    /// macOS hands an image over as an uncompressed TIFF, many megabytes: kept as a PNG, it is under the cap.
    @Test func aCopiedPictureIsKeptCompact() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let watcher = PasteboardWatcher(pasteboard: pasteboard)
        var captured: [ClipCapture] = []
        watcher.onCapture = { captured.append($0) }
        watcher.start()
        defer { watcher.stop() }
        let image = NSImage(size: NSSize(width: 600, height: 400), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        watcher.check()
        // Made compact off the main thread, then handed back.
        for _ in 0..<100 where captured.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let capture = try #require(captured.first)
        #expect(capture.entry.kind == .image && Array(capture.data.keys) == ["public.png"])
        #expect(capture.entry.size < 1_000_000 && capture.entry.thumbnail != nil)
    }
}

@Suite struct ClipThumbnailTests {
    @Test func aCopiedImageGetsASmallThumbnail() throws {
        let image = NSImage(size: NSSize(width: 800, height: 400), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let thumbnail = try #require(PasteboardWatcher.thumbnail(["public.png": png]))
        let rep = try #require(NSBitmapImageRep(data: thumbnail))
        #expect(max(rep.pixelsWide, rep.pixelsHigh) == 72 && thumbnail.count < png.count)
        #expect(PasteboardWatcher.thumbnail(["public.utf8-plain-text": Data("hi".utf8)]) == nil)
    }
}

/// A key store the Keychain is refusing, until told otherwise.
final class WithheldKeyStore: KeyStore, @unchecked Sendable {
    let file: FileKeyStore
    var withheld = true
    init(file: FileKeyStore) { self.file = file }
    func key() throws -> SymmetricKey {
        if withheld { throw NSError(domain: NSOSStatusErrorDomain, code: -25308) }
        return try file.key()
    }
}
