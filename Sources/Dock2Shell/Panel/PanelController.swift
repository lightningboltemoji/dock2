import AppKit
import Dock2Core

/// The panel: the field, and later whatever grows out of it, in its own glass — Spotlight's, frostier than the
/// platter's. It rises into place over the dock, and sinks back on dismissal (`EntryMotion`).
@MainActor
final class PanelController {
    private let stage: Stage
    private let view = PanelView()
    /// Everything the panel shows but its feedback, which outlasts a dismissal: what its entrance and dismissal fade,
    /// as one, so nothing in it outlives the glass.
    private let stack = PanelView()
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
    /// What the field is while nothing is typed (`Settings.fieldForm`), from the next showing.
    var form: FieldForm = .capsule
    /// Plays the panel's glass, shadow, clip and reveal — and its form, if it has one — while it shows.
    private var driver: FormDriver?
    private let faces = GemFaces()

    init(stage: Stage) {
        self.stage = stage
        view.autoresizingMask = [.width, .height]
        stage.view.addSubview(view)
        stack.autoresizingMask = [.width, .height]
        view.addSubview(stack)
        stack.addSubview(shadow)
        // Beneath the glass, which bends it.
        stack.addSubview(faces)
        stack.addSubview(glass)
        stack.addSubview(results)
        stack.addSubview(field)
        content.autoresizingMask = [.width, .height]
        content.layer!.mask = clip
        stack.addSubview(content)
        field.isHidden = true
        results.isHidden = true
        divider.isHidden = true
        content.addSubview(divider)
        view.onAppearanceChange = { [weak self] dark in
            guard let self else { return }
            // The glass built again, and its motion played on it, in one go.
            Motion.together {
                self.glass.recipe = .panel(dark: dark, lens: self.driver?.form == .gem)
                self.driver?.replay()
            }
        }
        field.onEdit = { [weak self] old, new, cleared in self?.edited(from: old, to: new, cleared: cleared) }
    }

    // MARK: - The form

    /// The form shown: none where the system's display settings ask for plain glass or no motion, nor
    /// without the glass the forms are made of.
    private var shownForm: FieldForm {
        let plain = DisplayOptions.reduceMotion || DisplayOptions.reduceTransparency || DisplayOptions.increaseContrast
        return plain || !GlassLayer.isAvailable ? .capsule : form
    }

    /// Nothing typed and nothing open over the search: what a form rests in.
    private var isResting: Bool { field.string.isEmpty && screen == nil }

    /// Starts `form` over the field at `frame`.
    private func startForm(_ form: FieldForm, over frame: CGRect, arriving: Bool) {
        let driver = FormDriver(form: form, glass: glass, field: field, shadow: shadow, clip: clip, rows: rowsMask, reveal: reveal,
                                faces: faces, fieldFrame: frame, target: frame, resting: isResting)
        self.driver = driver
        driver.start(arriving: arriving)
    }

    /// The form follows the field filling and emptying, and splashes as letters land.
    private func edited(from old: String, to new: String, cleared: Bool) {
        guard let driver, isShown else { return }
        if driver.isResting != isResting {
            if isResting { driver.rest(cleared: cleared) } else { driver.pour() }
        } else if !isResting, new.count > old.count {
            driver.typed()
        }
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
        // What the last screen had still to fade in goes with it.
        driver?.reveal(nil)
        if let driver, isShown, driver.isResting != isResting {
            if isResting { driver.rest(cleared: false) } else { driver.pour() }
        }
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
            grow(to: RowsView.height(of: results.rows), animated: motion != nil && wasWidth != width)
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
        grow(to: extent, animated: motion != nil, force: wasWidth != width)
        if motion != nil { driver?.reveal(content.layer) }
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

    /// The glass in `shape` — the shadow, the clip on what a screen shows and the rows' reveal with it — at once
    /// or growing to it (`GrowthMotion`); nil for none.
    private func setGlass(_ shape: GlassLayer.Shape?, animated: Bool = false) {
        guard let shape else { return glass.setShapes([]) }
        driver?.setTarget(shape, animated: animated)
    }

    // MARK: - Control

    /// What `dock2 debug state` says of the panel, each frame passed through `global` from the stage's.
    func debugState(global: (CGRect) -> DebugState.Rect) -> DebugState.Panel {
        let frame = fieldFrame
        let grown = max(screen?.size?.height ?? 0, RowsView.maximumHeight + 2 * RowsView.padding)
        let rows = results.isHidden ? [] : results.rows.filter(\.isSelectable)
        return DebugState.Panel(
            shown: isShown, form: (isShown ? showing : shownForm).rawValue, resting: driver?.isResting ?? false,
            field: frame.map(global),
            body: frame.map { global(CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height + extent)) },
            reach: frame.map { global(CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height + grown)) },
            screen: screen.map { $0.title ?? String(describing: type(of: $0)) },
            text: field.string,
            rows: rows.map { row in
                // A row scrolled out of the panel has no place to aim at.
                let frame = results.frame(of: row.id).flatMap { results.bounds.contains($0) ? results.convert($0, to: view) : nil }
                return DebugState.Row(title: row.title, subtitle: row.subtitle, selected: row.id == results.selection,
                                      frame: frame.map(global))
            })
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

    private func grow(to extent: CGFloat, animated: Bool = false, force: Bool = false) {
        guard isShown, let frame = fieldFrame, extent != self.extent || force else { return }
        // What grows shows whole: typed ahead of the entrance, the entrance runs now and its fade ends.
        if isWaiting { enter() }
        stack.layer!.mask = nil
        self.extent = extent
        setGlass(shape(frame, extent: extent), animated: animated)
        // Clear while it is the field alone, frosted for what grows from it to be read: a fade, so over the
        // slide under Reduce Motion too. A panel that arrives grown was never the clear field, so it comes frosted.
        glass.setFrosted(extent > 0, motion: hasArrived ? .slide : nil)
        divider.isHidden = extent == 0
        divider.frame = CGRect(x: frame.minX + 20, y: frame.maxY - 0.5, width: frame.width - 40, height: 0.5)
    }

