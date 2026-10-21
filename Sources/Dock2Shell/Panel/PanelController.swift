import AppKit
import Dock2Core

/// The panel: the field, and later whatever grows out of it, in its own glass — Spotlight's, frostier than the
/// platter's. It rises into place over the dock, and sinks back on dismissal (`EntryMotion`).
@MainActor
final class PanelController {
    private let stage: Stage
    private let view = PanelView()
    private let shadow = PanelShadow()
    private let glass = GlassView(recipe: .panel(dark: false))
    let field = FieldView()
    let results = RowsView()
    private(set) lazy var feedback = Feedback(in: view)
    /// Between the field and what grew from it: a view, clipped with what grew, since a bare layer on the
    /// panel's view is ordered beneath the glass.
    private let divider = Divider()
    /// What a screen shows — its view, its bar — within the glass's shape as it grows (`clip`).
    private let content = PanelView()
    private let clip: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = .black
        return layer
    }()
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
        content.autoresizingMask = [.width, .height]
        content.layer!.mask = clip
        view.addSubview(content)
        field.isHidden = true
        results.isHidden = true
        divider.isHidden = true
        content.addSubview(divider)
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
        unhover()
        let wasWidth = width
        width = screen?.size?.width ?? PanelMetrics.fieldSize.width
        guard let frame = fieldFrame else { return }
        // Fading out under a bar, the field stays where it was rather than widening with the panel.
        if screen?.bar == nil { field.frame = frame }
        let motion = Motion.adjusted(isShown ? .slide : nil)
        showField(screen?.bar == nil, over: motion)
        if isShown, motion == nil, DisplayOptions.reduceMotion, wasWidth != width { Motion.crossfade(view.layer, over: .slide) }
        guard let screen else {
            results.isHidden = results.rows.isEmpty
            grow(to: RowsView.height(of: results.rows), motion: wasWidth != width ? motion : nil)
            return
        }
        let extent = screen.size?.height ?? RowsView.maximumHeight + 2 * RowsView.padding
        results.isHidden = true
        content.frame = view.bounds
        screen.view.frame = CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: extent)
        content.addSubview(screen.view)
        if let bar = screen.bar {
            bar.frame = frame
            content.addSubview(bar)
        }
        grow(to: extent, motion: motion, force: wasWidth != width)
        if let motion { fadeInContent(over: motion) }
    }

    /// The field gives its place to a screen's bar, fading as the bar comes, and takes it back; once gone it
    /// is hidden, so it takes no click meant for the bar.
    private func showField(_ visible: Bool, over motion: Motion?) {
        guard isShown else {
            field.isHidden = true
            return
        }
        guard visible == field.isHidden || field.alphaValue < 1 else { return }
        if visible {
            field.isHidden = false
            fade(field, to: 1, duration: motion.map { $0.duration * 0.6 } ?? 0, delay: 0)
        } else {
            fade(field, to: 0, duration: motion.map { $0.duration * 0.4 } ?? 0, delay: 0) { [weak self] in self?.field.isHidden = true }
        }
    }

    /// A screen arriving: it shows as the glass reaches it, not ahead of it.
    private func fadeInContent(over motion: Motion) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = CACurrentMediaTime() + motion.duration * 0.25
        fade.duration = motion.duration * 0.75
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        content.layer?.add(fade, forKey: "fade")
    }

    /// The glass in `shape`, or none, and the clip on what a screen shows in the same shape, over `motion`.
    private func setGlass(_ shape: GlassLayer.Shape?, motion: Motion? = nil) {
        glass.setShapes(shape.map { [$0] } ?? [], motion: motion)
        guard let shape else { return }
        // Explicit, from wherever it is now, as the glass's elements move.
        let from = clip.presentation() ?? clip
        let start = (bounds: from.bounds, position: from.position, radius: from.cornerRadius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.bounds = CGRect(origin: .zero, size: shape.frame.size)
        clip.position = CGPoint(x: shape.frame.midX, y: shape.frame.midY)
        clip.cornerRadius = min(shape.cornerRadius, shape.frame.height / 2)
        clip.cornerCurve = shape.curve
        CATransaction.commit()
        guard let motion, !start.bounds.isEmpty else { return }
        motion.animate(clip, "bounds", from: NSValue(rect: start.bounds))
        motion.animate(clip, "position", from: NSValue(point: start.position))
        motion.animate(clip, "cornerRadius", from: NSNumber(value: Double(start.radius)))
    }

    // MARK: - Hover

    private weak var hovered: (any Hoverable)?

    /// The pointer moved to `point` on the screen, over the window numbered `window` (`PointerMonitor`): the
    /// control under it is lit, and no other.
    func pointerMoved(to point: CGPoint, over window: Int) {
        var lit: (any Hoverable)?
        if isShown, window == stage.window.windowNumber {
            var hit = view.hitTest(stage.view.convert(stage.window.convertPoint(fromScreen: point), from: nil))
            while let found = hit, !(found is any Hoverable) { hit = found.superview }
            lit = hit as? any Hoverable
        }
        guard lit !== hovered else { return }
        hovered?.isHovered = false
        hovered = lit
        lit?.isHovered = true
    }

    private func unhover() {
        hovered?.isHovered = false
        hovered = nil
    }

    private func grow(to extent: CGFloat, motion: Motion? = nil, force: Bool = false) {
        guard isShown, let frame = fieldFrame, extent != self.extent || force else { return }
        // What grows shows whole: typed ahead of the entrance, the entrance runs now and its fade ends.
        if isWaiting { enter() }
        view.layer!.mask = nil
        self.extent = extent
        let shape = shape(frame, extent: extent)
        setGlass(shape, motion: motion)
        shadow.set(shape.frame, cornerRadius: shape.cornerRadius, motion: motion)
        divider.isHidden = extent == 0
        divider.frame = CGRect(x: frame.minX + 20, y: frame.maxY - 0.5, width: frame.width - 40, height: 0.5)
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

    /// Brings the field in, or puts it straight there without `animated`: it rises from below, growing a
    /// little, and fades in from its middle outward — `delay` later, to follow a dock still to arrive.
    func show(animated: Bool, after delay: CFTimeInterval = 0) {
        guard !isShown, let frame = fieldFrame else { return }
        isShown = true
        entrances += 1
        let entrance = entrances
        view.frame = stage.view.bounds
        glass.frame = view.bounds
        shadow.frame = view.bounds
        content.frame = view.bounds
        glass.recipe = .panel(dark: view.isDark)
        field.frame = frame
        field.isHidden = false
        // A dismissal's fades may still be running on them; through `fade`, one still to come does nothing.
        field.layer?.removeAllAnimations()
        glass.layer?.removeAllAnimations()
        fade(field, to: 1, duration: 0, delay: 0)
        glass.alphaValue = 1
        guard animated, !DisplayOptions.reduceMotion else {
            // In place; under Reduce Motion, everything fading in together over the slide.
            setGlass(capsule(frame))
            shadow.set(frame)
            shadow.fade(in: true, duration: 0)
            if animated { fadeIn(frame, over: Motion.slide.duration, waveFrom: nil) }
            return
        }
        guard delay > 0 else { return enter() }
        isWaiting = true
        field.alphaValue = 0
        setGlass(nil)
        shadow.fade(in: false, duration: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isWaiting, self.entrances == entrance else { return }
            self.enter()
        }
    }

    /// Counts showings, so what one started does nothing once a later one has come.
    private var entrances = 0
    /// Shown, with the entrance still to run: it runs at its time, or once anything grows the panel.
    private var isWaiting = false

    private func enter() {
        isWaiting = false
        guard let frame = fieldFrame else { return }
        let start = EntryMotion.riseStart(of: frame)
        setGlass(capsule(start))
        setGlass(capsule(frame), motion: .rise)
        shadow.set(start)
        shadow.set(frame, motion: .rise)
        shadow.fade(in: true, duration: 0)
        fade(field, to: 1, duration: 0, delay: 0)
        rise(field, from: start, to: frame, over: .rise)
        fadeIn(frame, over: EntryMotion.fadeIn, waveFrom: CGPoint(x: frame.midX, y: frame.minY))
    }

    /// Plays the rise back.
    func hide(animated: Bool) {
        guard isShown else { return }
        isShown = false
        isWaiting = false
        feedback.cancel()
        unhover()
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
            self.setGlass(nil)
            self.width = PanelMetrics.fieldSize.width
        }
        guard animated, let frame = fieldFrame else {
            shadow.fade(in: false, duration: 0)
            finish()
            return
        }
        if reduceMotion {
            fade(field, to: 0, duration: Motion.slide.duration * 0.4, delay: 0)
            shadow.fade(in: false, duration: Motion.slide.duration * 0.3)
            fadeGlassOut(over: .slide)
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.slide.duration) { finish() }
            return
        }
        // A grown panel first becomes the field again, at once, then sinks.
        if grown {
            setGlass(capsule(frame))
            shadow.set(frame)
        }
        let start = EntryMotion.riseStart(of: frame)
        fade(field, to: 0, duration: Motion.sink.duration * 0.5, delay: 0)
        shadow.fade(in: false, duration: Motion.sink.duration)
        fadeGlassOut(over: .sink)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
        setGlass(capsule(start), motion: .sink)
        shadow.set(start, motion: .sink)
        CATransaction.commit()
    }

    /// Moves the field's contents as its glass moves, from `start` to `frame`. AppKit owns the layer, so the
    /// move is an animation alone, ending at the transform AppKit gave it.
    private func rise(_ view: NSView, from start: CGRect, to frame: CGRect, over motion: Motion) {
        guard let layer = view.layer else { return }
        // About the layer's anchor, a point p of `frame` goes to start's centre + scale × (p − frame's centre).
        let scale = start.width / frame.width
        let anchor = CGPoint(x: frame.minX + layer.anchorPoint.x * frame.width, y: frame.minY + layer.anchorPoint.y * frame.height)
        let shift = CGPoint(x: start.midX - frame.midX + (1 - scale) * (frame.midX - anchor.x),
                            y: start.midY - frame.midY + (1 - scale) * (frame.midY - anchor.y))
        let transform = CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                                            CATransform3DMakeTranslation(shift.x, shift.y, 0))
        motion.animate(layer, "transform", from: NSValue(caTransform3D: CATransform3DConcat(transform, layer.transform)))
    }

    /// The panel's mask while it fades in: whole as far as a wave has spread, dimmer past it.
    private let fadeMask: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.type = .radial
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 1)
        let floor = CGColor(gray: 0, alpha: EntryMotion.fadeFloor)
        layer.colors = [CGColor.black, CGColor.black, floor, floor]
        return layer
    }()

    /// Fades the whole panel in over `duration` through its mask — and from `origin`, in a wave spreading
    /// across the field at `frame`. The mask holds the glass, the shadow and the contents alike, where an
    /// alpha set and animated in one transaction would animate from the value it replaced.
    private func fadeIn(_ frame: CGRect, over duration: CFTimeInterval, waveFrom origin: CGPoint?) {
        // The shadow reaches this far past the glass.
        let covered = frame.insetBy(dx: -40, dy: -40)
        let center = origin ?? CGPoint(x: covered.midX, y: covered.midY)
        let reach = [CGPoint(x: covered.minX, y: covered.minY), CGPoint(x: covered.maxX, y: covered.maxY),
                     CGPoint(x: covered.minX, y: covered.maxY), CGPoint(x: covered.maxX, y: covered.minY)]
            .map { hypot($0.x - center.x, $0.y - center.y) }.max()!
        let edge = EntryMotion.fadeEdge, radius = reach + edge
        let stops: (CGFloat, CGFloat) -> [NSNumber] = { inner, outer in [0, inner / radius, outer / radius, 1].map { NSNumber(value: Double($0)) } }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
        fadeMask.locations = stops(reach, radius)
        view.layer!.mask = fadeMask
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.duration = duration
        // The mask comes off once the fade ends, unless a later entrance has it.
        let entrance = entrances
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.entrances == entrance else { return }
                self.view.layer!.mask = nil
            }
        }
        fadeMask.add(fade, forKey: "fade")
        if origin != nil {
            // The front moves at one speed from the origin to past the far corner, its soft edge behind it.
            let spread = CAKeyframeAnimation(keyPath: "locations")
            spread.values = [stops(0, 0), stops(0, edge), stops(reach, radius)]
            spread.keyTimes = [0, NSNumber(value: Double(edge / radius)), 1]
            spread.duration = radius / EntryMotion.fadeSpeed
            fadeMask.add(spread, forKey: "spread")
        }
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
    private func fadeGlassOut(over motion: Motion) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.duration
            context.timingFunction = motion.timing
            glass.animator().alphaValue = 0
        }
    }

    /// `done` runs once the fade ends, unless a later fade has begun.
    private func fade(_ view: NSView, to alpha: CGFloat, duration: CFTimeInterval, delay: CFTimeInterval,
                      then done: (@MainActor () -> Void)? = nil) {
        let generation = fades + 1
        fades = generation
        let run: @MainActor @Sendable () -> Void = { [weak self, weak view] in
            guard let self else { return }
            guard let view, self.fades == generation else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                view.animator().alphaValue = alpha
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.fades == generation else { return }
                    done?()
                }
            })
        }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: run) } else { run() }
    }
}

/// A hairline, darker on light glass and lighter on dark.
@MainActor
private final class Divider: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (effectiveAppearance.isDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.12)).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
