import CoreGraphics
import Foundation

/// The dock's geometry as a function of its tile size and style. The glass's was measured from macOS 27's
/// Dock at the bottom of the screen with magnification off; Snow Leopard's from Mac OS X 10.6's at tile size
/// 56, and grows in proportion. Points throughout.
public struct DockMetrics: Sendable, Equatable {
    /// `com.apple.dock tilesize`: the side of the square an icon is drawn into.
    public let tileSize: Double
    public let style: DockStyle

    /// The Dock's own limits on `tilesize`.
    public static let tileSizes: ClosedRange<Double> = 16...128
    /// What the Dock uses when `tilesize` was never written.
    public static let defaultTileSize = 48.0

    public init(tileSize: Double, style: DockStyle = .glass) {
        self.tileSize = min(max(tileSize, Self.tileSizes.lowerBound), Self.tileSizes.upperBound)
        self.style = style
    }

    /// Air either side of an icon inside its tile: 1pt below 48, 2pt to 95, 3pt from 96.
    public var iconInset: Double { (tileSize / 48).rounded(.down) + 1 }

    /// One tile's slot along the platter.
    public var tileWidth: Double { tileSize + 2 * iconInset }

    /// The platter's height. The glass's icons are centred in it; the shelf's is its footprint, from the
    /// screen's edge to the icons' tops.
    public var platterHeight: Double {
        switch style {
        case .glass: tileWidth + (tileSize < 48 ? 12 : 16)
        case .snowLeopard: iconLine - iconArtMargin + tileSize
        }
    }

    /// The platter's continuous corner radius: a third of its height, up to 28pt.
    public var cornerRadius: Double { min(platterHeight / 3, 28) }

    /// From the bottom of the screen to the bottom of the platter. The shelf stands on the screen's edge.
    public var bottomGap: Double { style == .glass ? 5 : 0 }

    /// The divider between groups of tiles, as wide as 0.45 of a tile; Snow Leopard's 31pt at tile size 56.
    public var separatorWidth: Double { style == .glass ? 0.45 * tileWidth : tileWidth * 31 / 60 }

    /// The divider's line: a point wide, from the slot's centre, centred on the platter. Measured at tile
    /// size 95, where it is 85 tall.
    public var separatorLineWidth: Double { 1 }
    public var separatorLineHeight: Double { tileSize - 10 }

    /// How high a launching app's icon hops: 24pt at tile size 95.
    public var hopHeight: Double { (tileSize / 4).rounded() }

    /// How far auto-hide moves the platter: from its place to just below the screen's edge.
    public var slideDistance: Double { platterHeight + bottomGap }

    /// The platter's width around a run of tiles and separators `run` points long: the run plus
    /// 2 × (inset + 6pt), or the shelf's margins, rounded to an even number of points so both ends land on
    /// whole points when it is centred. The glass's is exact for tile sizes from 48 up; within a few points below.
    public func platterWidth(run: Double) -> Double {
        let margin = style == .glass ? iconInset + 6 : shelfMargin
        return 2 * ((run + 2 * margin) / 2).rounded()
    }

    public func platterWidth(tiles: Int) -> Double {
        platterWidth(run: Double(tiles) * tileWidth)
    }

    /// The running indicator's diameter, centred under its tile.
    public var dotDiameter: Double { tileSize < 24 ? 3 : 4 }

    /// From the platter's bottom to the indicator's centre.
    public var dotCenterHeight: Double { tileSize < 24 ? 5.5 : 6 }

    // MARK: Snow Leopard's shelf, measured at tile size 56

    /// Snow Leopard's numbers at this tile size: those measured at 56, in proportion.
    private var shelfScale: Double { tileSize / 56 }

    /// From the screen's edge up to the shelf's back edge.
    public var shelfDepth: Double { 47.4 * shelfScale }

    /// How far the shelf's back edge reaches past the run of tiles, either side.
    public var shelfMargin: Double { 4.5 * shelfScale }

    /// How far the shelf's ends lean outward for each point down.
    public static let shelfSlant = 0.59

    /// The shelf's front edge, above the screen's: a dark seam a third of it, over light.
    public var lipHeight: Double { 3 * shelfScale }

    /// From the screen's edge up to the line the icons stand on, which their reflections mirror them about.
    public var iconLine: Double { 20.5 * shelfScale }

    /// From the screen's edge up to the line the floor mirrors the screen about: 0.6 above the back edge.
    public var mirrorLine: Double { 48 * shelfScale }

    /// How far a macOS icon's art sits inside its square: the icon grid's 100 of 1024 on every side. Snow
    /// Leopard's icons filled their squares, so on the shelf the art, not the square, stands on the line.
    public var iconArtMargin: Double { tileSize * 100 / 1024 }

    /// The running light's picture, centred under its tile on the screen's edge: a glow around a white core
    /// 8pt up, and its shine on the lip.
    public var lightSize: CGSize { CGSize(width: 32 * shelfScale, height: 16 * shelfScale) }

    /// The separator: a lane of eight dashes across the floor, equally spaced in perspective towards a point
    /// 30.05pt above the back edge, each 0.49 of its step long and 0.29 of its distance below that point wide.
    /// Each centred on x = 0, with y measured down from the back edge.
    public var laneDashes: [CGRect] {
        let horizon = 30.05 * shelfScale
        let first = 0.03007 / shelfScale, step = 0.002195 / shelfScale, half = 0.49 * step / 2
        return (0..<8).map { i in
            let middle = first - step * Double(i)
            let top = 1 / (middle + half) - horizon, bottom = 1 / (middle - half) - horizon
            let width = 0.29 * ((top + bottom) / 2 + horizon)
            return CGRect(x: -width / 2, y: top, width: width, height: bottom - top)
        }
    }

    // MARK: Badges and minimised windows, measured at tile sizes 64 and 128

    /// An app's badge is a red circle this wide: 50pt at tile size 128.
    public var badgeDiameter: Double { tileSize * 25 / 64 }

    /// Its label: the system font, regular, at half the badge's height.
    public var badgeFontSize: Double { badgeDiameter / 2 }

    /// The badge over `icon` for a label whose advance is `textWidth`: its top right on the icon's, widening
    /// leftward to keep 0.16 of its height either side of the label. It never outgrows the icon.
    public func badgeFrame(textWidth: Double, icon: CGRect) -> CGRect {
        let width = min(max(badgeDiameter, textWidth + 0.32 * badgeDiameter), icon.width)
        return CGRect(x: icon.maxX - width, y: icon.maxY - badgeDiameter, width: width, height: badgeDiameter)
    }

    /// A minimised window's picture: the window's shape, `aspect` wide to one high, fitted into a square
    /// 15/16 of the tile, centred on `icon`.
    public func windowFrame(aspect: Double, icon: CGRect) -> CGRect {
        let side = tileSize * 15 / 16
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 1
        let size = aspect >= 1 ? CGSize(width: side, height: side / aspect) : CGSize(width: side * aspect, height: side)
        return CGRect(x: icon.midX - size.width / 2, y: icon.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The icon of a minimised window's app: 3/8 of the tile, in `icon`'s bottom-right corner.
    public func windowAppIconFrame(icon: CGRect) -> CGRect {
        let side = tileSize * 3 / 8
        return CGRect(x: icon.maxX - tileSize / 64 - side, y: icon.minY + tileSize / 128, width: side, height: side)
    }
}
