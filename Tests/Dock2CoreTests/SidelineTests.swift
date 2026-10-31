import CoreGraphics
import Dock2Core
import Testing

private func app(_ id: String) -> AppRef { AppRef(bundleIdentifier: id, path: "/Applications/\(id).app") }

private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)

@Suite struct SidelinePackingTests {
    /// The design's table at tile size 128: rows × columns, the icons' size and the empty cells.
    @Test(arguments: [
        (1, 1, 1, 63.0), (2, 2, 1, 63), (3, 3, 1, 43), (4, 2, 2, 63), (5, 3, 2, 43), (6, 3, 2, 43),
        (7, 4, 2, 32), (8, 4, 2, 32), (9, 3, 3, 43), (10, 5, 2, 25), (11, 4, 3, 32), (12, 4, 3, 32),
    ])
    func packsAsDesignedAtTile128(_ count: Int, _ rows: Int, _ columns: Int, _ icon: Double) throws {
        let packing = try #require(SidelinePacking(count: count, metrics: DockMetrics(tileSize: 128)))
        #expect(packing.rows == rows && packing.columns == columns, "\(count) apps: \(packing)")
        #expect(abs(packing.icon - icon) <= 0.5)
        #expect(packing.empty(holding: count) == [5: 1, 7: 1, 11: 1][count, default: 0])
    }

    /// How fine each dock height cuts, and the icons there: the finest cut whose icons are still 24pt.
    @Test(arguments: [(48.0, 2, 24.0), (64, 2, 32), (96, 3, 32), (128, 5, 24.8), (256, 10, 24.8)])
    func theFinestCutKeepsIconsAt24(_ tile: Double, _ cut: Int, _ icon: Double) throws {
        let metrics = DockMetrics(tileSize: tile)
        let many = try #require(SidelinePacking(count: 200, metrics: metrics))
        #expect(many.cut == cut && many.rows == cut)
        #expect(abs(many.icon - icon) < 0.01)
    }

    /// Where the cut stops, the puck grows sideways: two rows from 5 apps at 48 and 64, three from 10 at 96,
    /// five from 26 at 128.
    @Test(arguments: [(48.0, 5, 2), (64, 5, 2), (96, 10, 3), (128, 26, 5)])
    func pastTheFinestCutItGrowsSideways(_ tile: Double, _ from: Int, _ rows: Int) throws {
        let metrics = DockMetrics(tileSize: tile)
        let before = try #require(SidelinePacking(count: from - 1, metrics: metrics))
        let after = try #require(SidelinePacking(count: from, metrics: metrics))
        #expect(Double(before.columns) * before.cell <= metrics.tileWidth + 1e-9)
        #expect(Double(after.columns) * after.cell > metrics.tileWidth && after.rows == rows)
    }

    /// Halves have no column of three: three apps leave one cell of a 2 × 2; at 96, seven leave two of a 3 × 3.
    @Test func theTwentyFourPointFloorLeavesEmptyCells() throws {
        let three = try #require(SidelinePacking(count: 3, metrics: DockMetrics(tileSize: 48)))
        #expect(three.rows == 2 && three.columns == 2 && three.empty(holding: 3) == 1)
        let seven = try #require(SidelinePacking(count: 7, metrics: DockMetrics(tileSize: 96)))
        #expect(seven.rows == 3 && seven.columns == 3 && seven.empty(holding: 7) == 2)
    }

    /// At 256, 128's shapes up to 16 apps, the cells twice as large.
    @Test func at256ItIs128Magnified() throws {
        for count in 1...16 {
            let small = try #require(SidelinePacking(count: count, metrics: DockMetrics(tileSize: 128)))
            let large = try #require(SidelinePacking(count: count, metrics: DockMetrics(tileSize: 256)))
            #expect(large.rows == small.rows && large.columns == small.columns && large.cell == 2 * small.cell)
        }
    }

    /// Below 48 half a slot holds less than 24pt: one row of 24pt icons, or of the tiles' size below that.
    @Test func belowFortyEightItIsOneRow() throws {
        let row = try #require(SidelinePacking(count: 5, metrics: DockMetrics(tileSize: 40)))
        #expect(row.cut == nil && row.rows == 1 && row.columns == 5 && row.icon == 24)
        #expect(try #require(SidelinePacking(count: 2, metrics: DockMetrics(tileSize: 16))).icon == 16)
        #expect(SidelinePacking(count: 0, metrics: DockMetrics(tileSize: 128)) == nil)
    }

