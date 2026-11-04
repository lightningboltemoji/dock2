import AppKit
import Dock2Core

/// The field's line, as the field and whatever takes its place lay it out (`PanelMetrics`): a symbol at the field's
/// own font size and weight, its ink centred on the glyph line; the text's ink from the text line; both centred on
/// the field's midline.
@MainActor
enum FieldLine {
    static var font: NSFont { .systemFont(ofSize: PanelMetrics.fieldFont) }

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: PanelMetrics.fieldFont, weight: .regular))
    }

    /// A symbol drawn at its own size, centred on the glyph line and the midline: SF Symbols centre their ink in
    /// their image.
    static func glyphFrame(for image: NSImage?, height: CGFloat) -> CGRect {
        let size = image?.size ?? .zero
        return CGRect(x: PanelMetrics.glyphCenter - size.width / 2, y: (height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The text's baseline above the field's bottom: its capitals centred on the midline, to the half point.
    static func baseline(_ font: NSFont, height: CGFloat) -> CGFloat {
        (height - font.capHeight).rounded() / 2
    }

    /// A text field's cell starts its text `NSTextField.textInset` in from its left and draws the baseline 2.5pt above
    /// its font's descender: measured, and taken off so the text lands on the line.
    static let cellInset = CGPoint(x: NSTextField.textInset, y: 2.5)

    /// A borderless text field whose text starts on the text line, its capitals on the midline, up to `end`.
    static func textFrame(_ font: NSFont, height: CGFloat, end: CGFloat) -> CGRect {
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up) + 2
        let x = PanelMetrics.textLeft - cellInset.x
        return CGRect(x: x, y: baseline(font, height: height) + font.descender - cellInset.y, width: max(0, end - x), height: lineHeight)
    }
}

extension NSTextField {
    /// How far in from its frame a text field's cell starts its text, a label's and an editable one's alike: measured.
    /// A line of text starts where its pen does, each glyph's own side bearing after it.
    static let textInset: CGFloat = 2
}
