import AppKit
import Dock2Core
import Dock2System

/// The dock on the stage. It composes the tiles from the settings and the running apps (`DockModel`),
/// lays them out, and turns what the pointer does on them — clicks, menus, drags — into actions.
@MainActor
final class DockController: DockDragHandler {
    private let stage: Stage
    private let settings: SettingsStore
    private let running: RunningApps
    private let apps: AppDirectory
    private let view: DockView
    private let label = LabelView()
    private let badges = BadgesView()
    private let autoHide: AutoHideDriver

    private var slots: [DockSlot] = []
    private var layout: DockLayout?
    /// Apps bouncing because they are starting.
    private var launching: Set<AppRef> = []
    private var drag: Drag?
    /// Files held over Finder's tile: Files opens, for the drag to carry on into a folder.
    private var spring: DispatchWorkItem?
    static let springDelay = 0.6
    private var menu: MenuBuilder?
    private var observations: [SettingsObservation] = []
    /// The ring: keyboard focus on a tile.
    private(set) var ring: TileKind?
    /// The app a search has selected that has no tile of its own.
    private var temporary: AppRef?
    private var pointerOnDock = false

    /// What is being dragged over the dock, and where it would land.
    private struct Drag {
        enum Payload { case tile(TileKind), apps([AppRef]), files([URL]) }
        var payload: Payload
        /// Where among the pinned apps it would be pinned: 0 is just after Finder.
        var gap: Int?
        /// The tile the files would open with.
        var target: TileKind?
    }

    var onQuit: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// The pointer arrived on the dock — the band while auto-hide shows it, else the platter — or left it.
    var onPointerOnDock: ((Bool) -> Void)?
    /// A click on the platter between tiles: a request for the keyboard.
    var onPlatterClick: (() -> Void)?
    /// An app was opened from the dock: whatever dock2 was doing is done.
    var onOpened: (() -> Void)?
    /// dock2 opened `app` — from a tile, ⌘1–9, the ring or search: a use, for search's ranking.
    var onOpenedApp: ((AppRef) -> Void)?
    /// Files asked for: Finder's tile clicked, `nil`; a place from its menu; an app's Show in Files.
    var onFiles: ((_ folder: URL?, _ revealing: [URL]) -> Void)?

    /// Above the platter: room for the label (the tallest thing over it) and its rim.
    private static let headroom = LabelMetrics.liftAbovePlatter + LabelMetrics.height + 8

    init(stage: Stage, settings: SettingsStore, running: RunningApps, apps: AppDirectory) {
        self.stage = stage
        self.settings = settings
        self.running = running
        self.apps = apps
        view = DockView(overlay: stage.glass.overlay)
        autoHide = AutoHideDriver(enabled: settings[Settings.autohide], revealDelay: settings[Settings.revealDelay],
                                  hideDelay: settings[Settings.hideDelay])
        stage.view.addSubview(view)
        stage.view.addSubview(label)
        stage.view.addSubview(badges)
        view.dragHandler = self
        view.onPlatterClick = { [weak self] in self?.onPlatterClick?() }
        view.onHover = { [weak self] slot in self?.hover(slot) }
        view.onClick = { [weak self] slot, modifiers in self?.click(slot, modifiers: modifiers) }
        view.menuFor = { [weak self] slot in self?.menu(for: slot) }
        view.nameFor = { [weak self] kind in self?.name(of: kind) }
        autoHide.onChange = { [weak self] shown in
            guard let self else { return }
            self.slide(shown: shown, motion: self.autoHideSlide)
            self.pointerMoved(to: NSEvent.mouseLocation)
        }
    }

    /// Auto-hide's slide at the system Dock's speed (`autohide-time-modifier`, as the first launch copied
    /// it): 0 is no slide at all.
    private var autoHideSlide: Motion? {
        let modifier = settings[Settings.slideTimeModifier]
        return modifier > 0 ? Motion(DockMotion.slideDuration * modifier, DockMotion.slideCurve) : nil
    }

