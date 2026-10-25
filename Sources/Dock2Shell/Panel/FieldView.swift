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
    /// Every change of the text, before `onTextChange`: `cleared` when it was set rather than typed.
    var onEdit: ((_ old: String, _ new: String, _ cleared: Bool) -> Void)?
    /// What was there before a clear, drawn while the field's form draws it away (`play`).
    private let ghost = CALayer()
    private var edited = ""
    /// Where it takes clicks, when not everywhere: the form's, at rest.
    var hitArea: CGRect?

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

        ghost.opacity = 0
        ghost.contentsGravity = .bottomLeft
        layer!.addSublayer(ghost)
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
            let old = edited
            if newValue.isEmpty, !old.isEmpty { drawGhost(of: old) }
            text.stringValue = newValue
            edited = newValue
            onEdit?(old, newValue, true)
            onTextChange?(newValue)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if placeholderPending, text.stringValue.isEmpty { beginAgain() }
        let old = edited
        edited = text.stringValue
        onEdit?(old, edited, false)
        onTextChange?(text.stringValue)
    }

    // MARK: - The form

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hitArea, !hitArea.contains(convert(point, from: superview)) { return nil }
        return super.hitTest(point)
    }

    /// The text's width as drawn.
    var textWidth: CGFloat {
        (text.stringValue as NSString).size(withAttributes: [.font: text.font!]).width
    }

    /// The text field's inset to its ink, measured (`layout`).
    private static let inset: CGFloat = 3.5

    private func drawGhost(of string: String) {
        let attributed = NSAttributedString(string: string, attributes: [.font: text.font!, .foregroundColor: NSColor.labelColor])
        let size = attributed.size()
        let scale = window?.backingScaleFactor ?? 2
        guard size.width > 0, let rep = bitmapImageRepForCachingDisplay(in: CGRect(origin: .zero, size: size)) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        effectiveAppearance.performAsCurrentDrawingAppearance { attributed.draw(at: .zero) }
        NSGraphicsContext.restoreGraphicsState()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.contents = rep.cgImage
        ghost.contentsScale = scale
        // Where the text field draws its ink: its baseline, from the field's.
        let font = text.font!
        ghost.frame = CGRect(x: PanelMetrics.textLeft, y: PanelMetrics.baseline + font.descender, width: size.width, height: size.height)
        CATransaction.commit()
    }

    /// Moves the magnifier, the text and the spinner through the form's keyframes; the ghost of a cleared
    /// text with the text, when `ghosted`.
    func play(glyph glyphTrack: Keyframes<FormPlacement>, text textTrack: Keyframes<FormPlacement>, trailing: Keyframes<Double>,
              textWidth: CGFloat, ghosted: Bool) {
        guard let glyphLayer = glyph.layer, let textLayer = text.layer, let spinnerLayer = spinner.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inkCentre = CGPoint(x: Self.inset + textWidth / 2, y: textLayer.bounds.midY)
        Self.play(glyphTrack, on: glyphLayer, about: CGPoint(x: glyphLayer.bounds.midX, y: glyphLayer.bounds.midY))
        // Cleared, the field would show its placeholder: the ghost carries the text away, and the field stays hidden.
        let hidden = textTrack.map { placement in
            var placement = placement
            placement.alpha = 0
            return placement
        }
        Self.play(ghosted ? hidden : textTrack, on: textLayer, about: inkCentre)
        trailing.play(on: spinnerLayer, "opacity") { NSNumber(value: $0) }
        if ghosted {
            Self.play(textTrack, on: ghost, about: CGPoint(x: textWidth / 2, y: ghost.bounds.midY))
        } else {
            ghost.stopKeyframes(["transform", "opacity"])
        }
        CATransaction.commit()
    }

    func stopPlaying() {
        for layer in [glyph.layer, text.layer, ghost] { layer?.stopKeyframes(["transform", "opacity"]) }
        spinner.layer?.stopKeyframes(["opacity"])
    }

    /// Placed about `centre`, a point in the layer's bounds; the layer's own transform and opacity stay as
    /// AppKit set them, under the animation.
    private static func play(_ track: Keyframes<FormPlacement>, on layer: CALayer, about centre: CGPoint) {
        let size = layer.bounds.size, anchor = layer.anchorPoint
        let c = CGPoint(x: centre.x - anchor.x * size.width, y: centre.y - anchor.y * size.height)
        track.play(on: layer, "transform") { placement in
            let s = CGFloat(placement.scale)
            let t = CATransform3DConcat(CATransform3DMakeTranslation(-c.x, -c.y, 0), CATransform3DMakeScale(s, s, 1))
            return NSValue(caTransform3D: CATransform3DConcat(t, CATransform3DMakeTranslation(c.x + placement.offset.x, c.y + placement.offset.y, 0)))
        }
        track.play(on: layer, "opacity") { NSNumber(value: $0.alpha) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // While an input method composes, its keys are its own.
        if textView.hasMarkedText() { return false }
        return onCommand?(selector) ?? false
    }
}
