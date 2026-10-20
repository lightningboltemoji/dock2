import CoreGraphics
import Dock2Core
import Testing

/// The system Dock on a 1920×1243pt screen, read through Accessibility at each tile size: Finder,
/// four more applications, the separator and the Trash. Top-left origin, as AX reports it.
private struct Measured: CustomTestStringConvertible {
    let tileSize: Double
    /// The list's x, y, width and height.
    let list: (x: Double, y: Double, width: Double, height: Double)
    let firstTileX: Double
    let tile: (width: Double, height: Double)

    var testDescription: String { "tile size \(tileSize)" }
}

private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1243)

private let measured: [Measured] = [
    Measured(tileSize: 48, list: (784, 1165, 352, 68), firstTileX: 792.3, tile: (52, 68)),
    Measured(tileSize: 64, list: (733, 1149, 454, 84), firstTileX: 740.7, tile: (68, 84)),
    Measured(tileSize: 80, list: (681, 1133, 558, 100), firstTileX: 689.1, tile: (84, 100)),
    Measured(tileSize: 95, list: (633, 1118, 654, 115), firstTileX: 640.725, tile: (99, 115)),
    Measured(tileSize: 128, list: (519, 1083, 882, 150), firstTileX: 527.85, tile: (134, 150)),
]

/// Below 48 the tiles and the height are exact; the platter's width is not modelled exactly.
private let small: [Measured] = [
    Measured(tileSize: 16, list: (896, 1203, 128, 30), firstTileX: 901.95, tile: (18, 30)),
    Measured(tileSize: 32, list: (847, 1187, 226, 46), firstTileX: 850.35, tile: (34, 46)),
]

@Suite struct DockMetricsTests {
    @Test(arguments: measured + small)
    fileprivate func tilesAndHeight(_ m: Measured) {
        let metrics = DockMetrics(tileSize: m.tileSize)
        #expect(metrics.tileWidth == m.tile.width)
        #expect(metrics.platterHeight == m.tile.height)
    }

    @Test(arguments: measured)
    fileprivate func platterMatchesTheSystemDock(_ m: Measured) {
        let metrics = DockMetrics(tileSize: m.tileSize)
        let run = 6 * metrics.tileWidth + metrics.separatorWidth
        let width = metrics.platterWidth(run: run)
        #expect(width == m.list.width)
        #expect((Double(screen.midX) - width / 2).rounded() == m.list.x)
        #expect(abs(m.list.x + (width - run) / 2 - m.firstTileX) < 0.01)
    }

    /// The platter's bottom sits 5pt above the screen's at every size: the items' AX frames, which are
    /// the platter's, start at 1243 - 5 - height.
    @Test(arguments: measured + small)
    fileprivate func platterFloatsFivePointsUp(_ m: Measured) {
        let layout = DockLayout(metrics: DockMetrics(tileSize: m.tileSize), tileCount: 2, screen: screen)
        #expect(Double(layout.platter.minY) == 5)
        #expect(Double(screen.height - layout.platter.maxY) == m.list.y + 5)
    }

    @Test func iconsAreCentredInTheirSlotsAndThePlatter() {
        let layout = DockLayout(metrics: DockMetrics(tileSize: 95), tileCount: 2, screen: screen)
        for tile in layout.tiles {
            #expect(tile.icon.midX == tile.slot.midX)
            #expect(tile.icon.midY == layout.platter.midY)
            #expect(tile.icon.width == 95)
        }
    }

    /// Finder's dot at tile size 95 occupied device pixels 1376–1383 across and 2460–2467 down.
    @Test func dotLandsOnTheMeasuredPixels() {
        let metrics = DockMetrics(tileSize: 95)
        let slot = CGRect(x: 640.725, y: 5, width: 99, height: 115)
        let dot = CGRect(x: slot.midX - metrics.dotDiameter / 2, y: 5 + metrics.dotCenterHeight - metrics.dotDiameter / 2,
                         width: metrics.dotDiameter, height: metrics.dotDiameter)
        let snapped = pixelAligned(dot, scale: 2)
        #expect(snapped == CGRect(x: 688, y: 1243 - 1234, width: 4, height: 4))
    }

    @Test func runIsCentredOnThePlatter() {
        let layout = DockLayout(metrics: DockMetrics(tileSize: 95), tileCount: 2, screen: screen)
        #expect(layout.platter.width == 214)
        #expect(layout.tiles[0].slot.minX - layout.platter.minX == layout.platter.maxX - layout.tiles[1].slot.maxX)
    }

    @Test func hitTestingCoversWholeSlots() {
        let layout = DockLayout(metrics: DockMetrics(tileSize: 95), tileCount: 2, screen: screen)
        let gap = CGPoint(x: layout.tiles[0].slot.maxX - 0.5, y: layout.platter.midY)
        #expect(layout.tileIndex(at: gap) == 0)
        #expect(layout.tileIndex(at: CGPoint(x: layout.tiles[1].slot.minX, y: layout.platter.midY)) == 1)
        #expect(layout.tileIndex(at: CGPoint(x: layout.platter.minX + 1, y: layout.platter.midY)) == nil)
        #expect(layout.tileIndex(at: CGPoint(x: layout.platter.midX, y: layout.platter.maxY + 1)) == nil)
    }

    /// Fitted from the corner's outline: about 15pt at tile size 32, 22 at 48, and 28 from 64 up.
    @Test func cornerRadiusIsAThirdOfTheHeightUpTo28() {
        #expect(abs(DockMetrics(tileSize: 32).cornerRadius - 15.33) < 0.01)
        #expect(abs(DockMetrics(tileSize: 48).cornerRadius - 22.67) < 0.01)
        #expect(DockMetrics(tileSize: 64).cornerRadius == 28)
        #expect(DockMetrics(tileSize: 95).cornerRadius == 28)
    }

    @Test func tileSizeIsClampedToTheDocksRange() {
        #expect(DockMetrics(tileSize: 4).tileSize == 16)
        #expect(DockMetrics(tileSize: 512).tileSize == 128)
    }
}

@Suite struct LabelMetricsTests {
    /// "Safari" and "Ghostty" at 14pt advance 37.12 and 50.94; their bubbles were 64 and 77 wide.
    @Test func widthIsTextPlusPaddingRounded() {
        #expect(LabelMetrics.width(forText: 37.12) == 64)
        #expect(LabelMetrics.width(forText: 50.94) == 77)
    }

    /// Over Safari at tile size 95 the bubble spanned 856–920 across, 9.5pt above the platter.
    @Test func bodyIsCentredOnWholePoints() {
        let body = LabelMetrics.body(textWidth: 37.12, centerX: 888.225, platterTop: 120)
        #expect(body == CGRect(x: 856, y: 129.5, width: 64, height: 25.5))
    }
}