    private var displayOptions: NSObjectProtocol?

    func start() {
        running.onChange = { [weak self] in self?.runningChanged() }
        running.onWillLaunch = { [weak self] app in self?.setLaunching(app, true) }
        for key in [Settings.tileSize, Settings.revealDelay, Settings.hideDelay] as [SettingKey<Double>] {
            observations.append(settings.observe(key) { [weak self] _ in self?.settingsChanged() })
        }
        for key in [Settings.autohide, Settings.showRunning, Settings.bounce] as [SettingKey<Bool>] {
            observations.append(settings.observe(key) { [weak self] _ in self?.settingsChanged() })
        }
        observations.append(settings.observe(Settings.pinned) { [weak self] _ in self?.relayout(motion: .reshape) })
        // Reduce Motion switched: a hidden dock moves to its place and fades out, or back.
        displayOptions = DisplayOptions.observe { [weak self] in
            guard let self else { return }
            self.relayout(motion: nil)
            self.slide(shown: self.autoHide.isShown, motion: nil)
        }
        relayout(motion: nil)
        if !autoHide.isShown { slide(shown: false, motion: nil) }
        note("dock2 \(Dock2Identity.version): \(slots.count) slots at tile size \(settings[Settings.tileSize])")
    }

    // MARK: - Layout

    private var metrics: DockMetrics { DockMetrics(tileSize: settings[Settings.tileSize]) }

    /// Plugins' tiles, by "plugin/tile", in the order they first appeared.
    private var pluginTiles: [(key: String, node: TileNode)] = []
    /// A plugin tile clicked, by its key.
    var onPluginTile: ((String) -> Void)?
    /// A plugin tile taken off the dock from its menu.
    var onRemovePluginTile: ((String) -> Void)?

    /// A plugin's tile drawn, changed, or — with nil — taken off.
    func setPluginTile(_ key: String, _ node: TileNode?) {
        let index = pluginTiles.firstIndex { $0.key == key }
        switch (index, node) {
        case (let index?, let node?):
            // A tile's state changing redraws its image alone: a relayout would take the label away.
            guard pluginTiles[index].node != node else { return }
            pluginTiles[index].node = node
            view.setImage(PluginTileImage.image(node), for: .plugin(key))
            if let hovered = view.hoveredSlot, kind(at: hovered) == .plugin(key) { hover(hovered) }
        case (nil, let node?):
            pluginTiles.append((key, node))
            relayout(motion: .reshape)
        case (let index?, nil):
            pluginTiles.remove(at: index)
            relayout(motion: .reshape)
        case (nil, nil):
            break
        }
    }

    /// Recomposes the tiles and moves everything to its place, over `motion` when given — or, under Reduce
    /// Motion, puts it there at once and fades the dock to it.
    func relayout(motion requested: Motion?) {
        let motion = Motion.adjusted(requested)
        // Only what can be drawn: the numbers, the ring and a drag's gap all count the tiles on show.
        slots = DockModel.compose(pinned: shownPinned, running: running.apps.map(\.ref).filter { apps.entry($0) != nil },
                                  showRunning: settings[Settings.showRunning], temporary: temporary,
                                  pluginTiles: pluginTiles.map(\.key))
        var shown: [DockSlot?] = slots
        if let drag {
            // What is carried, if pinned, leaves its place for the gap.
            let carried: Set<TileKind> = switch drag.payload {
            case .tile(let kind): [kind]
            case .apps(let apps): Set(apps.filter(shownPinned.contains).map(TileKind.app))
            case .files: []
            }
            shown.removeAll { $0?.tile.map(carried.contains) == true }
            if let gap = drag.gap { shown.insert(nil, at: min(1 + gap, shown.count)) }
        }
        let items: [DockView.Item] = shown.compactMap { slot in
            guard let slot else { return .gap }
            switch slot {
            case .separator(let group): return .separator(group)
            case .tile(let kind): return tile(kind).map { .tile($0) }
            }
        }
        let layout = DockLayout(metrics: metrics, kinds: items.map(\.kind), screen: stage.bounds)
        let shownPlatter = autoHide.isShown || DisplayOptions.reduceMotion
        self.layout = layout
        view.frame = CGRect(x: 0, y: 0, width: stage.bounds.width, height: layout.platter.maxY + Self.headroom)
        if let requested, motion == nil { view.crossfade(over: requested) }
        view.show(items, layout: layout, scale: stage.scale, motion: motion)
        stage.setGlass(.platter, platterShape(layout, shown: shownPlatter), motion: motion)
        autoHide.screen = stage.screen
        autoHide.bandTop = layout.platter.maxY
        for app in launching { view.setBouncing(true, .app(app), height: metrics.hopHeight) }
        if let ring, !slots.contains(.tile(ring)) { self.ring = nil }
        view.setRing(ring)
        label.hide()
        if !badges.isHidden { showBadges(true) }
    }

