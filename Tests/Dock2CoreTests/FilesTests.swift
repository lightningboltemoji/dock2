import Dock2Core
import Foundation
import Testing

@Suite struct FileNamingTests {
    @Test func finderOrderPutsFoldersFirstAndNumbersByValue() {
        let items = [("b", false), ("File 10", false), ("file 9", false), ("Zeta", true), ("alpha", true), ("Écran", false)]
        let sorted = FinderOrder.sorted(items, name: \.0, isFolder: \.1).map(\.0)
        #expect(sorted == ["alpha", "Zeta", "b", "Écran", "file 9", "File 10"])
    }

    @Test func duplicatesAreNamedAsFinderNamesThem() {
        var taken: Set<String> = ["report.pdf"]
        let first = CopyNaming.duplicate("report.pdf", isFolder: false, taken: taken.contains)
        #expect(first == "report copy.pdf")
        taken.insert(first)
        #expect(CopyNaming.duplicate("report.pdf", isFolder: false, taken: taken.contains) == "report copy 2.pdf")
        // A copy's copy counts on from it.
        #expect(CopyNaming.duplicate("report copy.pdf", isFolder: false, taken: taken.contains) == "report copy 2.pdf")
        #expect(CopyNaming.duplicate("report copy 7.pdf", isFolder: false, taken: taken.contains) == "report copy 8.pdf")
        // A folder has no extension; a dot-file's name is all base; a "extension" with a space is none.
        #expect(CopyNaming.duplicate("v1.2", isFolder: true, taken: { _ in false }) == "v1.2 copy")
        #expect(CopyNaming.duplicate(".zshrc", isFolder: false, taken: { _ in false }) == ".zshrc copy")
        #expect(CopyNaming.duplicate("Notes.final draft", isFolder: false, taken: { _ in false }) == "Notes.final draft copy")
        #expect(CopyNaming.duplicate("a.tar.gz", isFolder: false, taken: { _ in false }) == "a.tar copy.gz")
    }

    @Test func keepBothNumbersTheNewcomer() {
        let taken: Set<String> = ["photo.jpg", "photo 2.jpg"]
        #expect(CopyNaming.keepBoth("photo.jpg", isFolder: false, taken: taken.contains) == "photo 3.jpg")
        #expect(CopyNaming.keepBoth("Project 4", isFolder: true, taken: { _ in false }) == "Project 5")
        #expect(CopyNaming.newFolder(taken: { _ in false }) == "untitled folder")
        #expect(CopyNaming.newFolder(taken: { $0 == "untitled folder" }) == "untitled folder 2")
    }

    @Test func pathsSplitExpandAndComplete() {
        let home = "/Users/me"
        #expect(PathInput.isPath("~/x") && PathInput.isPath("/") && !PathInput.isPath("x/y"))
        #expect(PathInput.expand("~", home: home) == home && PathInput.expand("~/Dev", home: home) == "/Users/me/Dev")
        #expect(PathInput.split("~/Dev/do", home: home) == ("/Users/me/Dev", "do"))
        #expect(PathInput.split("/App", home: home) == ("/", "App"))
        #expect(PathInput.split("~/", home: home) == ("/Users/me", ""))

        let entries = [("Developer", true), ("Desktop", true), ("Documents", true), ("dev.txt", false), (".devrc", false)]
        #expect(PathInput.complete("~/deve", entries: entries) == "~/Developer/")
        // Case ignored: "Dev" begins dev.txt too.
        #expect(PathInput.complete("~/Dev", entries: entries) == "~/Dev")
        #expect(PathInput.complete("~/de", entries: entries) == "~/De")
        #expect(PathInput.complete("~/des", entries: entries) == "~/Desktop/")
        #expect(PathInput.complete("~/dev.", entries: entries) == "~/dev.txt")
        #expect(PathInput.complete("~/.d", entries: entries) == "~/.devrc")
        #expect(PathInput.complete("~/zz", entries: entries) == "~/zz")
        #expect(PathInput.complete("~", entries: entries) == "~/")
    }
}

