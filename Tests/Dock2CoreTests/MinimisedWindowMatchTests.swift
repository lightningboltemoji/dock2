import Dock2Core
import Foundation
import Testing

private typealias Item = MinimisedWindowMatch.Item
private typealias Window = MinimisedWindowMatch.Window

private let start = Date(timeIntervalSinceReferenceDate: 0)
private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

@Suite struct MinimisedWindowMatchTests {
    /// Windows of one title, minimised one after another: each item, as it comes, takes the window just
    /// minimised, and keeps it after another of that title is minimised later.
    @Test func eachItemKeepsItsWindow() {
        var match = MinimisedWindowMatch()
        match.update(items: [Item(id: 1, title: "zsh")], minimised: [Window(id: 10, title: "zsh", order: 1, minimisedAt: at(0))], at: at(0))
        match.update(items: [Item(id: 1, title: "zsh"), Item(id: 2, title: "zsh")],
                     minimised: [Window(id: 10, title: "zsh", order: 1, minimisedAt: at(0)), Window(id: 11, title: "zsh", order: 2, minimisedAt: at(5))],
                     at: at(5))
        #expect(match.windows == [1: 10, 2: 11])
    }

    /// Windows of one title minimised together, as Minimize All does: the Dock lists their items in the
    /// order the app says they were minimised, so each item takes the window at its place in that order.
    @Test func windowsMinimisedTogetherTakeTheirItemsInOrder() {
        let items = [Item(id: 1, title: "zsh"), Item(id: 2, title: "zsh"), Item(id: 3, title: "zsh")]
        let windows = [Window(id: 10, title: "zsh", order: 1, minimisedAt: at(0.54)), Window(id: 11, title: "zsh", order: 2, minimisedAt: at(0.54)),
                       Window(id: 12, title: "zsh", order: 3, minimisedAt: at(0.55))]
        var together = MinimisedWindowMatch()
        together.update(items: items, minimised: windows, at: at(0.6))
        #expect(together.windows == [1: 10, 2: 11, 3: 12])
        // Heard one by one, the items listed first.
        var oneByOne = MinimisedWindowMatch()
        oneByOne.update(items: items, minimised: [], at: at(0.05))
        for count in 1...3 { oneByOne.update(items: items, minimised: Array(windows.prefix(count)), at: at(0.54)) }
        #expect(oneByOne.windows == together.windows)
    }

    /// A window of the title minimised long before the item — a group's hidden tab still minimised — is not
    /// the item's: it waits for its own.
    @Test func aWindowMinimisedLongBeforeIsNotTheItems() {
        var match = MinimisedWindowMatch()
        let old = Window(id: 10, title: "Documents", order: 1, minimisedAt: at(0))
        match.update(items: [Item(id: 1, title: "Documents")], minimised: [old], at: at(30))
        #expect(match.windows.isEmpty)
        match.update(items: [Item(id: 1, title: "Documents")],
                     minimised: [old, Window(id: 11, title: "Documents", order: 2, minimisedAt: at(30.001))], at: at(30.001))
        #expect(match.windows == [1: 11])
    }

    /// The app can say its window is minimised a moment before the Dock lists the item: it is still the item's.
    @Test func aWindowHeardJustBeforeItsItemIsTheItems() {
        var match = MinimisedWindowMatch()
        let window = Window(id: 10, title: "Notes", order: 1, minimisedAt: at(0.538))
        match.update(items: [], minimised: [window], at: at(0.538))
        match.update(items: [Item(id: 1, title: "Notes")], minimised: [window], at: at(0.541))
        #expect(match.windows == [1: 10])
    }

    /// The Dock can show an item before its app says the window is minimised: it is matched once it does.
    @Test func anItemWaitsForItsWindow() {
        var match = MinimisedWindowMatch()
        match.update(items: [Item(id: 1, title: "Notes")], minimised: [], at: at(0.05))
        #expect(match.windows.isEmpty)
        match.update(items: [Item(id: 1, title: "Notes")], minimised: [Window(id: 10, title: "Notes", order: 1, minimisedAt: at(0.54))], at: at(0.54))
        #expect(match.windows == [1: 10])
    }

