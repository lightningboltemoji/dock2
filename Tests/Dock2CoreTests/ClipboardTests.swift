import Dock2Core
import Foundation
import Testing

@Suite struct ClipboardPolicyTests {
    let text = ["public.utf8-plain-text"]

    @Test func markedCopiesAndIgnoredAppsAreNeverKept() {
        #expect(ClipboardPolicy.decide(types: text + ["org.nspasteboard.ConcealedType"], frontApp: nil, ignored: [], size: 10) == .skip(.marked))
        #expect(ClipboardPolicy.decide(types: text + ["org.nspasteboard.TransientType"], frontApp: nil, ignored: [], size: 10) == .skip(.marked))
        #expect(ClipboardPolicy.decide(types: text, frontApp: "com.bitwarden.desktop", ignored: Set(ClipboardPolicy.ignoredByDefault), size: 10) == .skip(.ignoredApp))
        #expect(ClipboardPolicy.decide(types: ["public.png"], frontApp: nil, ignored: [], size: ClipboardPolicy.sizeCap + 1) == .skip(.tooLarge))
        #expect(ClipboardPolicy.decide(types: ["com.example.private"], frontApp: nil, ignored: [], size: 10) == .skip(.nothingKept))
    }

    @Test func theFirstKindKeptWins() {
        #expect(ClipboardPolicy.decide(types: ["public.file-url"] + text, frontApp: nil, ignored: [], size: 10) == .keep(.files))
        #expect(ClipboardPolicy.decide(types: ["public.rtf"] + text, frontApp: nil, ignored: [], size: 10) == .keep(.richText))
        #expect(ClipboardPolicy.decide(types: ["public.url"] + text, frontApp: nil, ignored: [], size: 10) == .keep(.link))
        #expect(ClipboardPolicy.decide(types: text, frontApp: "com.apple.TextEdit", ignored: [], size: 10) == .keep(.text))
        // Rich text keeps its plain text too, so a plain paste has something to give.
        #expect(ClipboardPolicy.types(for: .richText, among: ["public.rtf", "public.utf8-plain-text", "com.x"]) == ["public.rtf", "public.utf8-plain-text"])
    }

    @Test func titlesAreTheFirstLineWithSomethingInIt() {
        #expect(ClipEntry.title(from: "\n   \n  Hello there \nsecond") == "Hello there")
        #expect(ClipEntry.title(from: String(repeating: "x", count: 300)).count == 201)
    }
}

@Suite struct ClipHistoryTests {
    func entry(_ title: String, digest: String, at seconds: TimeInterval, pinned: Bool = false) -> ClipEntry {
        ClipEntry(kind: .text, title: title, digest: digest, date: Date(timeIntervalSince1970: seconds), pinned: pinned,
                  types: ["public.utf8-plain-text"], size: title.utf8.count)
    }

    @Test func copyingAgainMovesTheEntryToTheTop() {
        var history = ClipHistory()
        let first = history.insert(entry("one", digest: "1", at: 1))
        history.insert(entry("two", digest: "2", at: 2))
        let again = history.insert(entry("one", digest: "1", at: 3))
        #expect(first.isNew && !again.isNew && again.kept.id == first.kept.id)
        #expect(history.entries.map(\.title) == ["one", "two"] && history.entries[0].date.timeIntervalSince1970 == 3)
        history.touch(history.entries[1].id, at: Date(timeIntervalSince1970: 4))
        #expect(history.entries.map(\.title) == ["two", "one"])
    }

    @Test func pruningKeepsPinnedEntriesAndTheNewest() {
        var history = ClipHistory()
        history.insert(entry("old", digest: "a", at: 0))
        history.insert(entry("old pinned", digest: "b", at: 0, pinned: true))
        for i in 0..<5 { history.insert(entry("new \(i)", digest: "n\(i)", at: 1_000_000 + Double(i))) }
        let removed = history.prune(now: Date(timeIntervalSince1970: 1_000_010), retention: 100_000, cap: 4)
        #expect(Set(removed.map(\.title)) == ["old", "new 0", "new 1"])
        #expect(history.entries.map(\.title) == ["new 4", "new 3", "new 2", "old pinned"])
    }

    @Test func searchMatchesTitlesAndFileNames() {
        var history = ClipHistory()
        history.insert(entry("Meeting notes for Tuesday", digest: "t", at: 1))
        history.insert(ClipEntry(kind: .files, title: "report.pdf", files: ["/Users/me/Desktop/report.pdf", "/Users/me/Desktop/budget.xlsx"],
                                 digest: "f", date: Date(), types: ["public.file-url"], size: 0))
        #expect(history.matches(Query("tues")).map(\.entry.digest) == ["t"])
        #expect(history.matches(Query("budget")).map(\.entry.digest) == ["f"])
        #expect(history.matches(Query("zzz")).isEmpty)
    }

    /// Past its first line, an entry is found by the start of its text's words; its title has nothing to bold.
    @Test func searchMatchesTheTextPastTheTitle() throws {
        var history = ClipHistory()
        let text = "Dear Sam,\nThe invoice (#4417) for Café Müller is attached."
        history.insert(ClipEntry(kind: .text, title: ClipEntry.title(from: text), digest: "x", date: Date(), types: [], size: 0,
                                 searchText: ClipEntry.searchText(from: text)))
        let found = try #require(history.matches(Query("cafe inv")).first)
        #expect(found.match == Match(kind: .words, ranges: []))
        #expect(history.matches(Query("#4417")).count == 1 && history.matches(Query("muller")).count == 1)
        #expect(history.matches(Query("voice")).isEmpty && history.matches(Query("attached zzz")).isEmpty)
        #expect(ClipEntry.searchText(from: String(repeating: "a", count: 10_000)).count == ClipEntry.searchLimit)
    }
}