    /// Every size from 16 to 256 against 1 to 30 apps: never taller than the platter, never under 24pt (but for
    /// a dock smaller than that), never wider than a tile until the finest cut is full, empty cells only at the
    /// top right, and never a cut finer than the two in play.
    @Test func everySizeAndCount() throws {
        for tile in stride(from: 16.0, through: 256, by: 1) {
            let metrics = DockMetrics(tileSize: tile)
            for count in 1...30 {
                let packing = try #require(SidelinePacking(count: count, metrics: metrics))
                let label = Comment(rawValue: "\(count) apps at \(tile): \(packing)")
                #expect(Double(packing.rows) * packing.cell + 2 * metrics.platterRim <= metrics.platterHeight + 1e-9, label)
                #expect(packing.icon >= min(SidelinePacking.smallestIcon, tile) - 1e-9, label)
                #expect(packing.rows * packing.columns >= count && packing.empty(holding: count) < packing.columns, label)
                guard let cut = packing.cut else { continue }
                let coarsest = max(2, (1...).first { $0 * $0 >= count }!)
                let finest = packing.finer(holding: count, metrics: metrics).last?.cut ?? cut
                #expect(cut == coarsest || cut == coarsest + 1 || (coarsest > finest && cut == finest), label)
                if count <= finest * finest {
                    #expect(packing.columns <= cut, label)
                } else {
                    #expect(packing.columns == (count + cut - 1) / cut, label)
                }
            }
        }
    }

    /// Narrowing goes finer a cut at a time, each narrower than the last.
    @Test func finerCutsNarrowThePuck() throws {
        let metrics = DockMetrics(tileSize: 128)
        let packing = try #require(SidelinePacking(count: 12, metrics: metrics))
        let finer = packing.finer(holding: 12, metrics: metrics)
        #expect(finer.map(\.cut) == [5])
        #expect(finer[0].rows == 4 && finer[0].columns == 3)
    }
}

@Suite struct PuckTests {
    private func layout(_ tile: Double, tiles: Int = 3, sidelined: Int) -> DockLayout {
        DockLayout(metrics: DockMetrics(tileSize: tile), kinds: Array(repeating: .tile, count: tiles), sidelined: sidelined, screen: screen)
    }

    /// Right of the platter across a 12pt gap, on its baseline, the platter still centred; one app at 128 is
    /// one 67pt cell between the platter's rims, under the platter's corners.
    @Test func onePuckHangsOffTheRightEnd() throws {
        let layout = layout(128, sidelined: 1)
        let puck = try #require(layout.puck)
        #expect(layout.platter.midX == screen.midX)
        #expect(puck.frame.minX == layout.platter.maxX + 12 && puck.frame.minY == layout.platter.minY)
        #expect(puck.frame.height == 67 + 16 && puck.frame.width == 67 + 18)
        #expect(puck.cornerRadius == 28)
        #expect(layout.slots.count == 4 && layout.rowCount == 3 && layout.isSidelined(3))
        #expect(layout.slots[3].content.width == 63 && layout.slots[3].dot.isEmpty)
    }

    /// Rows fill from the bottom, left to right: the first app sits at the bottom left, next to the dock.
    @Test func cellsFillFromTheBottomLeft() throws {
        let layout = layout(128, sidelined: 5)
        let cells = layout.slots[layout.rowCount...].map(\.frame)
        #expect(cells[0].minY < cells[2].minY && cells[0].minX == cells[2].minX)
        #expect(cells[1].minY == cells[0].minY && cells[1].minX > cells[0].minX)
        #expect(cells[4].minY > cells[2].minY)
        let puck = try #require(layout.puck)
        #expect(cells[0].minY == puck.frame.minY + 8 && cells[4].maxY == puck.frame.maxY - 8)
        #expect(puck.frame.height == layout.platter.height)
    }

    @Test func thePuckIsHitTestedByCell() throws {
        let layout = layout(128, sidelined: 4)
        let puck = try #require(layout.puck)
        for index in layout.rowCount..<layout.slots.count {
            let cell = layout.slots[index].frame
            #expect(layout.tileIndex(at: CGPoint(x: cell.midX, y: cell.midY)) == index)
            #expect(layout.top(of: index) == Double(puck.frame.maxY))
        }
        let rim = CGPoint(x: puck.frame.midX, y: puck.frame.minY + 2)
        #expect(layout.contains(rim) && layout.tileIndex(at: rim) == nil)
        let gap = CGPoint(x: layout.platter.maxX + 6, y: layout.platter.midY)
        #expect(!layout.contains(gap))
        #expect(layout.top(of: 0) == Double(layout.platter.maxY))
    }

