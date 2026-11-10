import CoreGraphics
import Testing
@testable import Dock2Core

/// The panel's grid ([visual](product/visual.md#layout)): what holds however its numbers are tuned.
struct PanelGridTests {
    /// Every measure on the pane, from its edge; the ground's rim, outside it, is tuned by eye, and the corners follow
    /// from the layers' insets.
    @Test func everyMeasureOnThePaneIsOnTheGrid() {
        let rows = [PanelMetrics.Row.regular, .compact]
        let measures = [PanelMetrics.rowHeight, PanelMetrics.padding]
            + rows.flatMap { [$0.height, $0.plate, $0.plateX, $0.textX] }
        for measure in measures {
            #expect(measure.truncatingRemainder(dividingBy: PanelMetrics.unit) == 0, "\(measure)")
        }
    }

    /// Marks in `room`, 6 apart, a count 30 wide.
    private func marks(_ asked: [CGFloat], in room: CGFloat) -> PanelMetrics.Marks {
        PanelMetrics.marks(asked, in: room, gap: 6, floor: 40) { _ in 30 }
    }

    @Test func marksThatFitAreLeftAlone() {
        #expect(marks([], in: 100) == .init(widths: [], rest: 0))
        #expect(marks([50, 44], in: 100) == .init(widths: [50, 44], rest: 0))
    }

    @Test func marksPastTheRoomLeaveACount() {
        #expect(marks([50, 50, 50, 50], in: 150) == .init(widths: [50, 50], rest: 2))
        // The second would fit alone, but not with the count after it.
        #expect(marks([50, 50, 50], in: 120) == .init(widths: [50], rest: 2))
    }

    @Test func aCountNeverStandsForLessThanItTakes() {
        // The last, no wider than the count would be, stands in its place.
        #expect(marks([50, 50, 30], in: 142) == .init(widths: [50, 50, 30], rest: 0))
    }

    @Test func theCountsOwnWidthDecidesHowManyFit() {
        let wide = PanelMetrics.marks(Array(repeating: 20, count: 12), in: 108, gap: 6, floor: 40) { $0 > 9 ? 40 : 30 }
        #expect(wide == .init(widths: [20, 20, 20], rest: 9))
    }

    @Test func aFirstMarkTooWideIsCut() {
        #expect(marks([500], in: 120) == .init(widths: [120], rest: 0))
        #expect(marks([500, 50, 50], in: 120) == .init(widths: [84], rest: 2))
    }

    @Test func aMarkCutPastTheFloorLeavesTheCountAlone() {
        #expect(marks([500], in: 30) == .init(widths: [], rest: 1))
        #expect(marks([500, 50], in: 60) == .init(widths: [], rest: 2))
        #expect(marks([50], in: -10) == .init(widths: [], rest: 1))
    }

    @Test func marksTakeWhatTheWordsLeave() {
        let row = PanelMetrics.Row.compact
        #expect(row.marksRoom(width: 256, left: 44, words: 50, text: 0) == 138)
        #expect(row.marksRoom(width: 256, left: 44, words: 50, text: 50) == 80)
    }

    @Test func marksKeepHalfTheRowHoweverLongTheWords() {
        let row = PanelMetrics.Row.compact
        #expect(row.marksRoom(width: 256, left: 44, words: 900, text: 0) == 98)
        #expect(row.marksRoom(width: 256, left: 44, words: 900, text: 50) == 40)
    }

    @Test func widthsThatFitAreLeftAlone() {
        #expect(PanelMetrics.fit([], into: 100, floor: 84) == [])
        #expect(PanelMetrics.fit([44, 120], into: 164, floor: 84) == [44, 120])
    }

    @Test func theWidestGiveWayAndTheNarrowKeepTheirs() {
        // What the narrow leave goes to the wide: 400 - 44 - 60 between two.
        #expect(PanelMetrics.fit([176, 44, 176, 60], into: 400, floor: 84) == [148, 44, 148, 60])
        // One a share would cut keeps what it asks once a wider one has given way.
        #expect(PanelMetrics.fit([300, 120, 60], into: 300, floor: 84) == [120, 120, 60])
    }

    @Test func nothingGivesWayPastTheFloor() {
        #expect(PanelMetrics.fit([176, 176, 44], into: 150, floor: 84) == [84, 84, 44])
    }

    @Test func eachLayerIsConcentricWithTheOneItIsIn() {
        #expect(PanelMetrics.paneRadius == Double(PanelMetrics.fieldSize.height) / 2)
        #expect(PanelMetrics.paneRadius == PanelMetrics.radius - PanelMetrics.paneInset)
        #expect(PanelMetrics.Row.regular.bandRadius == PanelMetrics.paneRadius - PanelMetrics.padding)
        let body = CGRect(x: 0, y: 0, width: 640, height: 400)
        let grown = PanelMetrics.layering(body: body, radius: PanelMetrics.radius, fieldHeight: PanelMetrics.fieldSize.height, ground: 1)
        #expect(Double(grown.paneRadius) == PanelMetrics.paneRadius)
        #expect(Double(grown.pane.minX) == PanelMetrics.paneInset && Double(body.maxX - grown.pane.maxX) == PanelMetrics.paneInset)
        #expect(Double(body.maxY - grown.pane.maxY) == PanelMetrics.paneInset)
    }

