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
        /// A tile's icon square; a separator's line; empty for a gap.
        public var content: CGRect
        /// A tile's running indicator, before snapping to the display's pixels.
        public var dot: CGRect
    }

    public let metrics: DockMetrics
    /// The glass, centred horizontally on the screen.
    public let platter: CGRect
    public let slots: [Slot]

    public init(metrics: DockMetrics, kinds: [Kind], screen: CGRect) {
        self.metrics = metrics
        let widths = kinds.map { $0 == .separator ? metrics.separatorWidth : metrics.tileWidth }
        let run = widths.reduce(0, +)
        let width = metrics.platterWidth(run: run)
        let platter = CGRect(x: (screen.midX - width / 2).rounded(), y: screen.minY + metrics.bottomGap,
                             width: width, height: metrics.platterHeight)
        self.platter = platter
        var x = platter.minX + (platter.width - run) / 2
        var slots: [Slot] = []
        for (kind, width) in zip(kinds, widths) {
            let frame = CGRect(x: x, y: platter.minY, width: width, height: platter.height)
            x += width
            switch kind {
            case .tile:
                let icon = CGRect(x: frame.minX + metrics.iconInset, y: platter.minY + (platter.height - metrics.tileSize) / 2,
                                  width: metrics.tileSize, height: metrics.tileSize)
                let d = metrics.dotDiameter
                let dot = CGRect(x: frame.midX - d / 2, y: platter.minY + metrics.dotCenterHeight - d / 2, width: d, height: d)
                slots.append(Slot(kind: kind, frame: frame, content: icon, dot: dot))
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
