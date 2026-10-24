import CoreGraphics
import Foundation

/// Where everything goes for a row of tiles and separators on one screen. Cocoa's coordinates: points,
/// origin at the bottom left of the screen space, y up.
public struct DockLayout: Sendable, Equatable {
    /// What occupies a slot. A gap is a tile's width of nothing: where a dragged tile would land.
    public enum Kind: Sendable, Equatable {
        case tile, separator, gap
    }

    public struct Slot: Sendable, Equatable {
        public var kind: Kind
        /// The slot along the platter, the platter's full height.
        public var frame: CGRect
        /// A tile's icon square; a separator's line, or the lane round its dashes; empty for a gap.
        public var content: CGRect
        /// A tile's running indicator, before snapping to the display's pixels: the glass's dot, or the
        /// shelf's light.
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

    public let metrics: DockMetrics
    /// What is hit-tested, slid away and stood on by the label, centred horizontally on the screen: the
    /// glass, or the shelf's back edge up to the icons' tops.
    public let platter: CGRect
    public let slots: [Slot]
    /// Under Snow Leopard, the shelf.
    public let shelf: Shelf?

    public init(metrics: DockMetrics, kinds: [Kind], screen: CGRect) {
        self.metrics = metrics
        let widths = kinds.map { $0 == .separator ? metrics.separatorWidth : metrics.tileWidth }
        let run = widths.reduce(0, +)
        let width = metrics.platterWidth(run: run)
        let platter = CGRect(x: (screen.midX - width / 2).rounded(), y: screen.minY + metrics.bottomGap,
                             width: width, height: metrics.platterHeight)
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
        self.slots = slots
    }

    /// A row of `tileCount` tiles and nothing else.
    public init(metrics: DockMetrics, tileCount: Int, screen: CGRect) {
        self.init(metrics: metrics, kinds: Array(repeating: .tile, count: tileCount), screen: screen)
    }

    /// The tile slot under a point, if any: the whole slot counts, the air between icons included. A
    /// separator or a gap is no tile.
    public func tileIndex(at point: CGPoint) -> Int? {
        guard let index = slotIndex(at: point), slots[index].kind == .tile else { return nil }
        return index
    }

    /// The slot under a point on the platter.
    public func slotIndex(at point: CGPoint) -> Int? {
        guard platter.contains(point) else { return nil }
        return slots.firstIndex { $0.frame.minX <= point.x && point.x < $0.frame.maxX }
    }

    /// Where among `slots` a tile dropped at `x` would go: the index of the slot it would come before, by
    /// which half of a slot `x` is in.
    public func insertionIndex(at x: Double) -> Int {
        slots.firstIndex { x < $0.frame.midX } ?? slots.count
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
