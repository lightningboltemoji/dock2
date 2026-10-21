import AppKit
import Dock2Core

/// The panel: the field, and later whatever grows out of it. It grows from the platter's top edge in its own
/// glass — Spotlight's, frostier than the platter's, so the two cannot merge in one SDF tree — and runs back
/// into it on dismissal.
@MainActor
final class PanelController {
    private let stage: Stage
    private let view = PanelView()
    private let shadow = PanelShadow()
    private let glass = GlassView(recipe: .panel(dark: false))
    let field = FieldView()
    let results = RowsView()
    private(set) lazy var feedback = Feedback(in: view)
    /// Between the field and what grew from it.
    private let divider = CALayer()
    private var extent: CGFloat = 0
    private(set) var isShown = false
    /// Counts fades, so a delayed one superseded by a later one does nothing.
    private var fades = 0
    /// Where the platter is, in the stage's coordinates: what the panel grows from.
    var platter: () -> CGRect? = { nil }

    init(stage: Stage) {
        self.stage = stage
        view.autoresizingMask = [.width, .height]
        stage.view.addSubview(view)
        view.addSubview(shadow)
        view.addSubview(glass)
        view.addSubview(results)
        view.addSubview(field)
        field.isHidden = true
        results.isHidden = true
        divider.backgroundColor = CGColor(gray: 0, alpha: 0.12)
        divider.isHidden = true
        view.layer!.addSublayer(divider)
        view.onAppearanceChange = { [weak self] dark in self?.glass.recipe = .panel(dark: dark) }
    }

    /// Search's width, or the screen's showing.
    private var width = PanelMetrics.fieldSize.width

    private var fieldFrame: CGRect? {
        platter().map { PanelMetrics.field(over: $0, width: width) }
    }

    private func capsule(_ rect: CGRect) -> GlassLayer.Shape {
        GlassLayer.Shape(frame: rect, cornerRadius: rect.height / 2, curve: .circular)
    }

    /// The field alone is a capsule; grown, the panel keeps its radius with continuous corners, like
    /// Spotlight's.
    private func shape(_ field: CGRect, extent: CGFloat) -> GlassLayer.Shape {
        guard extent > 0 else { return capsule(field) }
        let rect = CGRect(x: field.minX, y: field.minY, width: field.width, height: field.height + extent)
        return GlassLayer.Shape(frame: rect, cornerRadius: field.height / 2, curve: .continuous)
    }

    /// The screen on top of the panel's stack, in place of the results; nil to go back to them.
    private var screen: Screen?