    /// The puck's corners are the platter's whatever it holds, and it is never smaller than they are, nor taller
    /// than the platter: a lone app on a small dock sits in a puck as round as the corners make it.
    @Test func theCornersAreThePlattersAtEverySize() throws {
        for tile in stride(from: 16.0, through: 256, by: 4) {
            for count in [1, 2, 3, 5, 10, 17] {
                let layout = layout(tile, sidelined: count)
                let puck = try #require(layout.puck)
                #expect(puck.cornerRadius == layout.metrics.cornerRadius)
                #expect(puck.frame.width >= 2 * puck.cornerRadius && puck.frame.height >= 2 * puck.cornerRadius - 1e-9)
                #expect(puck.frame.height <= layout.platter.height + 1e-9)
            }
        }
        let small = try #require(layout(64, sidelined: 1).puck)
        #expect(small.frame.size == CGSize(width: 56, height: 56))
        let cell = layout(64, sidelined: 1).slots[3].frame
        #expect(cell.midX == small.frame.midX && cell.midY == small.frame.midY)
    }

    /// No badge on the puck comes within `puckBadgeClearance` of its outline, the corners' curves included, its label
    /// as short or as long as it gets. Below tile 25 the puck is the platter's height, and a badge there is as far
    /// from its top as the row's own are from the platter's.
    @Test func badgesClearThePucksOutline() throws {
        for tile in stride(from: 16.0, through: 256, by: 1) {
            for count in 1...30 {
                let layout = layout(tile, tiles: 1, sidelined: count)
                let least = tile < 25 ? platterBadgeClearance(tile) : layout.metrics.puckBadgeClearance
                #expect(puckBadgeClearance(layout) >= least - 1e-6, "\(count) apps at \(tile)")
            }
        }
    }

    /// Past 128 every length is 128's magnified, the puck's gap too.
    @Test func thePuckMagnifiesPast128() throws {
        let small = try #require(layout(128, sidelined: 3).puck)
        let large = try #require(layout(256, tiles: 2, sidelined: 3).puck)
        #expect(large.frame.height == 2 * small.frame.height && large.cornerRadius == 2 * small.cornerRadius)
        let platter = layout(256, tiles: 2, sidelined: 3).platter
        #expect(large.frame.minX - platter.maxX == 24)
    }
}

/// How close the badges on the puck come to its outline, each label as short or as long as it gets.
private func puckBadgeClearance(_ layout: DockLayout) -> Double {
    guard let puck = layout.puck else { return .infinity }
    return layout.slots[layout.rowCount...].flatMap { slot in
        [0.0, 1000].map { text in
            clearance(DockMetrics(tileSize: slot.content.width).badgeFrame(textWidth: text, icon: slot.content), puck.frame, puck.cornerRadius)
        }
    }.min() ?? .infinity
}

/// How close the platter's own badges come to its outline at a tile size.
private func platterBadgeClearance(_ tile: Double) -> Double {
    let layout = DockLayout(metrics: DockMetrics(tileSize: tile), kinds: [.tile, .tile], screen: screen)
    return layout.slots.flatMap { slot in
        [0.0, 1000].map { text in
            clearance(DockMetrics(tileSize: tile).badgeFrame(textWidth: text, icon: slot.content), layout.platter, layout.metrics.cornerRadius)
        }
    }.min()!
}

/// The least distance from a badge, a capsule, to the inside of a rounded rect's outline: at one of its ends, since
/// the rect is convex.
private func clearance(_ badge: CGRect, _ frame: CGRect, _ radius: Double) -> Double {
    let r = Double(badge.height) / 2
    return [CGPoint(x: badge.minX + r, y: badge.midY), CGPoint(x: badge.maxX - r, y: badge.midY)].map { p in
        let corner = CGPoint(x: min(max(p.x, frame.minX + radius), frame.maxX - radius),
                             y: min(max(p.y, frame.minY + radius), frame.maxY - radius))
        let inside = corner.x != p.x && corner.y != p.y ? radius - Double(hypot(p.x - corner.x, p.y - corner.y))
            : Double(min(p.x - frame.minX, frame.maxX - p.x, p.y - frame.minY, frame.maxY - p.y))
        return inside - r
    }.min()!
}

