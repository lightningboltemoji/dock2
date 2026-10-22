import AppKit

/// A menu row of a label and pills, at most one of them lit: a choice made before the item it applies to.
/// Highlighted, it takes the keys — ← → between the pills, ↩ or space to light one — and passes the rest
/// on, so ↑ ↓ still move through the menu and ← past the first pill closes a submenu.
@MainActor
final class MenuPills: NSView {
    private let label: String
    private let titles: [String]
    /// The pill lit.
    private(set) var selected: Int? { didSet { needsDisplay = true } }
    /// The pill the keys are on: ringed.
    private var focused: Int? { didSet { needsDisplay = true } }
    private var takesKeys = false

    private static let font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
    /// Lined up with the items' own content.
    private static let inset: CGFloat = 14
    private static let pillHeight: CGFloat = 20
    private static let pillPadding: CGFloat = 9
    private static let gap: CGFloat = 6

    init(label: String, titles: [String]) {
        self.label = label
        self.titles = titles
        super.init(frame: .zero)
        let last = Self.rects(label: label, titles: titles).last?.maxX ?? 0
        frame = NSRect(x: 0, y: 0, width: last + Self.inset, height: Self.pillHeight + 10)
        autoresizingMask = .width
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// The menu highlighted this row, or moved off it. A key moving onto it rings the first pill.
    func highlight(_ on: Bool) {
        takesKeys = on
        if on {
            window?.makeFirstResponder(self)
            if NSApp.currentEvent?.type == .keyDown { focused = focused ?? 0 }
        } else {
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            focused = nil
        }
    }

    override var acceptsFirstResponder: Bool { takesKeys }

    override func keyDown(with event: NSEvent) {
        switch (event.specialKey, focused) {
        case (.leftArrow?, nil), (.rightArrow?, nil): focused = 0
        case (.leftArrow?, let at?) where at > 0: focused = at - 1
        case (.rightArrow?, let at?) where at < titles.count - 1: focused = at + 1
        case (.carriageReturn?, let at?), (.enter?, let at?): toggle(at)
        case (nil, let at?) where event.charactersIgnoringModifiers == " ": toggle(at)
        default: super.keyDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = pillRects.firstIndex(where: { $0.contains(point) }) { toggle(index) }
    }

    private func toggle(_ index: Int) {
        selected = selected == index ? nil : index
    }

    // MARK: - Drawing

    private var pillRects: [NSRect] { Self.rects(label: label, titles: titles) }

    private static func rects(label: String, titles: [String]) -> [NSRect] {
        var x = inset + width(label) + 8
        return titles.map { title in
            defer { x += width(title) + pillPadding * 2 + gap }
            return NSRect(x: x, y: 5, width: width(title) + pillPadding * 2, height: pillHeight)
        }
    }

    private static func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rects = pillRects
        draw(label, centredIn: NSRect(x: Self.inset, y: rects[0].minY, width: Self.width(label), height: Self.pillHeight),
             color: .secondaryLabelColor)
        for (index, rect) in rects.enumerated() {
            let lit = selected == index
            (lit ? NSColor.controlAccentColor : PillButton.ink(0.08)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            if focused == index {
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), xRadius: rect.height / 2 + 3, yRadius: rect.height / 2 + 3)
                ring.lineWidth = 2
                NSColor.controlAccentColor.setStroke()
                ring.stroke()
            }
            draw(titles[index], centredIn: rect, color: lit ? .alternateSelectedControlTextColor : .labelColor)
        }
    }

    private func draw(_ text: String, centredIn rect: NSRect, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    // MARK: - Accessibility

    override func accessibilityChildren() -> [Any]? {
        pillRects.enumerated().map { index, rect in
            let pill = PillElement()
            pill.setAccessibilityRole(.radioButton)
            pill.setAccessibilityLabel(titles[index])
            pill.setAccessibilityValue(selected == index ? 1 : 0)
            pill.setAccessibilityParent(self)
            pill.setAccessibilityFrameInParentSpace(rect)
            pill.press = { [weak self] in self?.toggle(index) }
            return pill
        }
    }

    private final class PillElement: NSAccessibilityElement {
        var press: () -> Void = {}
        override func accessibilityPerformPress() -> Bool {
            press()
            return true
        }
    }
}
