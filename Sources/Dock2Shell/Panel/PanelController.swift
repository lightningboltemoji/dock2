import AppKit
import Dock2Core

/// The panel: the field, in its own glass — Spotlight's, frostier than the platter's — and later whatever grows out
/// of it: a solid ground, the field's strip of it bare, and a pane of glass laid over what grew. It rises into place
/// over the dock, and sinks back on dismissal (`EntryMotion`).
@MainActor
final class PanelController {
    private let stage: Stage
    private let view = PanelView()
    /// Everything the panel shows but its feedback, which outlasts a dismissal: what its entrance and dismissal fade,
    /// as one, so nothing in it outlives the glass.
    private let stack = PanelView()
    private let shadow = PanelShadow()
    private let glass = GlassView(recipe: .panel(dark: false))
    /// Grown, what the glass lies on, and the pane over what grew (`PanelMetrics.layering`).
    private let ground = PanelGround()
    private let pane = GlassView(recipe: .pane(dark: false))
    let field = FieldView()
    let results = RowsView()
    /// A view's bar at the field's trailing end, and the menu it opens over everything else.
    let actions = ActionsBubble()
    /// A view's scope, at the trailing end of a bar of the ground along the panel's top, and the menu it opens down over
    /// the pane.
    let scope = ScopeMenu()
    /// Holds the scope, cut off at the pane's top as the glass moves and at its foot at rest (`headCut`): it comes out from
    /// behind the pane as its bar opens, and its menu opens down over the pane.
    private let head = PanelView()
    private let headCut: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = .black
        layer.anchorPoint = .zero
        return layer
    }()
    private(set) lazy var feedback = Feedback(in: view)
    /// What a screen shows — its view, its bar — within the glass's shape as it grows (`clip`).
    private let content = PanelView()
    /// A screen's view sits on it, over the pane, as search's rows do.
    private let slot = ScreenSlot()
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
        // Beneath the glass, which bends them.
        stack.addSubview(ground)
        stack.addSubview(faces)
        stack.addSubview(glass)
        stack.addSubview(pane)
        stack.addSubview(results)
        stack.addSubview(field)
        content.autoresizingMask = [.width, .height]
        content.layer!.mask = clip
        stack.addSubview(content)
        field.isHidden = true
        results.isHidden = true
        slot.isHidden = true
        content.addSubview(slot)
        head.autoresizingMask = [.width, .height]
        head.layer!.mask = headCut
        content.addSubview(head)
        scope.autoresizingMask = [.width, .height]
        scope.frames = { [weak self] in self?.scopeFrames }
        scope.onOpenChange = { [weak self] open in self?.menuOpened(open, other: self?.actions) }
        head.addSubview(scope)
        actions.autoresizingMask = [.width, .height]
        actions.frames = { [weak self] in self?.actionsFrames }
        actions.onOpenChange = { [weak self] open in self?.menuOpened(open, other: self?.scope) }
        stack.addSubview(actions)
        view.onAppearanceChange = { [weak self] dark in
            guard let self else { return }
            // The glass built again, and its motion played on it, in one go.
            Motion.together {
                self.glass.recipe = .panel(dark: dark, lens: self.driver?.form == .gem)
                self.pane.recipe = .pane(dark: dark)
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
        let driver = FormDriver(form: form, glass: glass, pane: pane, ground: ground, field: field, shadow: shadow, clip: clip, rows: rowsMask, results: results, reveal: reveal, above: feedback.anchor,
                                faces: faces, fieldFrame: frame, target: frame, resting: isResting)
        self.driver = driver
        driver.riders = riders
        driver.start(arriving: arriving)
    }

    /// The form follows the field filling and emptying, and splashes as letters land.
    private func edited(from old: String, to new: String, cleared: Bool) {
        guard let driver, isShown else { return }
        if driver.isResting != isResting {
            // Under Reduce Motion the capsule changes at once, faded rather than poured.
            if driver.form == .capsule, DisplayOptions.reduceMotion { Motion.crossfade(view.layer, over: .slide) }
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

    /// The field alone is a capsule; grown, the panel has continuous corners, like Spotlight's.
    private func shape(_ field: CGRect, extent: CGFloat) -> GlassLayer.Shape {
        guard extent > 0 else { return capsule(field) }
        let rect = CGRect(x: field.minX, y: field.minY, width: field.width, height: field.height + extent)
        return GlassLayer.Shape(frame: rect, cornerRadius: PanelMetrics.radius, curve: .continuous)
    }

    /// The screen on top of the panel's stack, in place of the results; nil to go back to them.
    private var screen: Screen?

    /// What rides the glass of the screen showing, or leaving; none under Reduce Motion, whose changes fade.
    private var riders: ScreenRiders? {
        didSet { driver?.riders = riders }
    }

    func showScreen(_ screen: Screen?) {
        actions.close(animated: false)
        scope.close(animated: false)
        endLeaving()
        let left = self.screen
        if screen != nil {
            left?.view.removeFromSuperview()
            left?.bar?.removeFromSuperview()
        }
        self.screen = screen
        unhover()
        if let driver, isShown, driver.isResting != isResting {
            if isResting {
                driver.rest(cleared: false)
            } else if hasArrived || DisplayOptions.reduceMotion {
                driver.pour()
            } else if let frame = fieldFrame {
                // Never on screen as its form: there is nothing to pour, and it arrives as the field.
                driver.stop()
                startForm(showing, over: frame, arriving: true)
            }
        }
        let wasWidth = width
        width = screen?.size?.width ?? PanelMetrics.fieldSize.width
        guard let frame = fieldFrame else { return }
        // Fading out under a bar, the field stays where it was rather than widening with the panel.
        if screen?.bar == nil { field.frame = frame }
        let hadScope = scopeHead > 0
        scopeHead = screen?.scope == nil ? 0 : PanelMetrics.scopeHead
        let motion = Motion.adjusted(isShown ? .slide : nil)
        // Opened from nothing, the bar has the field's place from the start.
        showField(screen?.bar == nil, over: hasArrived ? motion : nil)
        if isShown, motion == nil, DisplayOptions.reduceMotion, wasWidth != width { Motion.crossfade(view.layer, over: .slide) }
        if hadScope, screen?.scope == nil { leaveScope() }
        guard let screen else {
            if let left { leave(left) } else { slot.release() }
            slot.isHidden = !isLeaving
            results.isHidden = results.rows.isEmpty
            if isLeaving { results.layer?.fadeIn(over: GrowthMotion.screenFadeOut) }
            grow(to: Self.extent(of: results.rows), animated: motion != nil && wasWidth != width)
            return
        }
        let extent = (screen.size?.height ?? Self.rowsReach) + scopeHead
        let arriving = isShown && (slot.isHidden || extent != self.extent)
        results.isHidden = true
        content.frame = view.bounds
        slot.frame = PanelMetrics.pane(over: frame, extent: extent, head: scopeHead)
        slot.hold(screen.view)
        slot.isHidden = false
        if let bar = screen.bar {
            bar.frame = frame
            content.addSubview(bar)
        }
        // One leaving fades out as it is (`leaveScope`).
        if let offer = screen.scope { showScope(offer, over: frame, extent: extent) }
        riders = motion == nil ? nil : ScreenRiders(rest: shape(frame, extent: extent).frame, head: scopeHead, leading: screen.bar?.leadingEnd.layer,
                                                    trailing: screen.bar?.trailingEnd.layer, room: screen.bar?.room,
                                                    pane: slot.layer, contents: screen.view.layer, scope: screen.scope == nil ? nil : scope.layer,
                                                    scopeCut: screen.scope == nil ? nil : headCut)
        grow(to: extent, animated: motion != nil, force: wasWidth != width)
        if arriving {
            screen.bar?.layer?.fadeIn(over: GrowthMotion.barFadeIn)
            slot.layer?.fadeIn(over: GrowthMotion.contentFadeIn, after: motion == nil ? 0 : GrowthMotion.contentDelay)
            if !hadScope, screen.scope != nil { scope.layer?.fadeIn(over: GrowthMotion.barFadeIn) }
        }
    }

    // MARK: - The scope

    /// How far a scope's bar along the top holds the pane below the ground's rim: `PanelMetrics.scopeHead` while the
    /// screen showing has a scope, else none.
    private var scopeHead: CGFloat = 0

    /// The bar the scope stands on, kept as it fades out with the bar closing over it, and the room its menu opens into:
    /// down over the pane, off the field.
    private var scopeBar = CGRect.zero
    private var scopeFrames: (bar: CGRect, room: CGRect)? {
        guard let frame = fieldFrame else { return nil }
        return (scopeBar, CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: max(0, scopeBar.maxY - frame.maxY)))
    }

    /// The field the Actions pill stands on, and the panel grown above it for its menu.
    private var actionsFrames: (bar: CGRect, room: CGRect)? {
        guard let frame = fieldFrame else { return nil }
        return (frame, CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + extent))
    }

    /// The scope in its bar, over a panel grown `extent` above `frame`.
    private func showScope(_ offer: ScopeOffer?, over frame: CGRect, extent: CGFloat) {
        scope.layer?.stopFading()
        scopeBar = PanelMetrics.scopeBar(over: frame, extent: extent)
        Motion.perform(nil) {
            headCut.bounds = CGRect(origin: .zero, size: view.bounds.size)
            headCut.position = CGPoint(x: 0, y: frame.maxY)
        }
        scope.setOffer(offer)
        scope.needsLayout = true
    }

    /// The screen's scope changed in place: the panel grows by the bar as one comes and gives it back as one goes, the
    /// pane holding still.
    func setScope(_ offer: ScopeOffer?) {
        guard let screen, let frame = fieldFrame else { return scope.setOffer(nil) }
        let head = offer == nil ? 0 : PanelMetrics.scopeHead
        guard head != scopeHead else { return scope.setOffer(offer) }
        let extent = (screen.size?.height ?? Self.rowsReach) + head
        if offer == nil { leaveScope() }
        scopeHead = head
        slot.frame = PanelMetrics.pane(over: frame, extent: extent, head: head)
        if let offer {
            showScope(offer, over: frame, extent: extent)
            scope.layer?.fadeIn(over: GrowthMotion.barFadeIn)
        }
        let animated = !DisplayOptions.reduceMotion
        riders = animated ? ScreenRiders(rest: shape(frame, extent: extent).frame, head: head, leading: screen.bar?.leadingEnd.layer,
                                         trailing: screen.bar?.trailingEnd.layer, room: screen.bar?.room, pane: slot.layer,
                                         contents: screen.view.layer, scope: offer == nil ? nil : scope.layer,
                                         scopeCut: offer == nil ? nil : headCut) : nil
        grow(to: extent, animated: animated)
    }

    /// Counts scopes leaving, so the end of one superseded does nothing.
    private var scopeLeavings = 0

    /// The scope fades out as its bar closes over it, then goes.
    private func leaveScope() {
        scope.close(animated: false)
        scopeLeavings += 1
        let leaving = scopeLeavings
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.scopeLeavings == leaving, self.scopeHead == 0 else { return }
                self.scope.layer?.stopFading()
                self.scope.setOffer(nil)
            }
        }
        scope.layer?.fadeOut(over: GrowthMotion.screenFadeOut)
        CATransaction.commit()
    }

    /// What a screen that left still shows, until it has faded: its view stays in the slot, this its bar.
    private var leavingBar: NSView?
    private var isLeaving = false
    /// Counts leavings, so the end of one superseded does nothing.
    private var leavings = 0

    /// What `left` shows stays where it is, riding the glass as it draws back over it and fading out, then goes. It takes
    /// no more clicks: its screen is closed.
    private func leave(_ left: Screen) {
        isLeaving = true
        leavingBar = left.bar
        content.passesClicks = true
        leavings += 1
        let leaving = leavings
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.leavings == leaving else { return }
                self.endLeaving()
            }
        }
        slot.layer?.fadeOut(over: GrowthMotion.screenFadeOut)
        left.bar?.layer?.fadeOut(over: GrowthMotion.screenFadeOut)
        CATransaction.commit()
    }

    /// What a screen that left still showed goes.
    private func endLeaving() {
        guard isLeaving else { return }
        isLeaving = false
        leavings += 1
        content.passesClicks = false
        riders = nil
        slot.layer?.stopFading()
        slot.release()
        slot.isHidden = true
        leavingBar?.layer?.stopFading()
        leavingBar?.removeFromSuperview()
        leavingBar = nil
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
    /// or growing to it (`GrowthMotion`); nil for none. Its ground fades in or out, even under Reduce Motion, unless
    /// the panel was never on screen as the clear field.
    private func setGlass(_ shape: GlassLayer.Shape?, animated: Bool = false) {
        guard let shape else {
            glass.setShapes([])
            pane.setShapes([])
            ground.clear()
            return
        }
        driver?.setTarget(shape, head: grownHead, animated: animated, fading: hasArrived)
    }

    // MARK: - Control

    /// What `dock2 debug state` says of the panel, each frame passed through `global` from the stage's.
    func debugState(global: (CGRect) -> DebugState.Rect) -> DebugState.Panel {
        let frame = fieldFrame
        let grown = max(screen?.size?.height ?? 0, Self.rowsReach)
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
        guard isShown, let frame = fieldFrame, extent != self.extent || scopeHead != grownHead || force else { return }
        // What grows shows whole: typed ahead of the entrance, the entrance runs now and its fade ends.
        if isWaiting { enter() }
        stack.layer!.mask = nil
        self.extent = extent
        grownHead = scopeHead
        // Clear while it is the field alone; grown, the ground comes in under the glass on a spring of its own, the
        // clear glass giving way to it and to the pane (`FieldMotion.setTarget`).
        setGlass(shape(frame, extent: extent), animated: animated)
        actions.needsLayout = true
        scope.needsLayout = true
    }

    /// The scope's bar the glass was last grown for.
    private var grownHead: CGFloat = 0

    /// The most the panel grows for search's rows: as high as they ever reach, on the pane.
    private static let rowsReach: CGFloat = RowsView.maximumHeight + 2 * RowsView.padding + PanelMetrics.paneInset

    /// How far the panel grows for `rows`: as high as they reach, and the ground's rim above the pane; none for none.
    private static func extent(of rows: [RowModel]) -> CGFloat {
        let height = RowsView.height(of: rows)
        return height > 0 ? height + PanelMetrics.paneInset : 0
    }

    /// Grows the panel to hold `rows` above the field, or shrinks it back to the field alone.
    func setResults(_ rows: [RowModel], selection: String?) {
        guard isShown, let frame = fieldFrame else { return }
        let extent = Self.extent(of: rows)
        // On the pane, as high as rows ever reach, so a row leaving fades where it was as the glass draws back over it.
        results.frame = PanelMetrics.pane(over: frame, extent: Self.rowsReach)
        results.reach = RowsView.height(of: rows)
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
            endLeaving()
            view.frame = stage.view.bounds
            stack.frame = view.bounds
            // A dismissal's fade comes off.
            stack.layer!.mask = nil
            glass.frame = view.bounds
            pane.frame = view.bounds
            ground.frame = view.bounds
            shadow.frame = view.bounds
            faces.frame = view.bounds
            content.frame = view.bounds
            // What a dismissal left playing ends before anything new starts.
            driver?.stop()
            driver = nil
            showing = shownForm
            glass.recipe = .panel(dark: view.isDark, lens: showing == .gem)
            pane.recipe = .pane(dark: view.isDark)
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
            feedback.leave()
            unhover()
            let reduceMotion = DisplayOptions.reduceMotion
            results.isHidden = true
            if let screen { leave(screen) }
            screen = nil
            let grown = extent > 0
            extent = 0
            if scopeHead > 0 { leaveScope() }
            scopeHead = 0
            grownHead = 0
            let finish = { [weak self] in
                guard let self, !self.isShown else { return }
                self.endLeaving()
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
            // A grown panel first becomes the field again, then sinks: at once, unless a screen is riding it down.
            if grown { setGlass(capsule(frame), animated: isLeaving) }
            fade(field, to: 0, duration: Motion.sink.duration * 0.5, delay: 0)
            shadow.fade(in: false, duration: Motion.sink.duration)
            fadeOut(over: .sink)
            CATransaction.begin()
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
            driver?.leave(over: .sink, solid: isLeaving)
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


    /// What a view's bar offers; the field leaves it room.
    func setOffers(_ offers: ViewActions?) {
        actions.setOffers(offers)
        field.trailingReserve = actions.reserve
    }

    /// One of the bars' menus opened or closed: the other closes, since one menu is open at a time, and the screen
    /// recedes while either is.
    private func menuOpened(_ open: Bool, other: BarMenu?) {
        if open { other?.close(animated: true) }
        recede(actions.isOpen || scope.isOpen)
    }

    /// The screen fades back while a bar's menu is open over it, and comes forward as it closes.
    private func recede(_ receded: Bool) {
        guard let view = screen?.view else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = receded ? 0.2 : 0.15
            view.animator().alphaValue = receded ? 0.58 : 1
        }
    }

    func toast(_ text: String) {
        guard let frame = fieldFrame else { return }
        feedback.toast(text, over: frame.midX)
    }

    /// Asks before `run`: a destructive action, or one likely a mistake.
    func confirm(_ confirmation: Feedback.Confirmation, _ run: @escaping () -> Void) {
        guard let frame = fieldFrame else { return }
        feedback.confirm(confirmation, over: frame.midX, run)
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

/// The panel's view, spanning the stage; only the panel itself takes the mouse, so clicks reach the dock.
@MainActor
final class PanelView: NSView {
    var onAppearanceChange: ((Bool) -> Void)?
    /// What it holds shows, but takes no clicks.
    var passesClicks = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !passesClicks else { return nil }
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