@Suite struct FittingTests {
    /// The system Dock on this 1800 × 1169 screen at tile size 128, apps launched until it shrank: Finder's slot's
    /// x and width with that many tiles, the last of them the Trash behind the separator. It keeps its first slot
    /// a slot less 6pt from the screen's edge.
    @Test(arguments: [(11, 132.85, 134.0), (12, 119.398, 125.398), (13, 111.282, 117.282), (14, 104.152, 110.152),
                      (15, 97.84, 103.84), (16, 92.211, 98.211), (19, 78.475, 84.476), (20, 74.713, 80.713),
                      (23, 65.198, 71.198), (26, 57.691, 63.691), (29, 51.615, 57.615), (32, 46.598, 52.598),
                      (35, 42.385, 48.385), (38, 38.796, 44.796), (39, 37.715, 43.715)])
    func tilesShrinkAsTheSystemDocksDo(_ tiles: Int, _ x: Double, _ width: Double) {
        let kinds = Array(repeating: DockLayout.Kind.tile, count: tiles - 1) + [.separator, .tile]
        let layout = DockLayout(metrics: DockMetrics(tileSize: 128), kinds: kinds, screen: screen)
        #expect(abs(layout.metrics.tileWidth - width) < 0.5, "\(tiles) tiles: \(layout.metrics.tileWidth)")
        #expect(abs(layout.slots[0].frame.minX - x) < 1.5)
    }

    /// The puck gives first: a finer cut that fits keeps the dock centred.
    @Test func thePuckNarrowsFirst() throws {
        let metrics = DockMetrics(tileSize: 128)
        let wide = CGRect(x: 0, y: 0, width: 4000, height: 1000)
        let rule = try #require(DockLayout(metrics: metrics, kinds: Array(repeating: .tile, count: 8), sidelined: 12, screen: wide).puck)
        // Room for the platter centred and the puck at fifths, not quarters.
        let platter = metrics.platterWidth(tiles: 8)
        let room = platter / 2 + metrics.puckGap + rule.frame.width - 10 + metrics.screenMargin
        let tight = CGRect(x: 0, y: 0, width: 2 * room, height: 1000)
        let layout = DockLayout(metrics: metrics, kinds: Array(repeating: .tile, count: 8), sidelined: 12, screen: tight)
        #expect(layout.metrics.tileSize == 128 && layout.platter.midX == tight.midX)
        #expect(layout.puck?.packing.cut == 5)
        #expect(puckBadgeClearance(layout) >= metrics.puckBadgeClearance - 1e-6)
        #expect(try #require(layout.puck).frame.maxX <= tight.maxX - metrics.screenMargin)
    }

    /// Then the dock slides left of centre, just enough, the puck at its finest.
    @Test func thenTheDockSlidesLeft() throws {
        let metrics = DockMetrics(tileSize: 128)
        let layout = DockLayout(metrics: metrics, kinds: Array(repeating: .tile, count: 9), sidelined: 30, screen: screen)
        let puck = try #require(layout.puck)
        #expect(layout.metrics.tileSize == 128)
        #expect(layout.platter.midX < screen.midX && layout.platter.minX >= metrics.screenMargin)
        #expect(puck.frame.maxX <= screen.maxX - metrics.screenMargin && puck.frame.maxX > screen.maxX - metrics.screenMargin - 1)
        #expect(puckBadgeClearance(layout) >= metrics.puckBadgeClearance - 1e-6)
    }

    /// Then the tiles shrink, the puck with them.
    @Test func thenTheTilesShrink() throws {
        let layout = DockLayout(metrics: DockMetrics(tileSize: 256), kinds: Array(repeating: .tile, count: 5), sidelined: 4, screen: screen)
        let puck = try #require(layout.puck)
        #expect(layout.metrics.tileSize < 256)
        #expect(layout.platter.minX >= layout.metrics.screenMargin - 1e-9)
        #expect(puck.frame.maxX <= screen.maxX - layout.metrics.screenMargin + 1e-9)
    }

    /// A dock that fits stays as asked, centred.
    @Test func aDockThatFitsIsLeftAlone() {
        let layout = DockLayout(metrics: DockMetrics(tileSize: 128), kinds: Array(repeating: .tile, count: 4), sidelined: 2, screen: screen)
        #expect(layout.metrics.tileSize == 128 && layout.platter.midX == screen.midX)
    }
}

