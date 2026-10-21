import AppKit

/// What Files' bar is made of: an icon and a title over a rounded fill — lit by hover, a press, a drag held
/// over it, and more while it is the current one — and no bezel. Given a folder, it takes drops into it, and
/// a drag held over it springs it open.
@MainActor
class PillButton: NSView, Hoverable {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    /// After the title, smaller: a pop-up's chevrons.
    let accessory = NSImageView()
    var padding: CGFloat = 10
    var spacing: CGFloat = 6
    var iconSize: CGFloat = 16
    var onClick: (() -> Void)?
    /// Drawn alike, but never lit and never clicked: a name, not a control.
    var isInert = false
    var onDrop: (([URL], URL, _ moving: Bool) -> Void)?
    /// A drag held over it for the system's spring-loading delay.
    var onSpring: (() -> Void)?

    /// At most half its height: a capsule unless given less.
    var cornerRadius: CGFloat = .greatestFiniteMagnitude { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { if isCurrent != oldValue { needsDisplay = true } } }
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true; hoverChanged() } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    private var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }

    /// Where what is dropped on it goes; nil takes no drops.
    var folder: URL? {
        didSet {
            guard (folder == nil) != (oldValue == nil) else { return }
            if folder == nil { unregisterDraggedTypes() } else { registerForDraggedTypes([.fileURL]) }
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingTail
        accessory.isHidden = true
        for view in [icon, label, accessory] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(title: String, image: NSImage?) {
        if label.stringValue != title {
            label.stringValue = title
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        icon.image = image
        icon.isHidden = image == nil
        label.isHidden = title.isEmpty
        setAccessibilityLabel(title.isEmpty ? toolTip : title)
    }

    override var intrinsicContentSize: NSSize {
        // Measured unbounded: a label's own intrinsic width can follow the frame it was last given.
        let text = label.isHidden ? 0 : ceil(label.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width)
        let image = icon.isHidden ? 0 : iconSize + (text > 0 ? spacing : 0)
        let trailing = accessory.isHidden ? 0 : 4 + (accessory.image?.size.width ?? 0)
        return NSSize(width: padding + image + text + trailing + padding, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        var x = padding
        if !icon.isHidden {
            icon.frame = CGRect(x: x, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            x += iconSize + spacing
        }
        let size = accessory.isHidden ? .zero : accessory.image?.size ?? .zero
        let trailing = accessory.isHidden ? 0 : 4 + size.width
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: max(0, bounds.width - x - padding - trailing), height: height)
        accessory.frame = CGRect(x: bounds.width - padding - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    // MARK: - Drawing

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = min(bounds.height / 2, cornerRadius)
        layer?.backgroundColor = fill?.cgColor
    }

    private var fill: NSColor? {
        if isInert { return nil }
        if isDropTarget { return .controlAccentColor.withAlphaComponent(0.3) }
        if isPressed { return Self.ink(0.12) }
        if isCurrent { return Self.ink(0.09) }
        if isHovered { return Self.ink(0.05) }
        return nil
    }

    /// Black on light glass, white on dark: a tint that darkens or lightens whatever the glass shows.
    nonisolated static func ink(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: alpha * 1.4) : NSColor(white: 0, alpha: alpha) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// For a subclass: the pointer came or went.
    func hoverChanged() {}

    // MARK: - Clicks

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && !isInert && frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isPressed, bounds.contains(point) else { return }
        isPressed = false
        clicked(at: point)
    }

    /// A click let go inside it, at `point`.
    func clicked(at point: CGPoint) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    // MARK: - Drops

    private var spring: DispatchWorkItem?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let operation = operation(sender) else { return [] }
        isDropTarget = true
        startSpring()
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) ?? [] }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
        spring?.cancel()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        spring?.cancel()
        let urls = DropRule.fileURLs(sender)
        guard let folder, DropRule.accepts(urls, into: folder) else { return false }
        onDrop?(urls, folder, DropRule.moves(urls, to: folder, allowed: sender.draggingSourceOperationMask))
        return true
    }

    private func operation(_ sender: NSDraggingInfo) -> NSDragOperation? {
        let urls = DropRule.fileURLs(sender)
        guard let folder, DropRule.accepts(urls, into: folder) else { return nil }
        return DropRule.moves(urls, to: folder, allowed: sender.draggingSourceOperationMask) ? .move : .copy
    }

    /// The system's delay and its switch apply, as to a column's folders.
    private func startSpring() {
        spring?.cancel()
        let global = UserDefaults(suiteName: UserDefaults.globalDomain)
        guard onSpring != nil, global?.object(forKey: "com.apple.springing.enabled") as? Bool ?? true else { return }
        let open = DispatchWorkItem { [weak self] in
            guard let self, self.isDropTarget else { return }
            self.onSpring?()
        }
        spring = open
        DispatchQueue.main.asyncAfter(deadline: .now() + (global?.object(forKey: "com.apple.springing.delay") as? Double ?? 0.5), execute: open)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