    /// An item is not shown while it waits for its window, so its tile never takes another shape first;
    /// matched, it is shown at once.
    @Test func anItemIsShownOnceMatched() {
        var match = MinimisedWindowMatch()
        match.update(items: [Item(id: 1, title: "Notes")], minimised: [], at: start)
        #expect(!match.isShown(1, at: at(0.5)))
        #expect(match.nextDeadline(after: start) == at(MinimisedWindowMatch.patience))
        match.update(items: [Item(id: 1, title: "Notes")], minimised: [Window(id: 10, title: "Notes", order: 1, minimisedAt: at(0.5))], at: at(0.5))
        #expect(match.isShown(1, at: at(0.5)))
        #expect(match.nextDeadline(after: start) == nil)
    }

    /// An item whose window never comes is shown without it once it has waited its patience, and its
    /// deadline is then behind it.
    @Test func anItemWithNoWindowIsShownInTheEnd() {
        var match = MinimisedWindowMatch()
        let end = at(MinimisedWindowMatch.patience)
        match.update(items: [Item(id: 1, title: "Notes")], minimised: [], at: start)
        match.update(items: [Item(id: 1, title: "Notes")], minimised: [], at: at(1))
        #expect(!match.isShown(1, at: end.addingTimeInterval(-0.01)))
        #expect(match.isShown(1, at: end))
        #expect(match.nextDeadline(after: end) == nil)
    }

    /// An item that loses its window — restored while the Dock still lists it — is not shown, and waits afresh.
    @Test func anItemThatLosesItsWindowWaitsAgain() {
        var match = MinimisedWindowMatch()
        match.update(items: [Item(id: 1, title: "A")], minimised: [Window(id: 10, title: "A", order: 1, minimisedAt: start)], at: start)
        let restored = at(10)
        match.update(items: [Item(id: 1, title: "A")], minimised: [], at: restored)
        #expect(!match.isShown(1, at: restored))
        #expect(match.nextDeadline(after: restored) == restored.addingTimeInterval(MinimisedWindowMatch.patience))
    }

    /// A window retitled during its genie: the item, read first under the old title, matches by the new one.
    @Test func aWaitingItemMatchesByItsNewTitle() {
        var match = MinimisedWindowMatch()
        let windows = [Window(id: 10, title: "Renamed", order: 1, minimisedAt: start)]
        match.update(items: [Item(id: 1, title: "Untitled")], minimised: windows, at: start)
        #expect(match.windows.isEmpty)
        match.update(items: [Item(id: 1, title: "Renamed")], minimised: windows, at: at(0.5))
        #expect(match.windows == [1: 10])
        #expect(match.isShown(1, at: at(0.5)))
    }

    /// The Dock keeps the title from the moment of minimising: a window retitled since keeps its item.
    @Test func aRetitledWindowKeepsItsItem() {
        var match = MinimisedWindowMatch()
        match.update(items: [Item(id: 1, title: "Loading…")], minimised: [Window(id: 10, title: "Loading…", order: 1, minimisedAt: start)], at: start)
        match.update(items: [Item(id: 1, title: "Loading…")], minimised: [Window(id: 10, title: "Inbox", order: 1, minimisedAt: start)], at: at(60))
        #expect(match.windows == [1: 10])
    }

    /// An item gone, or its window restored, ends the match.
    @Test func aMatchEndsWithEitherSide() {
        var match = MinimisedWindowMatch()
        let windows = [Window(id: 10, title: "A", order: 1, minimisedAt: start), Window(id: 11, title: "B", order: 2, minimisedAt: start)]
        match.update(items: [Item(id: 1, title: "A"), Item(id: 2, title: "B")], minimised: windows, at: start)
        match.update(items: [Item(id: 2, title: "B")], minimised: windows, at: at(1))
        #expect(match.windows == [2: 11])
        match.update(items: [Item(id: 2, title: "B")], minimised: [windows[0]], at: at(2))
        #expect(match.windows.isEmpty)
    }
}
