import AppKit

/// The panel's feedback ([views](product/plugins/views.md#components)): a toast at its far edge; a
/// destructive action's confirmation there, which holds ↩ and Esc until it is answered; and after a
/// dismissal, a brief notice where the field was ("Copied"). Each is a pill centred on the point given.
@MainActor
final class Feedback {
    private let pill = Pill()
    private var hides = 0
    private var pending: (() -> Void)?

    static let toastDuration = 2.0
    static let noticeDuration = 1.2
    /// From the panel's edge to a toast's centre.
    static let inset = Pill.height / 2 + 10

    init(in view: NSView) {
        pill.isHidden = true
        view.addSubview(pill)
    }

    var isConfirming: Bool { pending != nil }

    func toast(_ text: String, at center: CGPoint) {
        cancel()
        show(text, style: .plain, at: center, for: Self.toastDuration)
    }

    func notice(_ text: String, at center: CGPoint) {
        cancel()
        // Long enough to read: a sentence stays longer than "Copied", though not past six seconds.
        show(text, style: .plain, at: center, for: min(6, max(Self.noticeDuration, Double(text.count) / 18)))
    }

    func confirm(_ title: String, at center: CGPoint, _ run: @escaping () -> Void) {
        pending = run
        show("\(title)?  ↩ to confirm, esc to cancel", style: .destructive, at: center, for: nil)
    }

    enum Key { case confirm, cancel, other }

    /// While confirming: ↩ runs it, anything else gives it up, and only ↩ and Esc are taken.
    func answer(_ key: Key) -> Bool {
        guard let run = pending else { return false }
        cancel()
        switch key {
        case .confirm:
            run()
            return true
        case .cancel:
            return true
        case .other:
            return false
        }
    }

    func cancel() {
        guard pending != nil else { return }
        pending = nil
        hide()
    }

    private func show(_ text: String, style: Pill.Style, at center: CGPoint, for duration: Double?) {
        pill.set(text, style: style)
        let size = pill.fittingSize
        pill.frame = CGRect(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded(),
                            width: size.width, height: size.height)
        pill.superview?.addSubview(pill, positioned: .above, relativeTo: nil)
        pill.alphaValue = 1
        pill.isHidden = false
        hides += 1
        let generation = hides
        guard let duration else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.hides == generation else { return }
            self.hide()
        }
    }

    private func hide() {
        hides += 1
        let generation = hides
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            pill.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hides == generation else { return }
                self.pill.isHidden = true
            }
        }
    }
}

/// A capsule of text that reads over glass and wallpaper alike.
@MainActor
private final class Pill: NSView {
    enum Style { case plain, destructive }
    static let height: CGFloat = 30
    private let label = NSTextField(labelWithString: "")

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer!.cornerRadius = Self.height / 2
        layer!.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(_ text: String, style: Style) {
        label.stringValue = text
        layer!.backgroundColor = style == .destructive ? NSColor.systemRed.cgColor : CGColor(gray: 0.1, alpha: 0.82)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        needsLayout = true
    }

    override var fittingSize: NSSize {
        NSSize(width: (label.intrinsicContentSize.width + 32).rounded(.up), height: Self.height)
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: 16, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }
}
