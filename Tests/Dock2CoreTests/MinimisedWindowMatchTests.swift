import Dock2Core
import Foundation
import Testing

private typealias Item = MinimisedWindowMatch.Item
private typealias Window = MinimisedWindowMatch.Window

@Suite struct MinimisedWindowMatchTests {
    /// A group of tabs is one item in the Dock and a minimised window per tab: the tab on show, said last,
    /// is the item's; the others match nothing.
    @Test func aGroupOfTabsIsTheTabOnShow() {
        var match = MinimisedWindowMatch()
        match.update(items: [Item(id: 1, title: "Alpha")],
                     minimised: [Window(id: 10, title: "Beta", order: 1), Window(id: 11, title: "Alpha", order: 2)])
        #expect(match.windows == [1: 11])
        match.update(items: [Item(id: 1, title: "~")],
                     minimised: [Window(id: 20, title: "~", order: 3), Window(id: 21, title: "~", order: 4), Window(id: 22, title: "~", order: 5)])
        #expect(match.windows == [1: 22])
    }

    /// Windows of one title, minimised one after another: each item, as it comes, takes the window just
    /// minimised, and keeps it after another of that title is minimised later.
    @Test func eachItemKeepsItsWindow() {
        var match = MinimisedWindowMatch()
        match.update(items: [Item(id: 1, title: "zsh")], minimised: [Window(id: 10, title: "zsh", order: 1)])
        match.update(items: [Item(id: 1, title: "zsh"), Item(id: 2, title: "zsh")],
                     minimised: [Window(id: 10, title: "zsh", order: 1), Window(id: 11, title: "zsh", order: 2)])
        #expect(match.windows == [1: 10, 2: 11])
    }

    /// The Dock can show an item before its app says the window is minimised: it is matched once it does.
    @Test func anItemWaitsForItsWindow() {
        var match = MinimisedWindowMatch()
        match.update(items: [Item(id: 1, title: "Notes")], minimised: [])
        #expect(match.windows.isEmpty)
        match.update(items: [Item(id: 1, title: "Notes")], minimised: [Window(id: 10, title: "Notes", order: 1)])
        #expect(match.windows == [1: 10])
    }

    /// An item is not shown while it waits for its window, so its tile never takes another shape first;
    /// matched, it is shown at once.
    @Test func anItemIsShownOnceMatched() {
        var match = MinimisedWindowMatch()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        match.update(items: [Item(id: 1, title: "Notes")], minimised: [], at: start)
        #expect(!match.isShown(1, at: start.addingTimeInterval(0.5)))
        #expect(match.nextDeadline(after: start) == start.addingTimeInterval(MinimisedWindowMatch.patience))
        match.update(items: [Item(id: 1, title: "Notes")], minimised: [Window(id: 10, title: "Notes", order: 1)],
                     at: start.addingTimeInterval(0.5))
        #expect(match.isShown(1, at: start.addingTimeInterval(0.5)))
        #expect(match.nextDeadline(after: start) == nil)
    }

    /// An item whose window never comes is shown without it once it has waited its patience, and its
    /// deadline is then behind it.
    @Test func anItemWithNoWindowIsShownInTheEnd() {
        var match = MinimisedWindowMatch()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end = start.addingTimeInterval(MinimisedWindowMatch.patience)
        match.update(items: [Item(id: 1, title: "Notes")], minimised: [], at: start)
        match.update(items: [Item(id: 1, title: "Notes")], minimised: [], at: start.addingTimeInterval(1))
        #expect(!match.isShown(1, at: end.addingTimeInterval(-0.01)))
        #expect(match.isShown(1, at: end))
        #expect(match.nextDeadline(after: end) == nil)
    }

    /// An item that loses its window — restored while the Dock still lists it — is not shown, and waits afresh.
    @Test func anItemThatLosesItsWindowWaitsAgain() {
        var match = MinimisedWindowMatch()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        match.update(items: [Item(id: 1, title: "A")], minimised: [Window(id: 10, title: "A", order: 1)], at: start)
        let restored = start.addingTimeInterval(10)
        match.update(items: [Item(id: 1, title: "A")], minimised: [], at: restored)
        #expect(!match.isShown(1, at: restored))
        #expect(match.nextDeadline(after: restored) == restored.addingTimeInterval(MinimisedWindowMatch.patience))
    }

    /// A window retitled during its genie: the item, read first under the old title, matches by the new one.
    @Test func aWaitingItemMatchesByItsNewTitle() {
        var match = MinimisedWindowMatch()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let windows = [Window(id: 10, title: "Renamed", order: 1)]
        match.update(items: [Item(id: 1, title: "Untitled")], minimised: windows, at: start)
        #expect(match.windows.isEmpty)
        match.update(items: [Item(id: 1, title: "Renamed")], minimised: windows, at: start.addingTimeInterval(0.5))
        #expect(match.windows == [1: 10])
        #expect(match.isShown(1, at: start.addingTimeInterval(0.5)))
    }

    /// The Dock keeps the title from the moment of minimising: a window retitled since keeps its item.
    @Test func aRetitledWindowKeepsItsItem() {
        var match = MinimisedWindowMatch()
        match.update(items: [Item(id: 1, title: "Loading…")], minimised: [Window(id: 10, title: "Loading…", order: 1)])
        match.update(items: [Item(id: 1, title: "Loading…")], minimised: [Window(id: 10, title: "Inbox", order: 1)])
        #expect(match.windows == [1: 10])
    }

    /// An item gone, or its window restored, ends the match.
    @Test func aMatchEndsWithEitherSide() {
        var match = MinimisedWindowMatch()
        let windows = [Window(id: 10, title: "A", order: 1), Window(id: 11, title: "B", order: 2)]
        match.update(items: [Item(id: 1, title: "A"), Item(id: 2, title: "B")], minimised: windows)
        match.update(items: [Item(id: 2, title: "B")], minimised: windows)
        #expect(match.windows == [2: 11])
        match.update(items: [Item(id: 2, title: "B")], minimised: [windows[0]])
        #expect(match.windows.isEmpty)
    }
}
