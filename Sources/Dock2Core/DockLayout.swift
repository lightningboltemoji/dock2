import CoreGraphics
import Foundation

/// Where everything goes for a row of tiles and separators on one screen, and the sideline's puck beside it.
/// Cocoa's coordinates: points, origin at the bottom left of the screen space, y up.
public struct DockLayout: Sendable, Equatable {
    /// What occupies a slot. A gap is a tile's width of nothing: where a dragged tile would land.
    public enum Kind: Sendable, Equatable {
        case tile, separator, gap
    }

    public struct Slot: Sendable, Equatable {
        public var kind: Kind
        /// The slot along the platter, the platter's full height; on the puck, its cell.
        public var frame: CGRect
        /// A tile's icon square; a separator's line, or the lane round its dashes; empty for a gap.
        public var content: CGRect
        /// A tile's running indicator, before snapping to the display's pixels: the glass's dot, or the
        /// shelf's light. Empty on the puck, where every app runs.
        public var dot: CGRect
        /// A separator's dashes across the shelf; none on the glass.
        public var dashes: [CGRect] = []
    }

    /// Snow Leopard's shelf, under the tiles: a floor from the screen's edge to a back edge as wide as the
    /// platter, its ends leaning out by `lean` from there to the front.
    public struct Shelf: Sendable, Equatable {
        public var floor: CGRect
        public var lean: Double
        /// The icons' bottom edges, which their reflections mirror them about.
        public var iconLine: Double
        /// The top of the lip: the floor's reflections end here.
        public var lipTop: Double
        /// The line the floor mirrors the screen about, a little above the back edge.
        public var mirrorLine: Double

        /// Where the floor's light grey gives way to the darker one in front of it, `t` of the way across from its
        /// left end. Leopard's floor picture steps along an S and is stretched end to end at every height, so the
        /// S spans the shelf at any width.
        public func floorStep(across t: Double) -> CGPoint {
            let depth = Self.floorStepDepth.reduce(0) { $0 * t + $1 }
            let y = floor.maxY - depth * floor.height
            let inset = lean * (y - floor.minY) / floor.height
            return CGPoint(x: floor.minX + inset + t * (floor.width - 2 * inset), y: y)
        }

        /// The S in Leopard's floor picture (`scurve-*.png`): its depth below the back edge, as a fraction of the
        /// shelf's, against the fraction of the way across.
        private static let floorStepDepth = [75.8646, -258.655, 332.027, -193.545, 51.1466, -9.20681, 2.65955, 0.355178]
    }

    /// The sideline's piece of glass, right of the platter across `DockMetrics.puckGap`, on its baseline.
    public struct Puck: Sendable, Equatable {
        public var frame: CGRect
        /// The platter's.
        public var cornerRadius: Double
        public var packing: SidelinePacking
        /// A sidelined tile's: a tile at its icon's size.
        public var metrics: DockMetrics { DockMetrics(tileSize: packing.icon) }
    }

    /// The tile size the dock fits the screen at: the one asked for, or smaller (`fit`).
    public let metrics: DockMetrics
    /// What is hit-tested, slid away and stood on by the label: the glass, or the shelf's back edge up to the
    /// icons' tops. Centred on the screen unless the puck needs the room.
    public let platter: CGRect
    /// The platter's slots, left to right, then the puck's in the order its apps fill it.
    public let slots: [Slot]
    /// How many of `slots` are the platter's.
    public let rowCount: Int
    /// Under Snow Leopard, the shelf.
    public let shelf: Shelf?
    /// The sideline's puck, while it holds an app.
    public let puck: Puck?

