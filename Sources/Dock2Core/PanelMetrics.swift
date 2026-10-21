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

    /// Files: three of Finder's columns and the preview, over its path bar
    /// ([panel](product/panel.md#sizes)).
    public static let filesSize = CGSize(width: 960, height: 520)

    /// The field, centred over the platter — as wide as search, or as the screen showing.
    public static func field(over platter: CGRect, width: CGFloat = fieldSize.width) -> CGRect {
        CGRect(x: (platter.midX - width / 2).rounded(), y: platter.maxY + gap, width: width, height: fieldSize.height)
    }

    /// Where the field grows from: a sliver along the platter's top edge.
    public static func seed(over platter: CGRect) -> CGRect {
        CGRect(x: platter.midX - 60, y: platter.maxY - 14, width: 120, height: 14)
    }
}
