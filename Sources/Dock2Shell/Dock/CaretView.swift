import AppKit
import Dock2Core

/// In a tile's label's place while the panel shows what the tile opened (Files, over Finder's): a small capsule
/// of the label's glass carrying a chevron, in the label's ink, pointing up at it.
@MainActor
final class CaretView: NSView {
    /// Room around the capsule for its rim.
    private static let margin: CGFloat = 4
    private static let size = CGSize(width: 30, height: 18)
    /// From the chevron's middle to either end, from its feet to its point, and how thick it is drawn.
    private static let halfWidth: CGFloat = 5
    private static let rise: CGFloat = 3
    private static let stroke: CGFloat = 2

    private let glass = GlassView(recipe: .label(dark: false))
    private let chevron = CAShapeLayer()
    private(set) var isShowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(glass)
        // Above the glass's own view, never inside it: a layer below a backdrop is refracted by it.
        let host = NSView()
        host.wantsLayer = true
        chevron.fillColor = nil
        chevron.lineWidth = Self.stroke
        chevron.lineCap = .round
        chevron.lineJoin = .round
        host.layer!.addSublayer(chevron)
        addSubview(host)
        isHidden = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Over a tile centred at `centerX`, where its label would be on a platter whose top is `platterTop`,
    /// fading in when `animated`.
    func show(centerX: CGFloat, platterTop: CGFloat, dark: Bool, animated: Bool) {
        let centerY = platterTop + LabelMetrics.liftAbovePlatter + LabelMetrics.height / 2
        let body = CGRect(x: (centerX - Self.size.width / 2).rounded(), y: (centerY - Self.size.height / 2).rounded(),
                          width: Self.size.width, height: Self.size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = body.insetBy(dx: -Self.margin, dy: -Self.margin)
        for view in subviews { view.frame = bounds }
        let capsule = body.offsetBy(dx: -frame.minX, dy: -frame.minY)
        glass.recipe = .label(dark: dark)
        glass.setShapes([GlassLayer.Shape(frame: capsule, cornerRadius: capsule.height / 2, curve: .circular)])
        let path = CGMutablePath()
        path.move(to: CGPoint(x: capsule.midX - Self.halfWidth, y: capsule.midY - Self.rise / 2))
        path.addLine(to: CGPoint(x: capsule.midX, y: capsule.midY + Self.rise / 2))
        path.addLine(to: CGPoint(x: capsule.midX + Self.halfWidth, y: capsule.midY - Self.rise / 2))
        chevron.path = path
        chevron.strokeColor = CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.95 : 0.85)
        chevron.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        guard !isShowing else { return }
        isShowing = true
        isHidden = false
        fade(to: 1, over: animated ? 0.15 : 0)
    }

    func hide(animated: Bool) {
        guard isShowing else { return }
        isShowing = false
        fade(to: 0, over: animated ? 0.12 : 0) { [weak self] in
            guard let self, !self.isShowing else { return }
            self.isHidden = true
        }
    }

    /// Through the view's alpha: AppKit owns a layer-backed view's layer opacity and puts it back.
    private func fade(to alpha: CGFloat, over duration: CFTimeInterval, then done: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            animator().alphaValue = alpha
        }, completionHandler: { MainActor.assumeIsolated { done?() } })
    }
}