    /// The row of `kinds`, and `sidelined` apps on the glass's puck, fitted to `screen`.
    public init(metrics: DockMetrics, kinds: [Kind], sidelined: Int = 0, screen: CGRect) {
        precondition(sidelined == 0 || metrics.style == .glass, "the shelf has no sideline")
        let fit = Self.fit(metrics: metrics, kinds: kinds, sidelined: sidelined, screen: screen)
        let metrics = fit.metrics
        self.metrics = metrics
        let widths = kinds.map { $0 == .separator ? metrics.separatorWidth : metrics.tileWidth }
        let run = widths.reduce(0, +)
        let platter = CGRect(x: fit.platterX, y: screen.minY + metrics.bottomGap,
                             width: metrics.platterWidth(run: run), height: metrics.platterHeight)
        self.platter = platter
        let shelved = metrics.style == .snowLeopard
        let lean = DockMetrics.shelfSlant * metrics.shelfDepth
        shelf = shelved ? Shelf(floor: CGRect(x: platter.minX - lean, y: platter.minY, width: platter.width + 2 * lean,
                                              height: metrics.shelfDepth),
                                lean: lean, iconLine: platter.minY + metrics.iconLine, lipTop: platter.minY + metrics.lipHeight,
                                mirrorLine: platter.minY + metrics.mirrorLine)
            : nil
        var x = platter.minX + (platter.width - run) / 2
        var slots: [Slot] = []
        for (kind, width) in zip(kinds, widths) {
            let frame = CGRect(x: x, y: platter.minY, width: width, height: platter.height)
            x += width
            switch kind {
            case .tile:
                let bottom = shelved ? metrics.iconLine - metrics.iconArtMargin : (platter.height - metrics.tileSize) / 2
                let icon = CGRect(x: frame.minX + metrics.iconInset, y: platter.minY + bottom,
                                  width: metrics.tileSize, height: metrics.tileSize)
                let d = metrics.dotDiameter, light = metrics.lightSize
                let dot = shelved
                    ? CGRect(x: frame.midX - light.width / 2, y: platter.minY, width: light.width, height: light.height)
                    : CGRect(x: frame.midX - d / 2, y: platter.minY + metrics.dotCenterHeight - d / 2, width: d, height: d)
                slots.append(Slot(kind: kind, frame: frame, content: icon, dot: dot))
            case .separator where shelved:
                let back = platter.minY + metrics.shelfDepth
                let dashes = metrics.laneDashes.map { dash in
                    CGRect(x: frame.midX + dash.minX, y: back - dash.maxY, width: dash.width, height: dash.height)
                }
                let lane = dashes.reduce(CGRect.null) { $0.union($1) }
                slots.append(Slot(kind: kind, frame: frame, content: lane, dot: .zero, dashes: dashes))
            case .separator:
                let height = metrics.separatorLineHeight
                let line = CGRect(x: frame.midX, y: platter.midY - height / 2, width: metrics.separatorLineWidth, height: height)
                slots.append(Slot(kind: kind, frame: frame, content: line, dot: .zero))
            case .gap:
                slots.append(Slot(kind: kind, frame: frame, content: .zero, dot: .zero))
            }
        }
        rowCount = slots.count
        puck = fit.packing.map { Self.puck($0, metrics: metrics, platter: platter) }
        if let puck {
            let cells = puck.frame.insetBy(dx: (puck.frame.width - Double(puck.packing.columns) * puck.packing.cell) / 2,
                                           dy: (puck.frame.height - Double(puck.packing.rows) * puck.packing.cell) / 2)
            let icon = puck.packing.icon
            for index in 0..<sidelined {
                let (row, column) = puck.packing.place(of: index)
                let cell = CGRect(x: cells.minX + Double(column) * puck.packing.cell, y: cells.minY + Double(row) * puck.packing.cell,
                                  width: puck.packing.cell, height: puck.packing.cell)
                slots.append(Slot(kind: .tile, frame: cell, content: cell.insetBy(dx: (cell.width - icon) / 2, dy: (cell.height - icon) / 2),
                                  dot: .zero))
            }
        }
        self.slots = slots
    }

    private static func puck(_ packing: SidelinePacking, metrics: DockMetrics, platter: CGRect) -> Puck {
        Puck(frame: CGRect(origin: CGPoint(x: platter.maxX + metrics.puckGap, y: platter.minY), size: puckSize(packing, metrics: metrics)),
             cornerRadius: metrics.cornerRadius, packing: packing)
    }

    /// The puck around `packing`'s cells, centred in it: the platter's rims above and below and its margins either
    /// side, grown where the top right cell's badge would come within `puckBadgeClearance` of the edge or of the
    /// corner's curve — upward only as far as the platter's height — and never smaller than its corners.
    private static func puckSize(_ packing: SidelinePacking, metrics: DockMetrics) -> CGSize {
        let cells = CGSize(width: Double(packing.columns) * packing.cell, height: Double(packing.rows) * packing.cell)
        let (corner, clearance) = (metrics.cornerRadius, metrics.puckBadgeClearance)
        // The badge's circle, from the cells' top right: its centre `right` and `top` in, and its radius.
        let inset = (packing.cell - packing.icon) / 2
        let icon = CGRect(x: -inset - packing.icon, y: -inset - packing.icon, width: packing.icon, height: packing.icon)
        let badge = DockMetrics(tileSize: packing.icon).badgeFrame(textWidth: 0, icon: icon)
        let (right, top, radius) = (-badge.midX, -badge.midY, badge.height / 2)
        let rim = min((metrics.platterHeight - cells.height) / 2,
                      max(metrics.platterRim, clearance + radius - top, corner - cells.height / 2))
        // How far in from the right edge the circle's centre clears the corner's curve, at its depth below the top.
        let (depth, reach) = (rim + top, corner - radius - clearance)
        let curve = depth >= corner ? 0 : corner - (reach > corner - depth ? (reach * reach - (corner - depth) * (corner - depth)).squareRoot() : 0)
        let side = max(metrics.platterMargin, clearance + radius - right, curve - right, corner - cells.width / 2)
        return CGSize(width: (cells.width + 2 * side).rounded(.up), height: cells.height + 2 * rim)
    }

