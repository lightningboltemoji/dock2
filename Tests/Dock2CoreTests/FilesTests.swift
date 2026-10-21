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

    @Test func twoTabsAtMost() {
        var state = FilesState(home: home)
        let closedOnly = state.closeTab()
        #expect(!closedOnly)
        state.go(to: url("/Users/me/Desktop"), root: home)
        state.toggleTab(home: home)
        #expect(state.tabs.count == 2 && state.current == 1 && state.tab.folder == home.canonical)
        #expect(state.other?.folder.lastPathComponent == "Desktop")
        state.toggleTab(home: home)
        #expect(state.tabs.count == 2 && state.current == 0)
        state.switchTab()
        #expect(state.current == 1)
        let closed = state.closeTab()
        #expect(closed && state.tabs.count == 1 && state.tab.folder.lastPathComponent == "Desktop")
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
}
