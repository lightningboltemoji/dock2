import CoreGraphics
import Testing
@testable import Dock2Core

struct FlowLayoutTests {
    private let gap = CGFloat(FlowLayout.gap), height = CGFloat(FlowLayout.pillHeight)

    private func layout(_ pieces: [FlowLayout.Piece], right: Double = 300) -> (frames: [CGRect], height: Double) {
        FlowLayout.frames(pieces, left: 20, right: right, titleHeight: 32, messageHeight: 56)
    }

    /// Pills follow one another along a line from the left edge, and one that would pass the right edge starts the next
    /// line; a title stands on a line of its own, a gap after the pills before it.
    @Test func pillsReadLikeWordsUnderTheirTitle() {
        let (frames, total) = layout([.title, .pill(width: 100), .pill(width: 100), .pill(width: 100), .title, .pill(width: 50)])
        #expect(frames[0] == CGRect(x: 20, y: 0, width: 280, height: 32))
        #expect(frames[1] == CGRect(x: 20, y: 32, width: 100, height: height))
        #expect(frames[2].minX == 20 + 100 + gap && frames[2].minY == 32)
        #expect(frames[3].minX == 20 && frames[3].minY == 32 + height + gap)
        #expect(frames[4].minY == frames[3].maxY + gap)
        #expect(frames[5].minY == frames[4].maxY && CGFloat(total) == frames[5].maxY)
    }

    /// A pill is never wider than the widest a pill draws, nor than its line.
    @Test func aLongPillIsCutToItsLine() {
        #expect(layout([.pill(width: 900)]).frames[0].width == CGFloat(FlowLayout.widest))
        #expect(layout([.pill(width: 900)], right: 120).frames[0].width == 100)
        #expect(layout([.message]).frames[0] == CGRect(x: 0, y: 0, width: 320, height: 56))
    }

    /// ↑ and ↓ go to the pill on the next line nearest across, over a section's title, and nowhere past the first or
    /// last line.
    @Test func upAndDownFindTheNearestPillOnTheNextLine() {
        let pieces: [FlowLayout.Piece] = [.title, .pill(width: 60), .pill(width: 60), .pill(width: 60), .pill(width: 200), .title, .pill(width: 40)]
        let (frames, _) = layout(pieces)
        let pills = pieces.map { if case .pill = $0 { true } else { false } }
        // Lines: 1 2 3 on the first, 4 on the second; 6 under the next title.
        #expect(frames[4].minY > frames[1].minY && frames[3].minY == frames[1].minY)
        #expect(FlowLayout.vertical(from: 3, in: frames, pills: pills, down: true) == 4)
        #expect(FlowLayout.vertical(from: 4, in: frames, pills: pills, down: false) == 2)
        #expect(FlowLayout.vertical(from: 4, in: frames, pills: pills, down: true) == 6)
        #expect(FlowLayout.vertical(from: 6, in: frames, pills: pills, down: true) == nil)
        #expect(FlowLayout.vertical(from: 1, in: frames, pills: pills, down: false) == nil)
    }

    /// A pill on its section's first line is kept in sight with the title over it; one on a later line is not.
    @Test func aSectionsFirstLineKeepsItsTitle() {
        let pieces: [FlowLayout.Piece] = [.title, .pill(width: 60), .pill(width: 60), .pill(width: 60), .pill(width: 200), .title, .pill(width: 40)]
        let (frames, _) = layout(pieces)
        let titles = pieces.map { $0 == .title }
        #expect(FlowLayout.title(over: 1, in: frames, titles: titles) == 0)
        #expect(FlowLayout.title(over: 3, in: frames, titles: titles) == 0)
        #expect(FlowLayout.title(over: 4, in: frames, titles: titles) == nil)
        #expect(FlowLayout.title(over: 6, in: frames, titles: titles) == 5)
        #expect(FlowLayout.title(over: 0, in: layout([.pill(width: 60)]).frames, titles: [false]) == nil)
    }

    /// A flow is never a tree, and says so when it holds items under items.
    @Test func aFlowIsNeverATree() {
        let item = ListNode.Item(id: "a", title: "A", children: [.init(id: "b", title: "B")])
        let flow = ListNode(id: "f", sections: [.init(items: [item])], layout: .flow)
        #expect(!flow.isTree && flow.flowHidesChildren)
        #expect(flow.rows(for: Query(""), open: ["a"]).flatMap(\.rows).map(\.item.id) == ["a"])
        var rows = flow
        rows.layout = nil
        #expect(rows.isTree && !rows.flowHidesChildren)
    }
}
