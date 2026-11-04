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

    /// Grown, the panel is a solid ground — the field's strip on it bare, as a bar — and a pane of glass laid over
    /// what grew, this far in from the ground's sides and top, its corners concentric with the ground's.
    public static let paneInset = 6.0
    public static let paneRadius = fieldSize.height / 2 - paneInset

    /// The panel's glass over its ground, for a body grown from a field `fieldHeight` tall.
    public struct Layering: Equatable, Sendable {
        /// The clear glass: the body, drawn in from the ground's edge as it gives way to the ground.
        public var clear: CGRect
        public var clearRadius: CGFloat
        /// The pane over what grew, its foot on the field's top.
        public var pane: CGRect
        public var paneRadius: CGFloat
        /// How solid the ground under them is, from 0, none, to 1.
        public var ground: Double
    }

    /// The clear glass and the pane over the ground, `ground` of the way from the one to the other
    /// (`FormFrame.ground`): both draw in from the body's edge as the ground comes, the pane to `paneInset`.
    public static func layering(body: CGRect, radius: CGFloat, fieldHeight: CGFloat, ground: Double) -> Layering {
        let inset = paneInset * ground
        let clear = body.insetBy(dx: inset, dy: inset)
        let split = body.minY + fieldHeight
        let pane = CGRect(x: clear.minX, y: split, width: clear.width, height: max(0, clear.maxY - split))
        return Layering(clear: clear, clearRadius: max(0, radius - inset), pane: pane, paneRadius: max(0, radius - inset), ground: ground)
    }

    /// The field, centred over the platter — as wide as search, or as the screen showing.
    public static func field(over platter: CGRect, width: CGFloat = fieldSize.width) -> CGRect {
        CGRect(x: (platter.midX - width / 2).rounded(), y: platter.maxY + gap, width: width, height: fieldSize.height)
    }

    /// The pane over `field`, in a panel grown `extent` above it: inset from the ground but for its foot, which
    /// meets the field.
    public static func pane(over field: CGRect, extent: CGFloat) -> CGRect {
        CGRect(x: field.minX + paneInset, y: field.maxY, width: field.width - 2 * paneInset, height: max(0, extent - paneInset))
    }
}