    /// Grows the panel to hold `rows` above the field, or shrinks it back to the field alone.
    func setResults(_ rows: [RowModel], selection: String?) {
        guard isShown, let frame = fieldFrame else { return }
        let extent = RowsView.height(of: rows)
        // As high as rows ever reach, so a row leaving fades where it was as the glass draws back over it.
        results.frame = CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: RowsView.maximumHeight + 2 * RowsView.padding)
        results.reach = extent
        results.show(rows, selection: selection)
        guard screen == nil else { return }
        results.isHidden = false
        // The panel grows to its results and back, the rows showing only within the glass as it goes, from the
        // field up (`FormDriver`).
        results.layer?.mask = rowsMask
        grow(to: extent, animated: !DisplayOptions.reduceMotion)
    }

    /// The rows' mask: `reveal`, within the body's width as a form pours it out (`FormDriver`).
    private lazy var rowsMask: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = true
        layer.anchorPoint = .zero
        layer.addSublayer(reveal)
        return layer
    }()

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
        Motion.together {
            guard !isShown, let frame = fieldFrame else { return }
            isShown = true
            hasArrived = false
            entrances += 1
            let entrance = entrances
            view.frame = stage.view.bounds
            stack.frame = view.bounds
            // A dismissal's fade comes off.
            stack.layer!.mask = nil
            glass.frame = view.bounds
            shadow.frame = view.bounds
            faces.frame = view.bounds
            content.frame = view.bounds
            // What a dismissal left playing ends before anything new starts.
            driver?.stop()
            driver = nil
            showing = shownForm
            glass.recipe = .panel(dark: view.isDark, lens: showing == .gem)
            glass.setFrosted(false)
            field.frame = frame
            field.isHidden = false
            // A dismissal's fade may still be running on it; through `fade`, one still to come does nothing.
            field.layer?.removeAllAnimations()
            fade(field, to: 1, duration: 0, delay: 0)
            guard animated, !DisplayOptions.reduceMotion else {
                // In place; under Reduce Motion, everything fading in together over the slide.
                startForm(showing, over: frame, arriving: false)
                shadow.fade(in: true, duration: 0)
                if animated { fadeIn(frame, over: Motion.slide.duration, waveFrom: nil) }
                arrive()
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
    }

    /// Counts showings, so what one started does nothing once a later one has come.
    private var entrances = 0
    /// The form this showing has, taken as it began.
    private var showing: FieldForm = .capsule
    /// Shown, with the entrance still to run: it runs at its time, or once anything grows the panel.
    private var isWaiting = false
    /// The turn the entrance began in has ended, so the panel has been on screen as it was then.
    private var hasArrived = false

    /// The glass, its motion and the mask it fades in through reach the screen together.
    private func enter() {
        Motion.together {
            isWaiting = false
            guard let frame = fieldFrame else { return }
            let start = EntryMotion.riseStart(of: frame)
            startForm(showing, over: frame, arriving: true)
            shadow.fade(in: true, duration: 0)
            // A screen with a bar that came while the entrance waited has the field's place.
            if screen?.bar == nil { fade(field, to: 1, duration: 0, delay: 0) }
            rise(field, from: start, to: frame, over: .rise)
            fadeIn(frame, over: EntryMotion.fadeIn, waveFrom: CGPoint(x: frame.midX, y: frame.minY))
            arrive()
        }
    }

    /// What the rest of this turn does — a screen opened with the panel — is part of its arrival.
    private func arrive() {
        let entrance = entrances
        DispatchQueue.main.async { [weak self] in
            guard let self, self.entrances == entrance else { return }
            self.hasArrived = true
        }
    }

    /// Plays the rise back, everything in the panel fading as one.
    func hide(animated: Bool) {
        Motion.together {
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
                self.driver?.stop()
                self.driver = nil
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
                fadeOut(over: .slide)
                DispatchQueue.main.asyncAfter(deadline: .now() + Motion.slide.duration) { finish() }
                return
            }
            // A grown panel first becomes the field again, at once, then sinks.
            if grown { setGlass(capsule(frame)) }
            fade(field, to: 0, duration: Motion.sink.duration * 0.5, delay: 0)
            shadow.fade(in: false, duration: Motion.sink.duration)
            fadeOut(over: .sink)
            CATransaction.begin()
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
            driver?.leave(over: .sink)
            CATransaction.commit()
        }
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
        stack.layer!.mask = fadeMask
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
                self.stack.layer!.mask = nil
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

    /// Asks before `run`: a destructive action, or one likely a mistake.
    func confirm(_ confirmation: Feedback.Confirmation, _ run: @escaping () -> Void) {
        guard let center = toastCenter else { return }
        feedback.confirm(confirmation, at: center, run)
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

    /// The panel's mask while it fades out: everything in it at once, the gem under the glass as long as the glass.
    private let fadeOutMask: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = .black
        return layer
    }()

    /// Fades everything but the feedback out over `motion`, through a mask: AppKit owns a layer-backed view's
    /// opacity and puts it back.
    private func fadeOut(over motion: Motion) {
        Motion.perform(nil) {
            fadeOutMask.frame = stack.bounds
            fadeOutMask.opacity = 0
            stack.layer!.mask = fadeOutMask
        }
        motion.animate(fadeOutMask, "opacity", from: 1)
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