    /// A screen's parts keep their place on the glass wherever it is on its way to, so it cuts nothing they show from the
    /// end each reads from, and at rest each is where it was laid out.
    @Test func whatAScreenShowsRidesTheGlass() {
        let rest = CGRect(x: -480, y: -28, width: 960, height: 520)
        #expect(ScreenRide(body: rest, rest: rest).contents == .zero && ScreenRide(body: rest, rest: rest).leading == .zero)
        let bodies = [CGRect(x: -320, y: -60, width: 640, height: 56), CGRect(x: -50, y: -28, width: 100, height: 200),
                      CGRect(x: -486, y: -28, width: 972, height: 528)]
        for body in bodies {
            let ride = ScreenRide(body: body, rest: rest)
            #expect(rest.minX + ride.leading.x == body.minX && rest.minY + ride.leading.y == body.minY)
            #expect(rest.maxX + ride.trailing.x == body.maxX && rest.minY + ride.trailing.y == body.minY)
            // What the leading end shows stops at the trailing end, wherever that has come to.
            #expect(rest.maxX + ride.leading.x + ride.room.x == body.maxX)
            // The contents, carried by the pane they lie in.
            #expect(rest.minX + ride.pane.x + ride.contents.x == body.minX)
            #expect(rest.maxY + ride.pane.y + ride.contents.y == body.maxY)
        }
    }

    /// What cannot be concentric with the pane still keeps a band's distance from it where it turns.
    @Test func whatCannotShareThePanesCornersClearsThem() {
        let turn = PanelMetrics.paneRadius, band = 10.0, inset = PanelMetrics.cornerInset
        let offset = turn - inset - band
        let gap = turn - (2 * offset * offset).squareRoot() - band
        #expect(gap >= PanelMetrics.padding, "\(gap)")
        #expect(inset.truncatingRemainder(dividingBy: PanelMetrics.unit) == 0)
        #expect(PanelMetrics.cardRadius == PanelMetrics.paneRadius - inset)
    }

    /// A plate's corners, 0.26 of it as Icon Composer draws it, and a band's are concentric at either size, and in the
    /// same proportion to the row: a compact row's cannot also be the pane's, which would pass a capsule.
    @Test(arguments: [PanelMetrics.Row.regular, .compact]) func aBandIsConcentricWithItsPlate(_ row: PanelMetrics.Row) {
        let plateCorners = 0.26 * row.plate
        #expect(abs(row.bandRadius - (row.plateX - row.bandX + plateCorners)) < 0.5)
        #expect(abs(row.bandRadius / row.height - 0.36) < 0.005)
    }

    /// The icon stands in a square as tall as the row: as far from the band's side, and from the text, as from the
    /// band's top and bottom; the trailing end mirrors the leading one.
    @Test(arguments: [PanelMetrics.Row.regular, .compact]) func aRowsIconHasAsMuchRoomBesideItAsAboveIt(_ row: PanelMetrics.Row) {
        let above = (row.height - row.plate) / 2
        #expect(row.plateX - row.bandX == above)
        #expect(row.textX - (row.plateX + row.plate) == above)
        #expect(row.trailingX == row.plateX)
        #expect(row.bandX == PanelMetrics.padding)
    }

    /// The field is the panel's bottom row: its magnifier centred under the icons, its text where their titles start.
    @Test func theFieldStandsOnTheRowsLines() {
        #expect(Double(PanelMetrics.fieldSize.height) == PanelMetrics.rowHeight)
        let field = CGRect(x: 100, y: 0, width: PanelMetrics.fieldSize.width, height: PanelMetrics.rowHeight)
        let pane = PanelMetrics.pane(over: field, extent: 300)
        #expect(Double(field.minX) + PanelMetrics.glyphCenter == Double(pane.minX) + PanelMetrics.Row.regular.glyphX)
        #expect(Double(field.minX) + PanelMetrics.textLeft == Double(pane.minX) + PanelMetrics.Row.regular.textX)
    }

    /// The panel's margin is the same at both edges: the icons start on it, the rows' trailing ends and the bar stop on it.
    @Test func theMarginIsTheSameAtBothEdges() {
        let row = PanelMetrics.Row.regular
        #expect(PanelMetrics.margin == PanelMetrics.paneInset + row.plateX)
        #expect(PanelMetrics.margin == PanelMetrics.paneInset + row.trailingX)
    }
}