    /// The platter, where it is when shown, in the stage's coordinates.
    var platter: CGRect? { layout?.platter }

    /// On screen, or coming on: auto-hide has it shown.
    var isShown: Bool { autoHide.isShown }

    /// The tile for a kind, or nil for an app that is not installed.
    private func tile(_ kind: TileKind) -> DockView.Tile? {
        switch kind {
        case .finder, .app, .temporary:
            guard let app = kind.app, let entry = apps.entry(app) else { return nil }
            return DockView.Tile(kind: kind, image: entry.icon, running: running.isRunning(app),
                                 dimmed: { if case .temporary = kind { return true } else { return false } }())
        case .plugin(let key):
            guard let node = pluginTiles.first(where: { $0.key == key })?.node else { return nil }
            return DockView.Tile(kind: kind, image: PluginTileImage.image(node), running: false)
        }
    }

    private func platterShape(_ layout: DockLayout, shown: Bool) -> GlassLayer.Shape {
        let offset = shown ? 0 : layout.metrics.slideDistance
        return GlassLayer.Shape(frame: layout.platter.offsetBy(dx: 0, dy: -offset), cornerRadius: layout.metrics.cornerRadius)
    }

    /// Counts slides, so the end of one superseded by a later one does nothing.
    private var slides = 0
    /// Slid all the way away and cleared: the next slide in is the dock's entrance.
    private var isAway = false