@Suite struct FilesStateTests {
    let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func goingSomewhereShowsTheChainFromItsRoot() {
        var state = FilesState(home: home)
        state.go(to: url("/Users/me/Developer/dock2"), root: home, selecting: [url("/Users/me/Developer/dock2/Package.swift")])
        #expect(state.tab.columns.map(\.folder.path) == ["/Users/me", "/Users/me/Developer", "/Users/me/Developer/dock2"])
        #expect(state.tab.columns.map { $0.selection.map(\.lastPathComponent) } == [["Developer"], ["dock2"], ["Package.swift"]])
        #expect(state.tab.focus == 2 && state.tab.folder.lastPathComponent == "dock2")
        // Outside the root, the folder stands alone.
        state.go(to: url("/Volumes/Backup"), root: home)
        #expect(state.tab.columns.map(\.folder.path) == ["/Volumes/Backup"])
    }

    @Test func selectingAFolderOpensItAndTheArrowsWalkTheColumns() {
        var state = FilesState(home: home)
        state.select([url("/Users/me/Music")], in: 0, opens: true)
        #expect(state.tab.columns.count == 2 && state.tab.focus == 0)
        let entered = state.enter()
        #expect(entered && state.tab.focus == 1)
        let enteredAgain = state.enter()
        #expect(!enteredAgain)
        state.select([url("/Users/me/Music/a.mp3")], in: 1, opens: false)
        let left = state.leave()
        #expect(left)
        // The column left stays open, nothing selected in it.
        #expect(state.tab.focus == 0 && state.tab.columns.count == 2 && state.tab.columns[1].selection.isEmpty)
        let leftAgain = state.leave()
        #expect(!leftAgain)
        // Selecting another item closes what was open past it.
        state.select([url("/Users/me/notes.txt")], in: 0, opens: false)
        #expect(state.tab.columns.count == 1)
    }

    @Test func enclosingAddsTheParentBeforeTheFirstColumn() {
        var state = FilesState(home: home)
        state.enclosing(parent: url("/Users"))
        #expect(state.tab.columns.map(\.folder.path) == ["/Users", "/Users/me"])
        #expect(state.tab.focus == 0 && state.tab.selection == [home.canonical])
        state.go(to: url("/"), root: url("/"))
        state.enclosing(parent: url("/"))
        #expect(state.tab.columns.count == 1)
    }

    @Test func aTabIsAtTheLastFolderItHasOpen() {
        var state = FilesState(home: home)
        #expect(state.tab.deepest == home.canonical)
        state.go(to: url("/Users/me/a"), root: home)
        // A folder selected opens beside it, and the keys stay behind.
        state.select([url("/Users/me/a/b")], in: 1, opens: true)
        #expect(state.tab.folder.lastPathComponent == "a" && state.tab.deepest.lastPathComponent == "b")
        // A file selected, or several things, open nothing.
        state.select([url("/Users/me/a/note.txt")], in: 1, opens: false)
        #expect(state.tab.deepest.lastPathComponent == "a")
        state.select([url("/Users/me/a/b"), url("/Users/me/a/c")], in: 1, opens: true)
        #expect(state.tab.deepest.lastPathComponent == "a")
        // ← leaves the folder it came from open, and selected.
        state.select([url("/Users/me/a/b")], in: 1, opens: true)
        state.enter()
        state.leave()
        #expect(state.tab.folder.lastPathComponent == "a" && state.tab.deepest.lastPathComponent == "b")
    }

