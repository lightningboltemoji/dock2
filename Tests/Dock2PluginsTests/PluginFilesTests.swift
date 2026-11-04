import Darwin
import Dock2Core
@testable import Dock2Plugins
import Foundation
import Testing

/// The test guest's `files`, in a folder its folder setting holds: `notes/new.txt` written, appended, read,
/// listed and watched; `leak.txt` a link to a file outside.
@MainActor
@Suite(.serialized) struct PluginFilesTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-files-\(UUID().uuidString)", isDirectory: true)
    let id = TestHost.id

    func granted() throws -> String {
        let folder = directory.appendingPathComponent("granted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: directory.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("leak.txt").path,
                                                   withDestinationPath: directory.appendingPathComponent("outside.txt").path)
        guard let resolved = realpath(folder.path, nil) else { return folder.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func run(_ host: PluginHost, _ recorder: Recorder, _ command: String, until prefix: String) async throws {
        host.send(.command(id: command), to: id)
        try await TestHost.settle(until: { recorder.toasts.contains { $0.hasPrefix(prefix) } }, seconds: 3)
    }

    @Test func aPluginWritesReadsAndListsInsideItsFolder() async throws {
        let recorder = Recorder(), folder = try granted(), host = TestHost.make(recorder, in: directory, settings: ["folder": folder])
        try await run(host, recorder, "file-write", until: "wrote write")
        try await run(host, recorder, "file-append", until: "wrote append")
        try await run(host, recorder, "file-read", until: "read")
        #expect(recorder.toasts.contains("read 11: hello world"))
        try await run(host, recorder, "file-list", until: "listed")
        #expect(recorder.toasts.contains("listed leak.txt:link notes:folder"))
        try await run(host, recorder, "file-stat", until: "stat stat")
        try await run(host, recorder, "file-missing", until: "stat missing")
        #expect(recorder.toasts.contains("stat stat Some(\"folder\")") && recorder.toasts.contains("stat missing None"))
        // Written whole through a file beside it, which is gone after.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder + "/notes") == ["new.txt"])
    }

    @Test func aLinkOutOrAClimbIsRefused() async throws {
        let recorder = Recorder(), folder = try granted(), host = TestHost.make(recorder, in: directory, settings: ["folder": folder])
        try await run(host, recorder, "file-leak", until: "error")
        try await run(host, recorder, "file-climb", until: "error: \(folder)/notes/..")
        #expect(recorder.toasts.contains("error: \(folder)/leak.txt: \(folder)/leak.txt is not inside a folder it was granted"))
        #expect(!recorder.toasts.contains { $0.contains("secret") })
    }

    /// Without a folder chosen there is nothing it may reach.
    @Test func noFolderChosenReachesNothing() async throws {
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory)
        try await run(host, recorder, "file-read", until: "error")
        #expect(recorder.toasts.contains { $0.hasSuffix("no folder is chosen for it in Settings → Plugins") })
    }

    /// A watch hears what changes, until the folder setting moves elsewhere or `files` is revoked.
    @Test func aWatchHearsChangesUntilItsFolderGoes() async throws {
        let recorder = Recorder(), folder = try granted(), host = TestHost.make(recorder, in: directory, settings: ["folder": folder])
        host.send(.command(id: "watch"), to: id)
        try await TestHost.settle(until: { !host.resources.keys(.watch, of: id).isEmpty }, seconds: 3)
        try Data("x".utf8).write(to: URL(fileURLWithPath: folder + "/touched.txt"))
        try await TestHost.settle(until: { recorder.toasts.contains { $0.hasPrefix("changed") } }, seconds: 5)
        #expect(recorder.toasts.contains { $0.hasPrefix("changed") && $0.contains("touched.txt") })
        // The setting now holds another folder: the watch on the old one ends.
        let elsewhere = directory.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        host.setSetting(id, "folder", elsewhere.path)
        #expect(host.resources.keys(.watch, of: id).isEmpty)
    }

    /// Counted while they resolve: a batch past the limit is refused past it.
    @Test func watchesAreCountedBeforeTheyResolve() async throws {
        let recorder = Recorder(), folder = try granted(), host = TestHost.make(recorder, in: directory, settings: ["folder": folder])
        host.perform((0...PluginHost.watchLimit).map { .watch(id: "w\($0)", path: folder) }, from: id, answering: .command(id: "c"))
        #expect(host.resources.keys(.watch, of: id).count == PluginHost.watchLimit)
        try await TestHost.settle(until: { toast(recorder) }, seconds: 3)
        #expect(recorder.toasts.contains("error: it watches \(PluginHost.watchLimit) folders already"))
    }

    func toast(_ recorder: Recorder) -> Bool { recorder.toasts.contains { $0.hasPrefix("error") } }

    @Test func revokingFilesEndsTheWatch() async throws {
        let recorder = Recorder(), folder = try granted(), host = TestHost.make(recorder, in: directory, settings: ["folder": folder])
        host.send(.command(id: "watch"), to: id)
        try await TestHost.settle(until: { !host.resources.keys(.watch, of: id).isEmpty }, seconds: 3)
        host.setGranted(id, .files, false)
        #expect(host.resources.keys(.watch, of: id).isEmpty)
    }

    /// Past what one read carries, the plugin is told the size and reads the rest by range.
    @Test func aReadIsCappedAndSaysTheWholeSize() throws {
        let file = directory.appendingPathComponent("big.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: PluginFiles.readLimit + 10).write(to: file)
        let (data, size) = try PluginFiles.read(file.path, offset: 0, length: nil)
        #expect(data.count == PluginFiles.readLimit && size == PluginFiles.readLimit + 10)
        #expect(try PluginFiles.read(file.path, offset: PluginFiles.readLimit, length: 100).data.count == 10)
    }
}

/// What one plugin's files can do to every plugin's queue.
@Suite struct PluginFilesQueueTests {
    /// A FIFO waits for a writer that never comes: refused at once, rather than holding every plugin's files.
    @Test func aFIFOIsNotWaitedOn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-fifo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fifo = folder.appendingPathComponent("pipe").path
        #expect(mkfifo(fifo, 0o644) == 0)
        #expect(throws: PluginFailure("not a file")) { try PluginFiles.read(fifo, offset: 0, length: nil) }
        #expect(throws: PluginFailure.self) { try PluginFiles.write(Data("x".utf8), to: fifo, append: true) }
    }
}
