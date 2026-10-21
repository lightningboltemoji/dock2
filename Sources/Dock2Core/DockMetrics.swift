import Foundation

/// The system Dock's geometry as a function of its tile size, measured from macOS 27's Dock at the
/// bottom of the screen with magnification off. Points throughout.
public struct DockMetrics: Sendable, Equatable {
    /// `com.apple.dock tilesize`: the side of the square an icon is drawn into.
    public let tileSize: Double

    /// The Dock's own limits on `tilesize`.
    public static let tileSizes: ClosedRange<Double> = 16...128
    /// What the Dock uses when `tilesize` was never written.
    public static let defaultTileSize = 48.0

    public init(tileSize: Double) {
        self.tileSize = min(max(tileSize, Self.tileSizes.lowerBound), Self.tileSizes.upperBound)
    }

    /// Air either side of an icon inside its tile: 1pt below 48, 2pt to 95, 3pt from 96.
    public var iconInset: Double { (tileSize / 48).rounded(.down) + 1 }

    /// One tile's slot along the platter.
    public var tileWidth: Double { tileSize + 2 * iconInset }

    /// The platter's height. Icons are centred in it vertically.
    public var platterHeight: Double { tileWidth + (tileSize < 48 ? 12 : 16) }

    /// The platter's continuous corner radius: a third of its height, up to 28pt.
    public var cornerRadius: Double { min(platterHeight / 3, 28) }

    /// From the bottom of the screen to the bottom of the platter.
    public var bottomGap: Double { 5 }

    /// The divider between groups of tiles, as wide as 0.45 of a tile.
    public var separatorWidth: Double { 0.45 * tileWidth }

    /// The divider's line: a point wide, from the slot's centre, centred on the platter. Measured at tile
    /// size 95, where it is 85 tall.
    public var separatorLineWidth: Double { 1 }
    public var separatorLineHeight: Double { tileSize - 10 }

    /// How high a launching app's icon hops: 24pt at tile size 95.
    public var hopHeight: Double { (tileSize / 4).rounded() }

    /// How far auto-hide moves the platter: from its place to just below the screen's edge.
    public var slideDistance: Double { platterHeight + bottomGap }

    /// The platter's width around a run of tiles and separators `run` points long: the run plus
    /// 2 × (inset + 6pt), rounded to an even number of points so both ends land on whole points when
    /// it is centred. Exact for tile sizes from 48 up; within a few points below.
    public func platterWidth(run: Double) -> Double {
        2 * ((run + 2 * (iconInset + 6)) / 2).rounded()
    }

    public func platterWidth(tiles: Int) -> Double {
        platterWidth(run: Double(tiles) * tileWidth)
    }

    /// The running indicator's diameter, centred under its tile.
    public var dotDiameter: Double { tileSize < 24 ? 3 : 4 }

    /// From the platter's bottom to the indicator's centre.
    public var dotCenterHeight: Double { tileSize < 24 ? 5.5 : 6 }
}