    @Test func tabs() {
        var state = FilesState(home: home)
        let closedOnly = state.closeTab()
        #expect(!closedOnly)
        state.go(to: url("/Users/me/Desktop"), root: home)
        state.newTab(at: home)
        #expect(state.tabs.count == 2 && state.current == 1 && state.tab.folder == home.canonical)
        state.go(to: url("/Users/me/Downloads"), root: home)
        // A new tab goes beside the one showing.
        state.show(tab: 0)
        state.newTab(at: home)
        #expect(state.tabs.map(\.folder.lastPathComponent) == ["Desktop", "me", "Downloads"] && state.current == 1)
        state.cycleTab(by: 1)
        #expect(state.current == 2)
        state.cycleTab(by: 1)
        #expect(state.current == 0)
        state.cycleTab(by: -1)
        #expect(state.current == 2)
        // Closing the last tab shows the one before it; closing one before the current keeps the current.
        let closedLast = state.closeTab()
        #expect(closedLast && state.current == 1 && state.tab.folder.lastPathComponent == "me")
        let closedFirst = state.closeTab(0)
        #expect(closedFirst && state.tabs.count == 1 && state.current == 0 && state.tab.folder.lastPathComponent == "me")
        while state.newTab(at: home) {}
        #expect(state.tabs.count == FilesState.maximumTabs)
    }

    @Test func everyURLHasOneSpelling() {
        var state = FilesState(home: home)
        state.select([URL(fileURLWithPath: "/Users/me/Music/", isDirectory: true)], in: 0, opens: true)
        #expect(state.tab.selection == [url("/Users/me/Music").canonical])
        #expect(url("/Users/me/./Music/").canonical == URL(fileURLWithPath: "/Users/me/Music", isDirectory: false))
    }

    @Test func renamesAndRemovalsFollowTheDisk() {
        var state = FilesState(home: home)
        state.go(to: url("/Users/me/Developer/dock2/Sources"), root: home, selecting: [url("/Users/me/Developer/dock2/Sources/a.swift")])
        state.moved(url("/Users/me/Developer/dock2"), to: url("/Users/me/Developer/dock3"))
        #expect(state.tab.columns.map(\.folder.lastPathComponent) == ["me", "Developer", "dock3", "Sources"])
        #expect(state.tab.selection.map(\.path) == ["/Users/me/Developer/dock3/Sources/a.swift"])
        state.removed([url("/Users/me/Developer/dock3")])
        #expect(state.tab.columns.map(\.folder.lastPathComponent) == ["me", "Developer"])
        #expect(state.tab.focus == 1 && state.tab.selection.isEmpty)
        state.removed([home])
        #expect(state.tab.columns.map(\.folder.path) == ["/Users"])
    }
    @Test func aShareMountsBeneathItsServer() {
        let server = URL(string: "smb://Synology._smb._tcp.local")!
        let share = URL(string: "smb://Synology._smb._tcp.local/home")!
        // A URL that is not a file's keeps its spelling, and is not the folder of its path on this disk.
        #expect(share.canonical == share)
        #expect(url("/home").relative(to: share) == nil && share.relative(to: url("/")) == nil)
        #expect(share.relative(to: server) == ["home"])

        var state = FilesState(home: home)
        state.go(to: url("/Volumes/Share/Movies"), root: url("/Volumes/Share"), above: [server])
        #expect(state.tab.columns.map(\.folder) == [server, url("/Volumes/Share"), url("/Volumes/Share/Movies")])
        #expect(state.tab.columns[0].selection == [url("/Volumes/Share")] && state.tab.focus == 2)

        // Selected before it is mounted, then followed to where it was mounted.
        state.go(to: share, root: server)
        #expect(state.tab.columns.map(\.folder) == [server, share])
        state.moved(share, to: url("/Volumes/Shared home"))
        #expect(state.tab.columns.map(\.folder) == [server, url("/Volumes/Shared home")])
        #expect(state.tab.columns[0].selection == [url("/Volumes/Shared home")])

        // Unmounted: the share's columns close, the server's stays.
        state.removed([url("/Volumes/Shared home")], parent: { _ in server })
        #expect(state.tab.columns.map(\.folder) == [server] && state.tab.columns[0].selection.isEmpty)

        // A tab that started on a disk ejected goes where it is sent.
        state.go(to: url("/Volumes/USB/a"), root: url("/Volumes/USB"))
        state.removed([url("/Volumes/USB")], parent: { _ in home })
        #expect(state.tab.columns.map(\.folder) == [home.canonical])

        #expect(PathInput.isPath("smb://nas/share") && PathInput.isAddress("SMB://nas") && !PathInput.isAddress("/smb://"))
    }
}
