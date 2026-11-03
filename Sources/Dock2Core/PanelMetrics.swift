import CoreGraphics
import Foundation

/// The panel's geometry, started from Spotlight's on macOS 27 — its field measured off a screenshot — and
/// placed over the dock.
public enum PanelMetrics {
    /// The field alone: a circular capsule.
    public static let fieldSize = CGSize(width: 640, height: 57)
    /// The magnifier's ink: 23pt square, from 22.5pt in, its centre 0.75pt above the field's.
    public static let glyphLeft = 22.5
    public static let glyphSize = 23.0
    public static let glyphLift = 0.75
    /// The text: the system font at 26pt, regular, from 63pt in, its baseline 19.5pt above the bottom.
    public static let fontSize = 26.0
    public static let textLeft = 63.0
    public static let baseline = 19.5
    /// From the platter's top to the field's bottom: room for a label between, 9pt either side of it.
    public static let gap = LabelMetrics.liftAbovePlatter + LabelMetrics.height + LabelMetrics.liftAbovePlatter

    /// Files: three columns and the preview, over its bar ([panel](product/panel.md#sizes)).
    public static let filesSize = CGSize(width: 960, height: 520)

    /// A screen's sheet sits this far in from the glass's sides and top, its corners concentric with the panel's.
    public static let sheetInset = 8.0
    public static let sheetRadius = fieldSize.height / 2 - sheetInset

    /// The field, centred over the platter — as wide as search, or as the screen showing.
    public static func field(over platter: CGRect, width: CGFloat = fieldSize.width) -> CGRect {
        CGRect(x: (platter.midX - width / 2).rounded(), y: platter.maxY + gap, width: width, height: fieldSize.height)
    }

    /// A screen's sheet over `field`, in a panel grown `extent` above it: inset from the glass but for its
    /// foot, which meets the field's glass.
    public static func sheet(over field: CGRect, extent: CGFloat) -> CGRect {
        CGRect(x: field.minX + sheetInset, y: field.maxY, width: field.width - 2 * sheetInset, height: max(0, extent - sheetInset))
    }
}
