import AppKit

/// A place in the places' pop-up that ejects — a disk, a server — with ⏏ where an item's key would be, as
/// Finder's sidebar has it. An item with a view draws nothing of its own, so this draws a menu item: the
/// selection material when highlighted, the check, the title, at a menu item's measured insets.
@MainActor
final class PlaceMenuRow: NSView {
    private let selection = NSVisualEffectView()
    private let check = NSImageView()
    private let label: NSTextField
    private let eject = NSButton()
    private let onChoose: () -> Void
    private let onEject: () -> Void
    private var takesKeys = false

    static let height: CGFloat = 24
    /// Measured against the items beside it: a title 30 pt in (a label draws 2 pt inside its frame), a key
    /// ending 18 pt from the right, a highlight inset 5 pt with a 7 pt radius.
    private static let titleInset: CGFloat = 28
    private static let trailingInset: CGFloat = 18
    private static let highlightInset: CGFloat = 5

    init(title: String, checked: Bool, choose: @escaping () -> Void, eject: @escaping () -> Void) {
        label = NSTextField(labelWithString: title)
        onChoose = choose
        onEject = eject
        super.init(frame: .zero)
        selection.material = .selection
        selection.state = .active
        selection.isEmphasized = true
        selection.blendingMode = .behindWindow
        selection.wantsLayer = true
        selection.layer?.cornerRadius = 7
        selection.layer?.cornerCurve = .continuous
        selection.isHidden = true
        addSubview(selection)
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        check.isHidden = !checked
        addSubview(check)
        label.font = .menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        self.eject.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject \(title)")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        self.eject.isBordered = false
        self.eject.imagePosition = .imageOnly
        self.eject.target = self
        self.eject.action = #selector(ejectPressed)
        self.eject.toolTip = "Eject"
        addSubview(self.eject)
        let width = Self.titleInset + ceil(label.intrinsicContentSize.width) + 40 + 16 + Self.trailingInset
        frame = NSRect(x: 0, y: 0, width: width, height: Self.height)
        autoresizingMask = .width
        tint(highlighted: false)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// The menu highlighted this row, or moved off it; highlighted from the keys, it takes ↩.
    func highlight(_ on: Bool) {
        selection.isHidden = !on
        tint(highlighted: on)
        takesKeys = on
        if on {
            window?.makeFirstResponder(self)
        } else if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    override var acceptsFirstResponder: Bool { takesKeys }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .carriageReturn?, .enter?: choose()
        default: super.keyDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !eject.frame.contains(point) { choose() }
    }

    @objc private func ejectPressed() {
        enclosingMenuItem?.menu?.cancelTracking()
        onEject()
    }

    private func choose() {
        enclosingMenuItem?.menu?.cancelTracking()
        onChoose()
    }

    private func tint(highlighted: Bool) {
        label.textColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        check.contentTintColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        eject.contentTintColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        selection.frame = bounds.insetBy(dx: Self.highlightInset, dy: 0)
        check.frame = CGRect(x: 11, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let titleHeight = label.intrinsicContentSize.height
        eject.frame = CGRect(x: bounds.width - Self.trailingInset - 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = CGRect(x: Self.titleInset, y: (bounds.height - titleHeight) / 2, width: eject.frame.minX - 8 - Self.titleInset,
                             height: titleHeight)
    }

    override func accessibilityPerformPress() -> Bool {
        choose()
        return true
    }

    override func accessibilityChildren() -> [Any]? { [eject] }
}
