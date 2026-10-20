import CoreGraphics
import Foundation

/// Where everything goes for a row of tiles on one screen. Cocoa's coordinates: points, origin at the
/// bottom left of the screen space, y up.
public struct DockLayout: Sendable, Equatable {
    public struct Tile: Sendable, Equatable {
        /// The tile's slot along the platter, the platter's full height.
        public var slot: CGRect
        /// The square the icon is drawn into.
        public var icon: CGRect
        /// The running indicator's circle, before snapping to the display's pixels.
        public var dot: CGRect
    }

    public let metrics: DockMetrics
    /// The glass, centred horizontally on the screen.
    public let platter: CGRect
    public let tiles: [Tile]

    public init(metrics: DockMetrics, tileCount: Int, screen: CGRect) {
        self.metrics = metrics
        let width = metrics.platterWidth(tiles: tileCount)
        let platter = CGRect(x: (screen.midX - width / 2).rounded(),
                             y: screen.minY + metrics.bottomGap,
                             width: width,
                             height: metrics.platterHeight)
        self.platter = platter
        let run = Double(tileCount) * metrics.tileWidth
        let firstX = platter.minX + (platter.width - run) / 2
        tiles = (0..<tileCount).map { index in
            let slot = CGRect(x: firstX + Double(index) * metrics.tileWidth, y: platter.minY,
                              width: metrics.tileWidth, height: platter.height)
            let icon = CGRect(x: slot.minX + metrics.iconInset,
                              y: platter.minY + (platter.height - metrics.tileSize) / 2,
                              width: metrics.tileSize, height: metrics.tileSize)
            let d = metrics.dotDiameter
            let dot = CGRect(x: slot.midX - d / 2, y: platter.minY + metrics.dotCenterHeight - d / 2,
                             width: d, height: d)
            return Tile(slot: slot, icon: icon, dot: dot)
        }
    }

    /// The tile under a point, if any: the whole slot counts, gaps between icons included.
    public func tileIndex(at point: CGPoint) -> Int? {
        guard platter.contains(point) else { return nil }
        return tiles.firstIndex { $0.slot.minX <= point.x && point.x < $0.slot.maxX }
    }
}

/// Snaps a rect's origin to the nearest device pixel, keeping its size: how the Dock places its dots.
public func pixelAligned(_ rect: CGRect, scale: Double) -> CGRect {
    CGRect(x: (rect.minX * scale).rounded() / scale, y: (rect.minY * scale).rounded() / scale,
           width: rect.width, height: rect.height)
}