    /// The tile size, the puck's packing and the platter's left end at which the dock fits `screen`, its ends
    /// `DockMetrics.screenMargin` in from its edges. Centred, with the puck as it packs, if that fits; if not, the
    /// puck's cells go finer, then the dock slides left of centre, then the tiles shrink, as the system Dock's do.
    private static func fit(metrics: DockMetrics, kinds: [Kind], sidelined: Int, screen: CGRect)
        -> (metrics: DockMetrics, packing: SidelinePacking?, platterX: Double) {
        func arrange(_ metrics: DockMetrics, regardless: Bool = false) -> (metrics: DockMetrics, packing: SidelinePacking?, platterX: Double)? {
            let run = kinds.reduce(0) { $0 + ($1 == .separator ? metrics.separatorWidth : metrics.tileWidth) }
            let width = metrics.platterWidth(run: run)
            let centred = (screen.midX - width / 2).rounded()
            let (low, high) = (screen.minX + metrics.screenMargin, screen.maxX - metrics.screenMargin)
            let packings: [SidelinePacking?] = SidelinePacking(count: sidelined, metrics: metrics)
                .map { [$0] + $0.finer(holding: sidelined, metrics: metrics) } ?? [nil]
            let beside = { (packing: SidelinePacking?) in packing.map { metrics.puckGap + puckSize($0, metrics: metrics).width } ?? 0 }
            if centred >= low, let packing = packings.first(where: { centred + width + beside($0) <= high }) {
                return (metrics, packing, centred)
            }
            let packing = packings.last!
            let slid = (high - width - beside(packing)).rounded(.down)
            if slid >= low { return (metrics, packing, slid) }
            return regardless ? (metrics, packing, max(screen.minX, min(centred, slid))) : nil
        }
        if let fitted = arrange(metrics) { return fitted }
        let smallest = DockMetrics(tileSize: DockMetrics.tileSizes.lowerBound, style: metrics.style)
        guard arrange(smallest) != nil else { return arrange(smallest, regardless: true)! }
        var (fits, overflows) = (smallest.tileSize, metrics.tileSize)
        while overflows - fits > 0.01 {
            let middle = (fits + overflows) / 2
            if arrange(DockMetrics(tileSize: middle, style: metrics.style)) != nil { fits = middle } else { overflows = middle }
        }
        return arrange(DockMetrics(tileSize: fits, style: metrics.style))!
    }

    /// A row of `tileCount` tiles and nothing else.
    public init(metrics: DockMetrics, tileCount: Int, screen: CGRect) {
        self.init(metrics: metrics, kinds: Array(repeating: .tile, count: tileCount), screen: screen)
    }

    /// Whether a slot is on the puck.
    public func isSidelined(_ index: Int) -> Bool { index >= rowCount }

    /// The top of the glass a slot is on, which its label stands over: the platter's, or the puck's.
    public func top(of index: Int) -> Double {
        isSidelined(index) ? puck?.frame.maxY ?? platter.maxY : platter.maxY
    }

    /// The platter and the puck together.
    public var extent: CGRect { puck.map { platter.union($0.frame) } ?? platter }

    /// On the platter or the puck: what the pointer is on the dock over.
    public func contains(_ point: CGPoint) -> Bool {
        platter.contains(point) || puck?.frame.contains(point) == true
    }

    /// The tile slot under a point, if any: the whole slot or cell counts, the air between icons included. A
    /// separator or a gap is no tile.
    public func tileIndex(at point: CGPoint) -> Int? {
        guard let index = slotIndex(at: point), slots[index].kind == .tile else { return nil }
        return index
    }

    /// The slot under a point on the platter or the puck.
    public func slotIndex(at point: CGPoint) -> Int? {
        guard contains(point) else { return nil }
        return slots.firstIndex { $0.frame.contains(point) }
    }

    /// Where along the platter's slots a tile dropped at `x` would go: the index of the slot it would come
    /// before, by which half of a slot `x` is in.
    public func insertionIndex(at x: Double) -> Int {
        slots[..<rowCount].firstIndex { x < $0.frame.midX } ?? rowCount
    }
}

/// Snaps a rect's origin to the nearest device pixel, keeping its size: how the Dock places its dots.
public func pixelAligned(_ rect: CGRect, scale: Double) -> CGRect {
    CGRect(x: (rect.minX * scale).rounded() / scale, y: (rect.minY * scale).rounded() / scale,
           width: rect.width, height: rect.height)
}

/// Snaps a rect's origin and size to whole device pixels, so an icon drawn at its size lands one to one.
public func pixelSnapped(_ rect: CGRect, scale: Double) -> CGRect {
    CGRect(x: (rect.minX * scale).rounded() / scale, y: (rect.minY * scale).rounded() / scale,
           width: (rect.width * scale).rounded() / scale, height: (rect.height * scale).rounded() / scale)
}
