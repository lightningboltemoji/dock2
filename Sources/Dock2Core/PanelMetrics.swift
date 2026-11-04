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
    /// what grew, this far in from the ground's edge and from the field, its corners concentric with the ground's.
    public static let sheetInset = 6.0
    public static let sheetRadius = fieldSize.height / 2 - sheetInset

    /// The panel's glass over its ground, for a body grown from a field `fieldHeight` tall.
    public struct Layering: Equatable, Sendable {
        /// The field's clear glass: the body itself until it grows, then a capsule drawn in from the ground's edge as
        /// it gives way to the ground.
        public var field: CGRect
        public var fieldRadius: CGFloat
        /// The pane over what grew, emerging from the field's top as the body grows.
        public var pane: CGRect
        public var paneRadius: CGFloat
        /// How solid the ground under them is, from 0, none, to 1.
        public var ground: Double
    }

    /// How far a body must grow past the field before its glass has drawn all the way in.
    static let layeringRamp = 22.0

    /// The field's glass and the pane over the ground, as the body — the field, or the panel grown from it —
    /// grows: not grown, the glass is the body itself and there is no ground; grown past `layeringRamp`, the
    /// field is the ground's, and the pane sits `sheetInset` in from the ground's edge, its foot at the field's top.
    public static func layering(body: CGRect, radius: CGFloat, fieldHeight: CGFloat) -> Layering {
        let grown = max(0, body.height - fieldHeight)
        let linear = min(1, max(0, (grown - 2) / layeringRamp))
        let t = linear * linear * (3 - 2 * linear)
        guard t > 0 else {
            return Layering(field: body, fieldRadius: radius, pane: CGRect(x: body.minX, y: body.maxY, width: body.width, height: 0),
                            paneRadius: radius, ground: 0)
        }
        let inset = sheetInset * t
        // Where the field's glass ends and the pane begins: the body's top until it grows, then the field's.
        let split = body.minY + fieldHeight + grown * (1 - t)
        let field = CGRect(x: body.minX + inset, y: body.minY + inset, width: body.width - 2 * inset, height: split - body.minY - 2 * inset)
        let pane = CGRect(x: body.minX + inset, y: split, width: body.width - 2 * inset, height: max(0, body.maxY - inset - split))
        return Layering(field: field, fieldRadius: field.height / 2, pane: pane, paneRadius: max(0, radius - inset), ground: t)
    }

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
