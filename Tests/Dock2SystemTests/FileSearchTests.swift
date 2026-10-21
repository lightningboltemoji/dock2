import Dock2Core
@testable import Dock2System
import Foundation
import Testing

@Suite struct FileSearchTests {
    /// ⌘F's walk passes over a folder it is told is closed: looking inside would raise macOS's prompt.
    @Test func theWalkPassesOverAClosedFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-walk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["open", "locked"] {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("quokka.txt"))
        }
        let hits = await withCheckedContinuation { continuation in
            _ = FileSearch().search(Query("quokka"), within: root.path, showsHidden: false,
                                    closed: { $0.lastPathComponent == "locked" }) { continuation.resume(returning: $0) }
        }
        #expect(hits.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent } == ["open"])
    }
}

@Suite struct FileAccessTests {
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// By spelling, a protected folder is one in another case and by the Data volume; through a symbolic link,
    /// where the link leads — read from the link alone — is.
    @Test func aProtectedFolderIsOneHoweverItIsReached() throws {
        #expect(FileAccess.asks(URL(fileURLWithPath: home + "/documents/notes", isDirectory: true), choice: .declined))
        #expect(FileAccess.asks(URL(fileURLWithPath: "/System/Volumes/Data" + home + "/Documents", isDirectory: true), choice: .declined))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("notes").path, withDestinationPath: home + "/Documents/Notes")
        let reached = FileAccess.reached(root.appendingPathComponent("notes/inner").path, choice: .declined)
        #expect(reached == home + "/Documents/Notes/inner")
        #expect(FileAccess.asks(URL(fileURLWithPath: reached, isDirectory: true), choice: .declined))
        #expect(!FileAccess.asks(root, choice: .declined) && !FileAccess.asks(URL(fileURLWithPath: home + "/Music"), choice: .declined))
        // A link to a link, and a relative one through it, its `..` the parent of where the link leads.
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("docs").path, withDestinationPath: home + "/Documents")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("proj").path, withDestinationPath: root.path + "/docs/proj")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("up").path, withDestinationPath: "docs/../Documents/y")
        #expect(FileAccess.reached(root.appendingPathComponent("proj").path, choice: .declined) == home + "/Documents/proj")
        #expect(FileAccess.reached(root.appendingPathComponent("up").path, choice: .declined) == home + "/Documents/y")
    }
}
