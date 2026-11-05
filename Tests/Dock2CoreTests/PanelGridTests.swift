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