    private func slide(shown: Bool, motion: Motion?) {
        guard let layout else { return }
        label.hide()
        badges.isHidden = true
        slides += 1
        let slide = slides
        // Under Reduce Motion the dock fades where it is rather than sliding away.
        let fades = DisplayOptions.reduceMotion
        if shown || fades { stage.fadeGlass(visible: shown, over: fades ? motion : nil) }
        CATransaction.begin()
        if !shown, !fades {
            // Slid away, the glass clears as well: it takes clicks a point or two beyond its shape, which
            // would leave a strip at the screen's edge that is dock2's.
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.slides == slide else { return }
                    self.stage.fadeGlass(visible: false, over: nil)
                    self.isAway = true
                }
            }
        }
        view.slide(by: shown || fades ? 0 : layout.metrics.slideDistance, motion: fades ? nil : motion)
        stage.setGlass(.platter, platterShape(layout, shown: shown || fades), motion: fades ? nil : motion)
        CATransaction.commit()
        guard shown else { return }
        if isAway, !fades, let motion { view.popIn(from: waveOrigin(layout), after: motion.duration * EntryMotion.popLead) }
        isAway = false
    }

    /// Where the tiles' entrance starts: under the pointer when it brought the dock up, else the middle.
    private func waveOrigin(_ layout: DockLayout) -> CGFloat {
        let pointer = NSEvent.mouseLocation
        return autoHide.zone(of: pointer) == .away ? layout.platter.midX : stage.local(pointer).x
    }

    private func settingsChanged() {
        autoHide.setDelays(reveal: settings[Settings.revealDelay], hide: settings[Settings.hideDelay])
        autoHide.setEnabled(settings[Settings.autohide])
        relayout(motion: .reshape)
    }

    private func runningChanged() {
        for app in launching where running.apps.contains(where: { $0.ref == app && $0.isFinishedLaunching }) {
            setLaunching(app, false)
        }
        relayout(motion: .reshape)
    }

    // MARK: - The pointer

    /// The pointer moved to `point`, over the window numbered `window` (`PointerMonitor`).
    func pointerMoved(to point: CGPoint, over window: Int) {
        // Hover follows the monitor, not a tracking area: dock2 is never the active app, so AppKit hands a
        // tracking area only some of the moves.
        view.hover(at: window == stage.window.windowNumber ? stage.local(point) : nil)
        pointerMoved(to: point)
    }

    private func pointerMoved(to point: CGPoint) {
        autoHide.pointerMoved(to: point)
        let on = autoHide.state.isEnabled
            ? autoHide.isShown && autoHide.zone(of: point) != .away
            : layout?.platter.contains(stage.local(point)) ?? false
        guard on != pointerOnDock else { return }
        pointerOnDock = on
        onPointerOnDock?(on)
    }

    /// Keeps the dock up — or lets it go — whatever the pointer does.
    func hold(_ hold: AutoHide.Hold, _ on: Bool) {
        autoHide.hold(hold, on)
    }

    // MARK: - The ring

    /// The tiles in order, separators skipped.
    private var tileKinds: [TileKind] { slots.compactMap(\.tile) }

    /// Moves the ring along the tiles, starting from the front app's tile, else Finder's.
    func moveRing(by step: Int) {
        let kinds = tileKinds
        guard !kinds.isEmpty else { return }
        if let ring, let index = kinds.firstIndex(of: ring) {
            setRing(kinds[min(max(index + step, 0), kinds.count - 1)])
        } else {
            let front = NSWorkspace.shared.frontmostApplication.flatMap(RunningApps.ref).map(TileKind.app)
            setRing(front.flatMap { kinds.contains($0) ? $0 : nil } ?? .finder)
        }
    }

    func ringToEnd(last: Bool) {
        setRing(last ? tileKinds.last : tileKinds.first)
    }

    func setRing(_ kind: TileKind?) {
        ring = kind
        view.setRing(kind)
        guard let kind, let layout, let slot = view.items.firstIndex(where: { $0.tileKind == kind }),
              let name = name(of: kind) else {
            label.hide()
            return
        }
        label.show(name, centerX: layout.slots[slot].frame.midX, platterTop: layout.platter.maxY, dark: view.isDark, scale: stage.scale)
    }

    /// The echo: the selected result's app wears the ring and its label — on its own tile, or on a temporary
    /// one at the end of the running apps, gone when the selection moves on.
    func setEcho(_ app: AppRef?) {
        var kind: TileKind?
        var standIn: AppRef?
        if let app {
            if app == .finder {
                kind = .finder
            } else if slots.contains(.tile(.app(app))) {
                kind = .app(app)
            } else {
                standIn = app
                kind = .temporary(app)
            }
        }
        if standIn != temporary {
            temporary = standIn
            relayout(motion: .reshape)
        }
        setRing(kind)
    }

    /// Uses the ringed tile, as a click would. False with no ring.
    @discardableResult
    func openRinged() -> Bool {
        guard let ring else { return false }
        use(ring)
        return true
    }

    /// The ringed tile's menu, at the tile.
    func popUpRingedMenu() {
        guard let ring, let layout, let slot = view.items.firstIndex(where: { $0.tileKind == ring }),
              let menu = menu(for: slot) else { return }
        // Above the tile, as the dock's menus open: the point is the menu's top left.
        let frame = layout.slots[slot].frame
        menu.popUp(positioning: nil, at: CGPoint(x: frame.minX, y: layout.platter.maxY + 4 + menu.size.height), in: view)
    }

    // MARK: - Numbers

    /// Uses tile `number` (1–9, from the left), as a click would.
    @discardableResult
    func openTile(number: Int) -> Bool {
        let kinds = tileKinds
        guard number >= 1, number <= min(9, kinds.count) else { return false }
        use(kinds[number - 1])
        return true
    }

    func showBadges(_ shown: Bool) {
        guard shown, settings[Settings.numberBadges], autoHide.isShown, let layout else {
            badges.isHidden = true
            return
        }
        badges.frame = stage.view.bounds
        let icons = DockModel.numbered(view.items.map { item -> DockSlot in
            if case .tile(let tile) = item { return .tile(tile.kind) }
            return .separator(.running)
        }).map { layout.slots[$0].content }
        badges.show(over: icons, tileSize: metrics.tileSize, dark: view.isDark, scale: stage.scale)
    }

    // MARK: - Tiles

    /// What `dock2 debug state` says of the tiles, each frame passed through `global` from the stage's.
    func debugTiles(global: (CGRect) -> DebugState.Rect) -> [DebugState.Tile] {
        guard let layout else { return [] }
        return zip(layout.slots, view.items).compactMap { slot, item in
            guard case .tile(let tile) = item else { return nil }
            let kind = switch tile.kind {
            case .finder: "finder"
            case .app: "app"
            case .temporary: "temporary"
            case .plugin: "plugin"
            }
            return DebugState.Tile(name: name(of: tile.kind) ?? "", kind: kind, running: tile.running,
                                   ringed: tile.kind == ring, frame: global(slot.frame))
        }
    }

    private func kind(at slot: Int) -> TileKind? {
        guard let layout, layout.slots.indices.contains(slot), case .tile(let tile) = view.items[slot] else { return nil }
        return tile.kind
    }

    private func name(of kind: TileKind) -> String? {
        switch kind {
        case .finder: "Files"
        case .app(let app), .temporary(let app): apps.entry(app)?.name
        case .plugin(let key): pluginTiles.first { $0.key == key }?.node.label
        }
    }

    private func hover(_ slot: Int?) {
        // A dock sliding away still draws, and so is still under the pointer.
        guard drag == nil, autoHide.isShown, let slot, let layout, let kind = kind(at: slot), let name = name(of: kind) else {
            label.hide()
            return
        }
        label.show(name, centerX: layout.slots[slot].frame.midX, platterTop: layout.platter.maxY,
                   dark: view.isDark, scale: stage.scale)
    }

    private func click(_ slot: Int, modifiers: NSEvent.ModifierFlags) {
        if let kind = kind(at: slot) { use(kind, modifiers: modifiers) }
    }

    /// A tile clicked, or chosen by its ring or its number: an app opens, a plugin's tile tells its plugin,
    /// and Finder's is Files — ⌥ makes it Finder.
    private func use(_ kind: TileKind, modifiers: NSEvent.ModifierFlags = []) {
        switch kind {
        case .plugin(let key): onPluginTile?(key)
        case .finder where !modifiers.contains(.option) && onFiles != nil: onFiles?(nil, [])
        default: if let app = kind.app { open(app) }
        }
    }

    /// Launches the app, or brings it forward and reopens a window, as the Dock does.
    func open(_ app: AppRef) {
        guard let url = apps.entry(app)?.url else { return }
        onOpened?()
        onOpenedApp?(app)
        if !running.isRunning(app) { setLaunching(app, true) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            warn("could not open \(url.lastPathComponent): \(error.localizedDescription)")
            Task { @MainActor in self?.setLaunching(app, false) }
        }
    }

    /// Files' operations, shown on Finder's tile ([dock](product/dock.md#tiles)).
    func setFilesProgress(_ progress: Double?) {
        view.setProgress(progress, .finder)
    }

    private func setLaunching(_ app: AppRef, _ isLaunching: Bool) {
        if isLaunching {
            guard settings[Settings.bounce], launching.insert(app).inserted else { return }
            view.setBouncing(true, .app(app), height: metrics.hopHeight)
            // An app that never reports in still stops hopping eventually, as in the Dock.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.setLaunching(app, false) }
        } else if launching.remove(app) != nil {
            view.setBouncing(false, .app(app), height: metrics.hopHeight)
        }
    }

    // MARK: - Menus

    private func menu(for slot: Int?) -> NSMenu? {
        let builder = MenuBuilder()
        builder.onOpen = { [weak self] open in self?.autoHide.hold(.menu, open) }
        if let slot {
            guard let kind = kind(at: slot) else { return nil }
            switch kind {
            case .finder: finderMenu(builder)
            case .app(let app), .temporary(let app): appMenu(builder, app)
            case .plugin(let key):
                builder.item("Remove from Dock") { [weak self] in self?.onRemovePluginTile?(key) }
            }
        } else {
            builder.item("Settings…", enabled: onOpenSettings != nil) { [weak self] in self?.onOpenSettings?() }
            builder.item("Auto-hide", state: settings[Settings.autohide] ? .on : .off) { [weak self] in
                guard let self else { return }
                self.settings[Settings.autohide].toggle()
            }
            builder.separator()
            builder.item("Quit dock2") { [weak self] in self?.onQuit?() }
        }
        menu = builder
        return builder.menu
    }

    private func appMenu(_ builder: MenuBuilder, _ app: AppRef) {
        let process = running.running(app)
        // Running, Open brings it forward and reopens a window, as a click does.
        builder.item("Open") { [weak self] in self?.open(app) }
        builder.item("Show in Files") { [weak self] in
            guard let url = self?.apps.entry(app)?.url else { return }
            self?.onFiles?(nil, [url])
        }
        builder.separator()
        if settings[Settings.pinned].contains(app) {
            builder.item("Remove from Dock") { [weak self] in self?.unpin(app) }
        } else {
            builder.item("Keep in Dock") { [weak self] in self?.pin([app], at: nil) }
        }
        if let process {
            builder.separator()
            builder.item("Hide") { process.hide() }
            builder.item("Quit") { process.terminate() }
            builder.alternate("Force Quit") { process.forceTerminate() }
        }
    }

    private func finderMenu(_ builder: MenuBuilder) {
        for place in Places.all {
            builder.item(place.name) { [weak self] in self?.onFiles?(place.url, []) }
        }
        builder.separator()
        builder.item("Open in Finder") { [weak self] in self?.open(.finder) }
    }

    // MARK: - Pinning

    /// The pinned apps the dock draws: those installed.
    private var shownPinned: [AppRef] {
        DockModel.shown(settings[Settings.pinned]) { apps.entry($0) != nil }
    }

    private func pin(_ new: [AppRef], at gap: Int?) {
        settings[Settings.pinned] = DockModel.pinning(new, atGap: gap, in: settings[Settings.pinned]) { apps.entry($0) != nil }
    }

    private func unpin(_ app: AppRef) {
        settings[Settings.pinned].removeAll { $0 == app }
    }

    // MARK: - Dragging

    func canDrag(slot: Int) -> Bool {
        guard let kind = kind(at: slot), case .app = kind else { return false }
        return true
    }

    func dragBegan(slot: Int) {
        guard let kind = kind(at: slot) else { return }
        autoHide.hold(.drag, true)
        drag = Drag(payload: .tile(kind), gap: pinnedIndex(of: kind))
        relayout(motion: .reshape)
    }

    func dragMoved(to point: CGPoint?, pasteboard: NSPasteboard, isTile: Bool) -> NSDragOperation {
        if drag == nil, !isTile { drag = Drag(payload: Self.payload(pasteboard)) }
        guard var drag else { return [] }
        let previous = drag
        var operation: NSDragOperation = []
        switch drag.payload {
        case .tile, .apps:
            drag.gap = point.map(gapIndex(at:))
            operation = point == nil ? [] : (isTile ? .move : .link)
        case .files(let urls):
            drag.target = point.flatMap { target(for: urls, at: $0) }
            operation = drag.target == nil ? [] : .generic
            springOverFinder(point.map { isFinder(at: $0) } ?? false)
        }
        self.drag = drag
        if previous.gap != drag.gap { relayout(motion: .reshape) }
        if previous.target != drag.target { view.setHighlighted(drag.target) }
        if point == nil, !isTile { endDrag() }
        return operation
    }

    func dropped(at point: CGPoint, pasteboard: NSPasteboard, isTile: Bool) -> Bool {
        guard let drag else { return false }
        defer { if !isTile { endDrag() } }
        switch drag.payload {
        case .tile(let kind):
            guard let gap = drag.gap, let app = kind.app else { return false }
            self.drag?.gap = nil
            pin([app], at: gap)
            return true
        case .apps(let new):
            guard let gap = drag.gap else { return false }
            self.drag?.gap = nil
            pin(new, at: gap)
            return true
        case .files(let urls):
            guard let target = drag.target, let app = target.app, let appURL = apps.entry(app)?.url else { return false }
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
    }

    func tileDragEnded(offTheDock: Bool) {
        if offTheDock, case .tile(let kind)? = drag?.payload, let app = kind.app, settings[Settings.pinned].contains(app) {
            unpin(app)
        }
        endDrag()
    }

    private func isFinder(at point: CGPoint) -> Bool {
        guard let layout, let slot = layout.tileIndex(at: point) else { return false }
        return kind(at: slot) == .finder
    }

    private func springOverFinder(_ over: Bool) {
        guard over else {
            spring?.cancel()
            spring = nil
            return
        }
        guard spring == nil else { return }
        let open = DispatchWorkItem { [weak self] in
            self?.spring = nil
            self?.onFiles?(nil, [])
        }
        spring = open
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.springDelay, execute: open)
    }

    private func endDrag() {
        spring?.cancel()
        spring = nil
        guard drag != nil else { return }
        drag = nil
        view.setHighlighted(nil)
        autoHide.hold(.drag, false)
        relayout(motion: .reshape)
    }

    private static func payload(_ pasteboard: NSPasteboard) -> Drag.Payload {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let bundles = urls.filter { $0.pathExtension == "app" }
        guard !bundles.isEmpty, bundles.count == urls.count else { return .files(urls) }
        return .apps(bundles.map { AppRef(bundleIdentifier: Bundle(url: $0)?.bundleIdentifier, path: $0.path) })
    }

    /// Where a pinned tile is among the pinned tiles on show: the gap it leaves when picked up.
    private func pinnedIndex(of kind: TileKind) -> Int? {
        guard case .app(let app) = kind else { return nil }
        return shownPinned.firstIndex(of: app)
    }

    /// How many of the pinned tiles on show, other than those being dragged, lie left of `point`. Measured
    /// against the row as drawn, gap included, so the gap stays put until the pointer passes the middle of
    /// the tile beside it.
    private func gapIndex(at point: CGPoint) -> Int {
        guard let layout else { return 0 }
        var pinned = Set(shownPinned)
        if case .apps(let apps)? = drag?.payload { pinned.subtract(apps) }
        return zip(view.items, layout.slots).filter { item, slot in
            guard case .tile(let tile) = item, case .app(let app) = tile.kind else { return false }
            return pinned.contains(app) && slot.frame.midX < point.x
        }.count
    }

    /// The tile under `point`, if its app opens every one of `urls`.
    private func target(for urls: [URL], at point: CGPoint) -> TileKind? {
        guard let layout, let slot = layout.tileIndex(at: point), let kind = kind(at: slot),
              case .app(let app) = kind, let appURL = apps.entry(app)?.url, !urls.isEmpty else { return nil }
        let opens = urls.allSatisfy { url in
            NSWorkspace.shared.urlsForApplications(toOpen: url).contains { $0.standardizedFileURL == appURL.standardizedFileURL }
        }
        return opens ? kind : nil
    }
}
