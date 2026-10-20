import CoreGraphics
import Foundation

/// The name bubble over a hovered tile, measured from macOS 27's Dock: a glass capsule with a
/// right-angled arrow pointing down at the tile.
public enum LabelMetrics {
    /// The system font at this size, regular weight.
    public static let fontSize = 14.0
    /// The capsule's height; its ends are semicircles.
    public static let height = 25.5
    /// Either side of the text, before the width is rounded to a whole point.
    public static let padding = 13.25
    /// From the capsule's bottom to where the arrow's straight sides would meet.
    public static let arrowDepth = 7.6
    /// The rounding of the arrow's tip.
    public static let arrowTipRadius = 1.8
    /// From the platter's top to the capsule's bottom.
    public static let liftAbovePlatter = 9.5

    public static func width(forText textWidth: Double) -> Double {
        (textWidth + 2 * padding).rounded()
    }

    /// The capsule, centred over `centerX` on whole points.
    public static func body(textWidth: Double, centerX: Double, platterTop: Double) -> CGRect {
        let width = width(forText: textWidth)
        return CGRect(x: (centerX - width / 2).rounded(), y: platterTop + liftAbovePlatter,
                      width: width, height: height)
    }
}