@Suite struct SidelineModelTests {
    let pinned = [app("mail"), app("zoom")]

    /// Sidelined apps leave the pinned and running apps; the puck has those running, in the list's order.
    @Test func sidelinedAppsLeaveTheRowForThePuck() {
        let running = [app("outlook"), app("zoom"), app("notes")]
        let sidelined = [app("zoom"), app("outlook"), app("teams")]
        let slots = DockModel.compose(pinned: pinned, running: running, sidelined: sidelined)
        #expect(slots == [.tile(.finder), .tile(.app(app("mail"))), .tile(.app(app("notes")))])
        #expect(DockModel.sideline(sidelined, running: running) == [app("zoom"), app("outlook")])
    }

    /// Hiding running apps hides none of the sidelined: sidelining is a choice of its own.
    @Test func showRunningOffKeepsTheSideline() {
        let slots = DockModel.compose(pinned: [], running: [app("zoom")], showRunning: false, sidelined: [app("zoom")])
        #expect(slots == [.tile(.finder)])
        #expect(DockModel.sideline([app("zoom"), .finder], running: [app("zoom"), .finder]) == [app("zoom")])
    }

    /// An app is pinned, sidelined or neither.
    @Test func choicesAreExclusive() {
        var choices = DockChoices(pinned: pinned, sidelined: [])
        choices.sideline(app("zoom"))
        #expect(choices.pinned == [app("mail")] && choices.sidelined == [app("zoom")])
        choices.pin([app("zoom")])
        #expect(choices.pinned == [app("mail"), app("zoom")] && choices.sidelined.isEmpty)
        choices.sideline(.finder)
        #expect(choices.sidelined.isEmpty)
        choices.sideline(app("outlook"))
        choices.unsideline(app("outlook"))
        #expect(choices.sidelined.isEmpty)
    }
}

@Suite struct BadgeFloorTests {
    /// The system Dock's badge measured 6, 9, 13 and 19pt at tile sizes 16, 24, 32 and 48: 25/64 of the icon, with
    /// no floor. dock2's never goes under 16, centred where the Dock's is.
    @Test func smallBadgesAreFlooredAboutTheDocksCentre() {
        let metrics = DockMetrics(tileSize: 24)
        let icon = CGRect(x: 0, y: 0, width: 24, height: 24)
        let frame = metrics.badgeFrame(textWidth: 4, icon: icon)
        #expect(metrics.badgeDiameter == 16 && metrics.badgeFontSize == 8)
        let dock = 24 * 25 / 64.0
        #expect(frame.midX == icon.maxX - dock / 2 && frame.midY == icon.maxY - dock / 2 && frame.width == 16)
        #expect(DockMetrics(tileSize: 41).badgeDiameter == 41 * 25 / 64.0)
        #expect(DockMetrics(tileSize: 40).badgeDiameter == 16)
    }

    /// A wider label still widens leftward, from the same right edge.
    @Test func aFlooredBadgeWidensLeftward() {
        let metrics = DockMetrics(tileSize: 24)
        let icon = CGRect(x: 0, y: 0, width: 24, height: 24)
        let one = metrics.badgeFrame(textWidth: 4, icon: icon), many = metrics.badgeFrame(textWidth: 14, icon: icon)
        #expect(many.maxX == one.maxX && many.width > one.width && many.width <= 24)
    }
}

@Suite struct MagnificationTests {
    /// Past 128 every length is its value at 128 times size / 128; the label stays the Dock's.
    @Test func at256EveryLengthIsTwice128s() {
        let small = DockMetrics(tileSize: 128), large = DockMetrics(tileSize: 256)
        let lengths: [(DockMetrics) -> Double] = [
            \.iconInset, \.tileWidth, \.platterHeight, \.cornerRadius, \.bottomGap, \.separatorWidth, \.separatorLineWidth,
            \.separatorLineHeight, \.hopHeight, \.dotDiameter, \.dotCenterHeight, \.platterRim, \.puckGap, \.screenMargin,
            \.badgeDiameter,
        ]
        for length in lengths { #expect(length(large) == 2 * length(small)) }
        #expect(large.cornerRadius == 56)
        #expect(large.platterWidth(tiles: 3) == 2 * small.platterWidth(tiles: 3))
    }

    @Test func belowTheCeilingNothingChanges() {
        let metrics = DockMetrics(tileSize: 95)
        #expect(metrics.magnification == 1 && metrics.tileWidth == 99 && metrics.platterHeight == 115)
    }
}
