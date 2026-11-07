import CoreGraphics
import Foundation

/// The panel's geometry, on one grid ([visual](product/visual.md#layout)): a stack of rows, the field the bottom
/// one, each layer nested in the one beneath — the ground, the pane `paneInset` in from it, a row's band `padding` in from
/// that, the icon's plate within the band — its corners concentric with that layer's. Placed over the dock.
public enum PanelMetrics {
    // MARK: - The grid

    /// Every inset, gap and row on the pane is a whole number of these.
    public static let unit = 4.0
    /// A row of search's results, and the field.
    public static let rowHeight = 56.0
    /// From the ground's edge to the pane's: the ground's rim, tuned by eye rather than on the grid; at 8 pt it looks off.
    public static let paneInset = 6.0
    /// From the pane's edge to what is on it: a row's band, a list's first row.
    public static let padding = 8.0
    /// The pane's corners are the field's ends; the ground's stand `paneInset` out from them.
    public static let paneRadius = rowHeight / 2
    public static let radius = paneRadius + paneInset
    /// From the pane's edge to what is too small to share its corners: Files' rows' bands, a card. A band's corner this far
    /// in stands at least `padding` from the pane's turn, as a band stands from its straight edge.
    public static let cornerInset = 12.0
    /// A card, `cornerInset` in, concentric with the pane.
    public static let cardRadius = paneRadius - cornerInset

    /// A row in a list on the pane. Its icon stands in a square as tall as the row, as far from the band's side as
    /// from its top and bottom, and its text starts where the square ends; its trailing end mirrors its leading one.
    public struct Row: Equatable, Sendable {
        public var height: Double
        /// What shows of the icon: an app icon's plate, a picture, a symbol.
        public var plate: Double
        public var title: Double
        public var subtitle: Double

        /// From the pane's edge: the band, the plate, the plate's centre, the text.
        public var bandX: Double { PanelMetrics.padding }
        public var plateX: Double { bandX + (height - plate) / 2 }
        public var glyphX: Double { bandX + height / 2 }
        public var textX: Double { bandX + height }
        /// The band's corners, concentric with the plate's, which are about a quarter of it.
        public var bandRadius: Double { height / 2 - plate / 4 }
        /// From the pane's other edge to where the row's text and marks stop.
        public var trailingX: Double { plateX }

        public static let regular = Row(height: rowHeight, plate: 32, title: titleFont, subtitle: detailFont)
        /// Beside a preview.
        public static let compact = Row(height: 36, plate: 20, title: 13, subtitle: 11)
    }

    /// From the panel's edge, the two lines everything leading stands on: the icons' centres and the magnifier's,
    /// and where titles and the field's text start.
    public static let glyphLine = paneInset + Row.regular.glyphX
    public static let textLine = paneInset + Row.regular.textX
    /// From either edge of the panel, its margin: where the icons and sections' titles start, and where the rows'
    /// trailing text and marks, and the field's bar, stop.
    public static let margin = paneInset + Row.regular.plateX

    // MARK: - Type

    public static let fieldFont = 22.0
    public static let titleFont = 16.0
    public static let detailFont = 13.0
    /// A section's title, semibold.
    public static let headingFont = 12.0

    // MARK: - The field

    /// The field alone: a circular capsule, a row tall.
    public static let fieldSize = CGSize(width: 640, height: rowHeight)
    /// The magnifier, the field's own font size and weight, centred on the glyph line and the field's midline. Its
    /// ink: SF Symbols' magnifyingglass at 22pt, regular, measured.
    public static let glyphSize = 21.75
    public static let glyphCenter = glyphLine
    public static var glyphLeft: Double { glyphCenter - glyphSize / 2 }
    /// The text's ink, from the text line, its capitals centred on the field's midline.
    public static let textLeft = textLine
    /// From the platter's top to the field's bottom: room for a label between, 9pt either side of it.
    public static let gap = LabelMetrics.liftAbovePlatter + LabelMetrics.height + LabelMetrics.liftAbovePlatter

    /// Files: three columns and the preview, over its bar ([panel](product/panel.md#sizes)).
    public static let filesSize = CGSize(width: 960, height: 520)

    /// The panel's glass over its ground, for a body grown from a field `fieldHeight` tall.
    /// Widths that fit `room`, each as near what it asks as the others allow: the narrow keep theirs and the widest give
    /// way evenly, none below `floor` unless it asks for less.
    public static func fit(_ asked: [CGFloat], into room: CGFloat, floor: CGFloat) -> [CGFloat] {
        var left = room
        var waiting = CGFloat(asked.count)
        for width in asked.sorted() {
            let share = left / waiting
            if width > share {
                let most = max(floor, share.rounded(.down))
                return asked.map { min($0, most) }
            }
            left -= width
            waiting -= 1
        }
        return asked
    }

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

    /// The pane over `field`, in a panel grown `extent` above it: `paneInset` in from the ground but for its foot, which
    /// meets the field.
    public static func pane(over field: CGRect, extent: CGFloat) -> CGRect {
        CGRect(x: field.minX + paneInset, y: field.maxY, width: field.width - 2 * paneInset, height: max(0, extent - paneInset))
    }
}
