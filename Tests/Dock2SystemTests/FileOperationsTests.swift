@testable import Dock2System
import Foundation
import Testing

/// Against a folder of their own in the temporary directory, with a Trash of their own too.
@MainActor
@Suite struct FileOperationsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-files-\(UUID().uuidString)", isDirectory: true)
    var trash: URL { root.appendingPathComponent("Trash", isDirectory: true) }

    init() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Trash"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: root.appendingPathComponent("a/one.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/folder/inner"), withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: root.appendingPathComponent("a/folder/inner/deep.txt"))
    }

    func operations() -> FileOperations {
        let trash = self.trash
        return FileOperations(trashing: { url in
            let target = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
    }

    func names(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)) ?? []).sorted()
    }

    func text(_ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Runs one operation and waits for what it made.
    func wait(_ start: (@escaping @MainActor ([URL]) -> Void) -> Void) async -> [URL] {
        await withCheckedContinuation { continuation in start { continuation.resume(returning: $0) } }
    }

    @Test func copiesFilesAndFoldersWholeLeavingNoPartials() async {
        let ops = operations()
        let made = await wait { ops.copy([root.appendingPathComponent("a/one.txt"), root.appendingPathComponent("a/folder")],
                                         to: root.appendingPathComponent("b"), done: $0) }
        #expect(made.map(\.lastPathComponent) == ["one.txt", "folder"])
        #expect(names("b") == ["folder", "one.txt"])
        #expect(text("b/folder/inner/deep.txt") == "deep")
        #expect(names("a") == ["folder", "one.txt"])
        #expect(ops.canUndo && ops.jobs.isEmpty)
    }

    @Test func aTakenNameIsAskedAbout() async throws {
        let ops = operations()
        try Data("other".utf8).write(to: root.appendingPathComponent("b/one.txt"))
        var asked: [String] = []
        let source = root.appendingPathComponent("a/one.txt"), folder = root.appendingPathComponent("b")

        var answer = ConflictAnswer(.keepBoth)
        ops.ask = { question, reply in
            asked.append(question.existing.lastPathComponent)
            reply(answer)
        }
        _ = await wait { ops.copy([source], to: folder, done: $0) }
        #expect(names("b") == ["one 2.txt", "one.txt"] && text("b/one.txt") == "other")

        answer = ConflictAnswer(.skip)
        let skipped = await wait { ops.copy([source], to: folder, done: $0) }
        #expect(skipped.isEmpty && text("b/one.txt") == "other")

        answer = ConflictAnswer(.replace)
        _ = await wait { ops.copy([source], to: folder, done: $0) }
        #expect(text("b/one.txt") == "one" && names("b") == ["one 2.txt", "one.txt"])
        #expect(asked == ["one.txt", "one.txt", "one.txt"])
    }

    @Test func movesAndUndoesThemAndRedoes() async {
        let ops = operations()
        let one = root.appendingPathComponent("a/one.txt")
        _ = await wait { ops.move([one], to: root.appendingPathComponent("b"), done: $0) }
        #expect(names("a") == ["folder"] && names("b") == ["one.txt"])
        let back = await wait { ops.undo(done: $0) }
        #expect(back.map(\.path) == [one.path] && names("b").isEmpty)
        #expect(ops.canRedo)
        _ = await wait { ops.redo(done: $0) }
        #expect(names("b") == ["one.txt"])
        // Moving an item where it already is, or into itself, does nothing.
        let none = await wait { ops.move([root.appendingPathComponent("a/folder")], to: root.appendingPathComponent("a/folder/inner"), done: $0) }
        #expect(none.isEmpty && names("a") == ["folder"])
    }

    @Test func duplicatesTrashesAndPutsBack() async throws {
        let ops = operations()
        let one = root.appendingPathComponent("a/one.txt")
        let copies = await wait { ops.duplicate([one, one], done: $0) }
        #expect(copies.map(\.lastPathComponent) == ["one copy.txt", "one copy 2.txt"])
        _ = await wait { ops.trash([one], done: $0) }
        #expect(!FileManager.default.fileExists(atPath: one.path) && names("Trash").count == 1)
        _ = await wait { ops.undo(done: $0) }
        #expect(FileManager.default.fileExists(atPath: one.path) && names("Trash").isEmpty)
        // Undoing the duplicate trashes its copies.
        _ = await wait { ops.undo(done: $0) }
        #expect(names("a") == ["folder", "one.txt"] && names("Trash").count == 2)
    }

    @Test func newFoldersAndRenames() async throws {
        let ops = operations()
        let first = try ops.newFolder(in: root.appendingPathComponent("b"))
        let second = try ops.newFolder(in: root.appendingPathComponent("b"))
        #expect([first, second].map(\.lastPathComponent) == ["untitled folder", "untitled folder 2"])
        let renamed = try ops.rename(second, to: "Photos")
        #expect(names("b") == ["Photos", "untitled folder"])
        #expect(throws: (any Error).self) { try ops.rename(renamed, to: "untitled folder") }
        #expect(throws: (any Error).self) { try ops.rename(renamed, to: "a/b") }
        // A change of case alone is allowed.
        _ = try ops.rename(renamed, to: "photos")
        _ = await wait { ops.undo(done: $0) }
        _ = await wait { ops.undo(done: $0) }
        #expect(names("b") == ["untitled folder", "untitled folder 2"])
        // A new folder is undone only while it is empty.
        _ = await wait { ops.undo(done: $0) }
        #expect(names("b") == ["untitled folder"])
        try Data().write(to: first.appendingPathComponent("x"))
        var error: String?
        ops.onError = { error = $0.message }
        _ = await wait { ops.undo(done: $0) }
        #expect(names("b") == ["untitled folder"] && error?.contains("no longer empty") == true)
    }

    /// What a Replace put aside goes to the Trash, so undo brings it back, and redo puts it aside again.
    @Test func replacingIsUndoneWithWhatWasReplaced() async throws {
        let ops = operations()
        try Data("other".utf8).write(to: root.appendingPathComponent("b/one.txt"))
        ops.ask = { _, reply in reply(ConflictAnswer(.replace)) }
        _ = await wait { ops.copy([root.appendingPathComponent("a/one.txt")], to: root.appendingPathComponent("b"), done: $0) }
        #expect(text("b/one.txt") == "one" && names("Trash").count == 1)
        _ = await wait { ops.undo(done: $0) }
        #expect(text("b/one.txt") == "other")
        _ = await wait { ops.redo(done: $0) }
        #expect(text("b/one.txt") == "one")
        _ = await wait { ops.undo(done: $0) }
        #expect(text("b/one.txt") == "other" && text("a/one.txt") == "one")

        // A move that replaces, the same.
        _ = await wait { ops.move([root.appendingPathComponent("a/one.txt")], to: root.appendingPathComponent("b"), done: $0) }
        #expect(text("b/one.txt") == "one" && names("a") == ["folder"])
        _ = await wait { ops.undo(done: $0) }
        #expect(text("b/one.txt") == "other" && text("a/one.txt") == "one")
    }

    /// A file that cannot be read fails the copy, leaving nothing — and a move across volumes, which is a
    /// copy first, keeps its source.
    @Test func aFileThatCannotBeReadFailsTheCopyWhole() async throws {
        let ops = operations()
        let locked = root.appendingPathComponent("a/folder/inner/locked.txt")
        try Data("secret".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        var error: String?
        ops.onError = { error = $0.message }
        var problem: FileProblem?
        ops.onError = { problem = $0; error = $0.message }
        let made = await wait { ops.copy([root.appendingPathComponent("a/folder")], to: root.appendingPathComponent("b"), done: $0) }
        #expect(made.isEmpty && error?.contains("locked.txt") == true)
        // On the row of what was being copied; a file's own permissions are Finder's to change, not access to grant.
        #expect(problem?.item == root.appendingPathComponent("a/folder").canonical && problem?.remedy == .openInFinder)
        #expect(names("b").isEmpty)
        #expect(throws: (any Error).self) { _ = try Worker.unhurried.copy(root.appendingPathComponent("a/folder"), to: root.appendingPathComponent("b/folder")) }
        #expect(names("b").isEmpty)
    }

    /// Where it already is: a move does nothing and asks nothing; a copy is a duplicate.
    @Test func intoItsOwnFolder() async {
        let ops = operations()
        var asked = 0
        ops.ask = { _, reply in asked += 1; reply(ConflictAnswer(.skip)) }
        let moved = await wait { ops.move([root.appendingPathComponent("a/one.txt")], to: root.appendingPathComponent("a"), done: $0) }
        #expect(moved.isEmpty && names("a") == ["folder", "one.txt"])
        let copied = await wait { ops.copy([root.appendingPathComponent("a/one.txt")], to: root.appendingPathComponent("a/"), done: $0) }
        #expect(copied.map(\.lastPathComponent) == ["one copy.txt"] && asked == 0)
    }

    /// A batch that fails partway is still undone as far as it got.
    @Test func whatABatchDidBeforeItFailedIsUndone() async {
        let ops = operations()
        var error: String?
        ops.onError = { error = $0.message }
        let made = await wait { ops.move([root.appendingPathComponent("a/one.txt"), root.appendingPathComponent("a/missing.txt")],
                                         to: root.appendingPathComponent("b"), done: $0) }
        #expect(error != nil && made.map(\.lastPathComponent) == ["one.txt"] && names("b") == ["one.txt"])
        _ = await wait { ops.undo(done: $0) }
        #expect(names("a") == ["folder", "one.txt"] && names("b").isEmpty)
    }

    /// A folder cannot be replaced by something inside it.
    @Test func aFolderIsNotReplacedByWhatItHolds() async throws {
        let ops = operations()
        let inner = root.appendingPathComponent("a/folder/inner")
        try FileManager.default.createDirectory(at: inner.appendingPathComponent("folder"), withIntermediateDirectories: true)
        ops.ask = { _, reply in reply(ConflictAnswer(.replace)) }
        var error: String?
        ops.onError = { error = $0.message }
        _ = await wait { ops.move([inner.appendingPathComponent("folder")], to: root.appendingPathComponent("a"), done: $0) }
        #expect(error?.contains("holds") == true && names("a/folder/inner") == ["deep.txt", "folder"] && names("Trash").isEmpty)
    }

    /// A privacy denial is EPERM, which Full Disk Access answers; a file's own permissions are EACCES.
    @Test func whatAProblemOffersToDo() {
        let item = URL(fileURLWithPath: "/x/y")
        let denied = CocoaError(.fileReadNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM) as NSError])
        #expect(FileProblem(denied, item: item, hasFullDiskAccess: false).remedy == .allowAccess)
        #expect(FileProblem(denied, item: item, hasFullDiskAccess: true).remedy == .openInFinder)
        #expect(FileProblem(POSIXError(.EACCES), hasFullDiskAccess: false).remedy == .openInFinder)
        #expect(FileProblem(CocoaError(.fileReadNoSuchFile), item: item).remedy == .none)
        #expect(FileProblem(ItemError(item: item, error: POSIXError(.EPERM)), hasFullDiskAccess: false).item == item)
        // A locked file refuses with EPERM as well: Finder unlocks it, Full Disk Access would not.
        let locked = root.appendingPathComponent("a/one.txt")
        try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        let problem = FileProblem(POSIXError(.EPERM), item: locked, hasFullDiskAccess: false)
        #expect(problem.remedy == .openInFinder && problem.message == "“one.txt” is locked.")
    }

    /// Across volumes, a move is a copy and then a removal: given a folder on another volume, a failed copy
    /// keeps its source, a whole one removes it, and undo brings it back.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DOCK2_SECOND_VOLUME"] != nil))
    func aMoveAcrossVolumes() async throws {
        let other = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOCK2_SECOND_VOLUME"]!)
            .appendingPathComponent("dock2-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(!Worker.sameVolume(root, other))
        let ops = operations()
        let folder = root.appendingPathComponent("a/folder")
        let locked = folder.appendingPathComponent("inner/locked.txt")
        try Data("secret".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        var error: String?
        ops.onError = { error = $0.message }
        let failed = await wait { ops.move([folder], to: other, done: $0) }
        #expect(failed.isEmpty && error?.contains("locked.txt") == true)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("inner/deep.txt").path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: other.path))?.isEmpty == true)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        let moved = await wait { ops.move([folder], to: other, done: $0) }
        #expect(moved.map(\.lastPathComponent) == ["folder"] && !FileManager.default.fileExists(atPath: folder.path))
        #expect((try? String(contentsOf: other.appendingPathComponent("folder/inner/deep.txt"), encoding: .utf8)) == "deep")
        _ = await wait { ops.undo(done: $0) }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("inner/locked.txt").path))
        #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent("folder").path))
    }

    @Test func aCancelledJobLeavesNothing() async {
        let ops = operations()
        ops.copy([root.appendingPathComponent("a/folder")], to: root.appendingPathComponent("b"))
        ops.cancel()
        _ = await wait { ops.copy([], to: root.appendingPathComponent("b"), done: $0) }
        #expect(names("b").isEmpty)
    }

    @Test func listingIsFinderOrderWithPackagesAsFiles() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/Tool.app/Contents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a/link"), withDestinationURL: root.appendingPathComponent("b"))
        try Data().write(to: root.appendingPathComponent("a/.hidden"))
        let entries = try DirectoryListing.list(root.appendingPathComponent("a"), showsHidden: false) { _ in false }
        #expect(entries.map(\.name) == ["folder", "link", "one.txt", "Tool.app"] || entries.map(\.name) == ["folder", "link", "one.txt", "Tool"])
        #expect(entries.first { $0.url.lastPathComponent == "Tool.app" }?.isFolder == false)
        #expect(entries.first { $0.url.lastPathComponent == "link" }?.isFolder == true)
        #expect(try DirectoryListing.list(root.appendingPathComponent("a"), showsHidden: true) { _ in false }.contains { $0.name == ".hidden" })
    }
}

extension Worker {
    /// A worker for one call: never cancelled, asking nothing.
    static var unhurried: Worker {
        Worker(progress: Progress(totalUnitCount: 1), asker: { _, reply in reply(ConflictAnswer(.skip)) }, changed: {})
    }
}
