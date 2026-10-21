import AppKit
import Dock2Core

/// The panel's feedback ([views](product/plugins/views.md#components)), each a capsule of glass of its own: a
/// toast at the panel's far edge; a confirmation there, its question beside the buttons that answer it; and
/// after a dismissal, a brief notice where the field was ("Copied").
@MainActor
final class Feedback {
    /// What a confirmation asks, and the button that goes ahead: red when what it does cannot be undone.
    struct Confirmation {
        var question: String
        var action: String
        var destructive = true
    }

    private let toast = Toast()
    private var hides = 0
    private var pending: (() -> Void)?

    static let toastDuration = 2.0
    static let noticeDuration = 1.2
    /// From the panel's edge to a toast's centre: as far in as Files' content.
    static let inset = Toast.height / 2 + 10

    init(in view: NSView) {
        view.addSubview(toast)
    }

    var isConfirming: Bool { pending != nil }

    func toast(_ text: String, at center: CGPoint) {
        cancel()
        show(text, at: center, for: Self.toastDuration)
    }

    func notice(_ text: String, at center: CGPoint) {
        cancel()
        // Long enough to read: a sentence stays longer than "Copied", though not past six seconds.
        show(text, at: center, for: min(6, max(Self.noticeDuration, Double(text.count) / 18)))
    }

    /// Up until it is answered: by ↩ or Esc, or by its buttons.
    func confirm(_ confirmation: Confirmation, at center: CGPoint, _ run: @escaping () -> Void) {
        pending = run
        let buttons = [
            ToastButton(title: "Cancel", key: "esc", role: .cancel) { [weak self] in _ = self?.answer(.cancel) },
            ToastButton(title: confirmation.action, key: "↩", role: confirmation.destructive ? .destroy : .confirm) { [weak self] in
                _ = self?.answer(.confirm)
            },
        ]
        show(confirmation.question, buttons: buttons, at: center, for: nil)
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

    private func show(_ text: String, buttons: [ToastButton] = [], at center: CGPoint, for duration: Double?) {
        toast.show(text, buttons: buttons, centeredAt: center)
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
        toast.hide()
    }
}

/// A capsule of the dock's label glass over the panel's shadow: a line of text, and the buttons that answer it
/// when it asks. It drops into place as it fades in, and lifts away as it fades out. Clicks pass through it
/// unless it has buttons.
@MainActor
private final class Toast: NSView {
    static let height: CGFloat = 36
    /// Around the capsule, for its shadow.
    private static let margin: CGFloat = 32
    /// How far it drops into place, and lifts as it goes.
    private static let travel: CGFloat = 6
    private static let maxWidth = PanelMetrics.fieldSize.width - 40
    /// The text's inset from the capsule's ends, and the buttons' from its edge: concentric with it.
    private static let textInset: CGFloat = 16
    private static let buttonInset: CGFloat = 5

    private let panelShadow = PanelShadow()
    private let glass = GlassView(recipe: .label(dark: false))
    private let label = NSTextField(labelWithString: "")
    private var buttons: [ToastButton] = []
    private var isShown = false
    /// Counts its showings, so a fade out from one cut short does nothing.
    private var showings = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        alphaValue = 0
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setAccessibilityElement(false)
        // Above the glass's own view, never inside it: a layer below a backdrop is refracted by it.
        for view in [panelShadow, glass, label] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var capsule: CGRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShown, !buttons.isEmpty else { return nil }
        let local = convert(point, from: superview)
        guard capsule.contains(local) else { return nil }
        return buttons.first { $0.frame.contains(local) } ?? self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Between the buttons, a click lands on nothing beneath.
    override func mouseDown(with event: NSEvent) {}