    func showScreen(_ screen: Screen?) {
        self.screen?.view.removeFromSuperview()
        self.screen?.bar?.removeFromSuperview()
        self.screen = screen
        let wasWidth = width
        width = screen?.size?.width ?? PanelMetrics.fieldSize.width
        guard let frame = fieldFrame else { return }
        field.frame = frame
        field.isHidden = !isShown || screen?.bar != nil
        let motion = Motion.adjusted(isShown ? .slide : nil)
        if isShown, motion == nil, DisplayOptions.reduceMotion, wasWidth != width { Motion.crossfade(view.layer, over: .slide) }
        guard let screen else {
            results.isHidden = results.rows.isEmpty
            grow(to: RowsView.height(of: results.rows), motion: wasWidth != width ? motion : nil)
            return
        }
        let extent = screen.size?.height ?? RowsView.maximumHeight + 2 * RowsView.padding
        results.isHidden = true
        screen.view.frame = CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: extent)
        view.addSubview(screen.view, positioned: .below, relativeTo: field)
        if let bar = screen.bar {
            bar.frame = frame
            view.addSubview(bar)
        }
        grow(to: extent, motion: motion, force: wasWidth != width)
    }

    private func grow(to extent: CGFloat, motion: Motion? = nil, force: Bool = false) {
        guard isShown, let frame = fieldFrame, extent != self.extent || force else { return }
        self.extent = extent
        let shape = shape(frame, extent: extent)
        glass.setShapes([shape], motion: motion)
        shadow.set(shape.frame, cornerRadius: shape.cornerRadius, motion: motion)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        divider.isHidden = extent == 0
        divider.frame = CGRect(x: frame.minX + 20, y: frame.maxY - 0.5, width: frame.width - 40, height: 0.5)
        CATransaction.commit()
    }

    /// Grows the panel to hold `rows` above the field, or shrinks it back to the field alone.
    func setResults(_ rows: [RowModel], selection: String?) {
        guard isShown, let frame = fieldFrame else { return }
        let extent = RowsView.height(of: rows)
        results.frame = CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: extent)
        results.show(rows, selection: selection)
        guard screen == nil else { return }
        results.isHidden = rows.isEmpty
        // As Spotlight's, measured: the panel grows to its results and back over the slide, the rows showing
        // only within the glass as it goes, from the field up.
        let motion = Motion.adjusted(.slide)
        results.layer?.mask = reveal
        let shown = (reveal.presentation() ?? reveal).bounds.height
        Motion.perform(nil) { reveal.bounds = CGRect(x: 0, y: 0, width: frame.width, height: extent) }
        if shown < extent { motion?.animate(reveal, "bounds", from: NSValue(rect: CGRect(x: 0, y: 0, width: frame.width, height: shown))) }
        grow(to: extent, motion: motion)
    }

    /// The part of the rows the glass covers yet, from the field up.
    private let reveal: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        layer.anchorPoint = .zero
        layer.position = .zero
        return layer
    }()

    /// Grows the field out of the platter, or puts it straight there without `animated`.
    func show(animated: Bool) {
        guard !isShown, let frame = fieldFrame, let platter = platter() else { return }
        isShown = true
        view.frame = stage.view.bounds
        glass.frame = view.bounds
        shadow.frame = view.bounds
        shadow.set(frame)
        glass.recipe = .panel(dark: view.isDark)
        field.frame = frame
        field.alphaValue = 0
        field.isHidden = false
        let reduceMotion = DisplayOptions.reduceMotion
        glass.alphaValue = 1
        if animated && !reduceMotion {
            glass.setShapes([capsule(PanelMetrics.seed(over: platter))])
            glass.setShapes([capsule(frame)], motion: .slide)
            fade(field, to: 1, duration: Motion.slide.duration * 0.6, delay: Motion.slide.duration * 0.4)
            shadow.fade(in: true, duration: Motion.slide.duration * 0.5, delay: Motion.slide.duration * 0.5)
        } else {
            // In place, the glass fading in with the field.
            glass.setShapes([capsule(frame)])
            if animated { fadeGlass(from: 0, to: 1) }
            fade(field, to: 1, duration: animated ? Motion.slide.duration : 0, delay: 0)
            shadow.fade(in: true, duration: animated ? Motion.slide.duration : 0)
        }
    }

    /// Runs the field back into the platter.
    func hide(animated: Bool) {
        guard isShown else { return }
        isShown = false
        feedback.cancel()
        let reduceMotion = DisplayOptions.reduceMotion
        results.isHidden = true
        screen?.view.removeFromSuperview()
        screen?.bar?.removeFromSuperview()
        screen = nil
        divider.isHidden = true
        let grown = extent > 0
        extent = 0
        let finish = { [weak self] in
            guard let self, !self.isShown else { return }
            self.field.isHidden = true
            self.glass.setShapes([])
            self.width = PanelMetrics.fieldSize.width
        }
        guard animated, let platter = platter() else {
            shadow.fade(in: false, duration: 0)
            finish()
            return
        }
        fade(field, to: 0, duration: Motion.slide.duration * 0.4, delay: 0)
        shadow.fade(in: false, duration: Motion.slide.duration * 0.3)
        if reduceMotion {
            fadeGlass(from: 1, to: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.slide.duration) { finish() }
            return
        }
        // A grown panel first becomes the field again, at once, then runs into the platter.
        if grown, let frame = fieldFrame { glass.setShapes([capsule(frame)]) }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
        glass.setShapes([capsule(PanelMetrics.seed(over: platter))], motion: .slide)
        CATransaction.commit()
    }

    /// Where a toast sits: inside the panel's far edge, or over the field when it is alone.
    private var toastCenter: CGPoint? {
        guard let frame = fieldFrame else { return nil }
        let y = extent > 0 ? frame.maxY + extent - Feedback.inset : frame.maxY + Feedback.inset
        return CGPoint(x: frame.midX, y: y)
    }

    func toast(_ text: String) {
        guard let center = toastCenter else { return }
        feedback.toast(text, at: center)
    }

    /// Asks before `run`: a destructive action.
    func confirm(_ title: String, _ run: @escaping () -> Void) {
        guard let center = toastCenter else { return }
        feedback.confirm(title, at: center, run)
    }

    /// After a dismissal: where the field was.
    func notice(_ text: String) {
        guard let frame = fieldFrame else { return }
        feedback.notice(text, at: CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Puts the caret in the field: the stage must be key.
    func focus() {
        stage.window.makeFirstResponder(field.text)
        // Selecting nothing: the caret at the end of whatever is there.
        field.text.currentEditor()?.selectedRange = NSRange(location: field.string.utf16.count, length: 0)
    }

    /// Through the view's alpha: AppKit owns a layer-backed view's layer opacity and puts it back.
    /// Reduce Motion's appearance and dismissal: the glass fades where it is.
    private func fadeGlass(from: CGFloat, to alpha: CGFloat) {
        glass.alphaValue = from
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.slide.duration
            glass.animator().alphaValue = alpha
        }
    }

    private func fade(_ view: NSView, to alpha: CGFloat, duration: CFTimeInterval, delay: CFTimeInterval) {
        let generation = fades + 1
        fades = generation
        let run: @MainActor @Sendable () -> Void = { [weak self, weak view] in
            guard let self else { return }
            guard let view, self.fades == generation else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                view.animator().alphaValue = alpha
            }
        }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: run) } else { run() }
    }
}

/// The panel's view, spanning the stage; only the panel itself takes the mouse, so clicks reach the dock.
@MainActor
final class PanelView: NSView {
    var onAppearanceChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?(isDark)
    }
}
