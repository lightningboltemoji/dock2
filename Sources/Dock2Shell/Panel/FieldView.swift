import AppKit
import Dock2Core

/// The search field: the magnifier and a borderless text field, laid out as Spotlight's (PanelMetrics), drawn
/// over the panel's glass. Commands the text system sends — arrows, Return, Esc — go to `onCommand` first,
/// which is also where an input method's composition is respected.
@MainActor
final class FieldView: NSView, NSTextFieldDelegate {
    private let glyph = NSImageView()
    private let spinner = NSProgressIndicator()
    let text = NSTextField()
    var onTextChange: ((String) -> Void)?
    /// Returns true when it handled the command.
    var onCommand: ((Selector) -> Bool)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        let symbol = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(symbol)
        glyph.contentTintColor = .labelColor
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.setAccessibilityElement(false)
        addSubview(glyph)

        text.isBordered = false
        text.drawsBackground = false
        text.focusRingType = .none
        text.font = .systemFont(ofSize: PanelMetrics.fontSize)
        text.textColor = .labelColor
        text.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
            .font: NSFont.systemFont(ofSize: PanelMetrics.fontSize), .foregroundColor: NSColor.labelColor,
        ])
        text.cell?.usesSingleLineMode = true
        text.cell?.isScrollable = true
        text.delegate = self
        text.setAccessibilityLabel("Search")
        text.setAccessibilitySubrole(.searchField)
        addSubview(text)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let height = bounds.height
        // A symbol's image carries padding: its ink fills 80% of the view it is scaled into.
        let side = PanelMetrics.glyphSize / 0.8
        let center = CGPoint(x: PanelMetrics.glyphLeft + PanelMetrics.glyphSize / 2, y: height / 2 + PanelMetrics.glyphLift)
        glyph.frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        // The text field's cell insets its text 3.5pt from the left and draws the baseline 2.5pt above its
        // font's descender: measured, and taken off here so the ink lands where Spotlight's does.
        let font = text.font!
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up) + 2
        let bottom = PanelMetrics.baseline + font.descender - 2.5
        text.frame = CGRect(x: PanelMetrics.textLeft - 3.5, y: bottom, width: bounds.width - PanelMetrics.textLeft - 48, height: lineHeight)
        // At the trailing edge, as far in as the magnifier is from the leading one.
        spinner.frame = CGRect(x: bounds.width - PanelMetrics.glyphLeft - 16, y: center.y - 8, width: 16, height: 16)
    }

    /// The magnifier is decoration: the text field and the spinner are what VoiceOver meets.
    override func accessibilityChildren() -> [Any]? {
        super.accessibilityChildren()?.filter { child in (child as AnyObject) !== glyph && (child as AnyObject) !== glyph.cell }
    }

    /// A source still working after the first frame, or a view loading.
    func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// In a view the field is its filter, or — for a form — no use at all and dimmed.
    func setFilterMode(_ filters: Bool, placeholder: String?) {
        text.isEnabled = filters
        alphaValue = filters ? 1 : 0.5
        // A form's own fields take the keys: the field is only dimmed glass beneath it.
        let title = filters ? placeholder.map { "Search \($0)" } ?? "Search" : ""
        guard text.placeholderAttributedString?.string != title else { return }
        text.placeholderAttributedString = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: PanelMetrics.fontSize), .foregroundColor: NSColor.labelColor,
        ])
        // The field editor takes the placeholder as editing begins: begin again to show this one — once the
        // field is empty, where it shows, since beginning selects what was typed.
        placeholderPending = filters && text.currentEditor() != nil
        if placeholderPending, text.stringValue.isEmpty { beginAgain() }
    }

    /// A placeholder the field editor has yet to take.
    private var placeholderPending = false

    private func beginAgain() {
        placeholderPending = false
        text.window?.makeFirstResponder(text)
    }

    var string: String {
        get { text.stringValue }
        set {
            text.stringValue = newValue
            onTextChange?(newValue)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if placeholderPending, text.stringValue.isEmpty { beginAgain() }
        onTextChange?(text.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // While an input method composes, its keys are its own.
        if textView.hasMarkedText() { return false }
        return onCommand?(selector) ?? false
    }
}