    func show(_ text: String, buttons: [ToastButton], centeredAt center: CGPoint) {
        label.stringValue = text
        self.buttons.forEach { $0.removeFromSuperview() }
        self.buttons = buttons
        buttons.forEach(addSubview)

        let textWidth = ceil(label.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude, height: Self.height)).width)
        let buttonWidths = buttons.map { ceil($0.intrinsicContentSize.width) }
        let buttonsWidth = buttonWidths.reduce(0, +) + CGFloat(max(buttons.count - 1, 0)) * 6
        let trailing = buttons.isEmpty ? Self.textInset : 12 + buttonsWidth + Self.buttonInset
        let width = min(Self.textInset + textWidth + trailing, Self.maxWidth)
        let end = CGRect(x: (center.x - width / 2).rounded() - Self.margin, y: (center.y - Self.height / 2).rounded() - Self.margin,
                         width: width + 2 * Self.margin, height: Self.height + 2 * Self.margin)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = end
        let capsule = self.capsule
        panelShadow.frame = bounds
        glass.frame = bounds
        glass.recipe = .label(dark: effectiveAppearance.isDark)
        glass.setShapes([GlassLayer.Shape(frame: capsule, cornerRadius: Self.height / 2, curve: .circular)])
        panelShadow.set(capsule)
        panelShadow.fade(in: true, duration: 0)
        var x = capsule.maxX - Self.buttonInset
        for (button, buttonWidth) in zip(buttons, buttonWidths).reversed() {
            x -= buttonWidth
            button.frame = CGRect(x: x, y: capsule.minY + Self.buttonInset, width: buttonWidth, height: Self.height - 2 * Self.buttonInset)
            x -= 6
        }
        let textEnd = buttons.isEmpty ? capsule.maxX - Self.textInset : x - 6
        let textHeight = label.intrinsicContentSize.height
        label.frame = CGRect(x: capsule.minX + Self.textInset, y: (capsule.midY - textHeight / 2).rounded(),
                             width: max(0, textEnd - capsule.minX - Self.textInset), height: textHeight)
        CATransaction.commit()

        setAccessibilityLabel(text)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        superview?.addSubview(self, positioned: .above, relativeTo: nil)
        // Whole before it is seen: a button places its title in a layout pass of its own.
        layoutSubtreeIfNeeded()
        showings += 1
        // Already up, it changes in place.
        guard !isShown else { return }
        isShown = true
        isHidden = false
        alphaValue = 1
        move(opacity: 0.2, travel: (from: Self.travel, to: 0), over: 0.35, CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        let showing = showings
        alphaValue = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown, self.showings == showing else { return }
                self.isHidden = true
                self.layer?.removeAnimation(forKey: "travel")
            }
        }
        move(opacity: 0.3, travel: (from: 0, to: Self.travel), over: 0.3, CAMediaTimingFunction(name: .easeIn), holds: true)
        CATransaction.commit()
    }

    /// Fades the layer to the opacity just set, from where it is, and moves it `travel` up and back, added to
    /// wherever it is: never its frame, which reaches the layer only at its next update, so an animated frame
    /// would set off from where the layer last was. A move that `holds` stays where it ends.
    private func move(opacity duration: CFTimeInterval, travel: (from: CGFloat, to: CGFloat), over moving: CFTimeInterval,
                      _ timing: CAMediaTimingFunction, holds: Bool = false) {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? (alphaValue > 0 ? 0 : 1)
        fade.toValue = Float(alphaValue)
        fade.duration = duration
        layer.add(fade, forKey: "fade")
        layer.removeAnimation(forKey: "travel")
        guard !DisplayOptions.reduceMotion else { return }
        let move = CABasicAnimation(keyPath: "position.y")
        move.isAdditive = true
        move.fromValue = travel.from
        move.toValue = travel.to
        move.duration = moving
        move.timingFunction = timing
        if holds {
            move.fillMode = .forwards
            move.isRemovedOnCompletion = false
        }
        layer.add(move, forKey: "travel")
    }
}

/// A toast's button: the panel's pill, filled — the accent colour for the one ↩ presses, red when that
/// cannot be undone — its key after its title, dimmed.
@MainActor
private final class ToastButton: PillButton {
    enum Role { case cancel, confirm, destroy }
    private let role: Role

    init(title: String, key: String, role: Role, _ action: @escaping () -> Void) {
        self.role = role
        super.init()
        padding = 12
        onClick = action
        set(title: title, image: nil)
        let color: NSColor = role == .cancel ? .labelColor : .white
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color])
        text.append(NSAttributedString(string: "  \(key)", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                                        .foregroundColor: color.withAlphaComponent(0.55)]))
        label.attributedStringValue = text
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var fill: NSColor? {
        let effect: NSColor.SystemEffect = isPressed ? .pressed : isHovered ? .rollover : .none
        switch role {
        case .cancel: return Self.ink(isPressed ? 0.14 : isHovered ? 0.1 : 0.06)
        case .confirm: return NSColor.controlAccentColor.withSystemEffect(effect)
        case .destroy: return NSColor.systemRed.withSystemEffect(effect)
        }
    }
}
