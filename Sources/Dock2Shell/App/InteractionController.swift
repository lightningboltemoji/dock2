import AppKit
import Carbon.HIToolbox
import Dock2Core
import Dock2Plugins
import Dock2System

/// Runs `Interaction` against the real system — the dwell, the typing guard, every dismissal — taking the
/// keyboard by making the stage key and giving it back with `NSApp.deactivate()` (IMPLEMENTATION.md §6).
@MainActor
final class InteractionController {
    private var state: Interaction
    private let stage: Stage
    private let panel: PanelController
    private let dock: DockController
    private let settings: SettingsStore
    private var dwell: DispatchSourceTimer?
    private var badges: DispatchWorkItem?
    private var outsideClicks: Any?
    private var observers: [NSObjectProtocol] = []
    private var observations: [SettingsObservation] = []
    /// Set while dock2 itself is about to come forward: then letting go of the keyboard must not deactivate it.
    private var handingOver = false
    var onOpenSettings: (() -> Void)?
    /// dock2 dismissed, or another app in front: the user has moved on from what they asked for.
    var onUserMovedOn: (() -> Void)?
    var search: SearchController? {
        didSet {
            search?.onDone = { [weak self] in self?.handle(.dismiss) }
            search?.onShowAll = { [weak self] host in
                self?.views?.push(host)
                self?.updateEngagement()
            }
            search?.onShowAllFiles = { [weak self] text, found in self?.showFiles(searching: text, found: found) }
        }
    }
    var views: ViewsController? {
        didSet {
            views?.onDismiss = { [weak self] in self?.handle(.dismiss) }
            views?.onPopToSearch = { [weak self] query in
                self?.panel.field.string = query
                self?.panel.focus()
            }
        }
    }

    var files: FilesScreen? {
        didSet {
            files?.onDismiss = { [weak self] in self?.handle(.dismiss) }
            files?.toast = { [weak self] text in self?.panel.toast(text) }
            files?.notice = { [weak self] text in self?.panel.notice(text) }
            files?.confirm = { [weak self] title, run in self?.panel.confirm(title, run) }
        }
    }

    /// ⌘ held alone this long shows the number badges.
    private static let badgeDelay = 0.3

    init(stage: Stage, panel: PanelController, dock: DockController, settings: SettingsStore) {
        self.stage = stage
        self.panel = panel
        self.dock = dock
        self.settings = settings
        state = Interaction(revealToType: settings[Settings.typeToSearch])
    }

    var hasKeyboard: Bool { state.hasKeyboard }
    var phase: Interaction.Phase { state.phase }

    func start() {
        dock.onPointerOnDock = { [weak self] on in self?.handle(.pointerOnDock(on)) }
        dock.onPlatterClick = { [weak self] in self?.handle(.request) }
        dock.onOpened = { [weak self] in
            guard let self, self.state.hasKeyboard else { return }
            self.handle(.dismiss)
        }
        panel.platter = { [weak self] in self?.dock.platter }
        panel.field.onTextChange = { [weak self] text in
            guard let self else { return }
            self.panel.feedback.cancel()
            // A path is Files' to follow, in its own path bar.
            // As search reads a query: its spaces at either end aside.
            let query = Query(text).text
            if self.views?.isActive != true, PathInput.isPath(query), let files = self.files {
                self.panel.field.string = ""
                self.views?.push(files)
                files.beginPath(query)
                self.updateEngagement()
                return
            }
            if self.views?.isActive == true { self.views?.filter(text) } else { self.search?.update(text) }
            self.updateEngagement()
        }
        panel.field.onCommand = { [weak self] selector in self?.command(selector) ?? false }
        stage.window.onKeyEquivalent = { [weak self] event in self?.keyEquivalent(event) ?? false }
        stage.window.onKeyActivity = { [weak self] event in self?.keyActivity(event) ?? false }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                           object: nil, queue: .main) { [weak self] note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.activated(app) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resigned() }
        })
        observations.append(settings.observe(Settings.typeToSearch) { [weak self] on in self?.state.revealToType = on })
    }

    func summon() { handle(.summon) }

    /// A query typed, or a view open: dock2 stays when the pointer leaves.
    private func updateEngagement() {
        handle(.panelEngaged(!panel.field.string.isEmpty || views?.isActive == true))
    }

    /// A request for the keyboard that no guard holds back: "Show in Finder", a click on the platter.
    func request() { handle(.request) }

    var clipboard: ClipboardController?

    /// A plugin's view, over the search or from nothing — a tile clicked, a command's shortcut.
    func showPluginView(_ host: PluginViewHost) {
        guard let views else { return }
        let fromSearch = state.hasKeyboard && (!panel.field.string.isEmpty || views.isActive)
        if !state.hasKeyboard { handle(.request) }
        views.push(NodeScreen(host: host, context: views.context), fromSearch: fromSearch)
        updateEngagement()
    }

    func isShowing(_ host: ViewHost) -> Bool {
        (views?.top as? NodeScreen)?.host === host
    }

    /// A plugin's popView: back one level, as Esc would.
    func popView() {
        views?.pop()
        updateEngagement()
    }

    /// Clipboard History, over the search or from nothing: the command, or its shortcut.
    func showClipboardHistory() {
        guard let clipboard, let views else { return }
        let fromSearch = state.hasKeyboard && !panel.field.string.isEmpty
        if !state.hasKeyboard { handle(.request) }
        let host = ClipboardHost(clipboard: clipboard, settings: settings) { [weak self] url in self?.showQuickLook(url) }
        clipboard.onChange = { [weak host] in host?.refresh() }
        views.push(NodeScreen(host: host, context: views.context), fromSearch: fromSearch)
        updateEngagement()
    }

    /// ⌘Y on a file result: the file on the stack, over the search.
    func showQuickLook(_ url: URL) {
        guard let views else { return }
        views.push(QuickLookScreen(url))
        updateEngagement()
    }

    /// The app last in front, dock2 aside: the one a reveal hands the front back to.
    private var lastFront = NSWorkspace.shared.frontmostApplication?.processIdentifier
    /// Until then, a reveal is being handed over: LaunchServices bringing dock2 forward is undone, and the
    /// asking app coming back is no reason to let go.
    private var revealing: Date?
    /// A reveal's items, waiting for dock2 to have let go of the front before Files takes the keyboard: a
    /// panel made key while dock2 is active loses it as dock2 resigns.
    private var pendingReveal: [URL]?

    /// Another app coming forward is a dismissal ([interaction](product/interaction.md#moves)).
    private func activated(_ app: pid_t?) {
        if app != getpid() { onUserMovedOn?() }
        let inReveal = revealing.map { Date() < $0 } ?? false
        if app == getpid() {
            if inReveal { handFrontBack() } else if state.hasKeyboard { handle(.dismiss) }
            return
        }
        let returning = app == lastFront
        lastFront = app
        guard state.hasKeyboard, !(inReveal && returning) else { return }
        handle(.dismiss)
    }

    /// dock2 no longer in front: a reveal's Files takes the keyboard now, or takes it back.
    private func resigned() {
        guard revealing.map({ Date() < $0 }) ?? false else { return }
        if let urls = pendingReveal {
            pendingReveal = nil
            showFiles(revealing: urls)
        } else if state.hasKeyboard, !stage.window.isKeyWindow {
            stage.window.makeKey()
            views?.top?.focus()
        }
    }

    /// "Show in Finder" taken over: LaunchServices brought dock2 forward to hand it the items. The app that
    /// asked goes back in front, and Files takes the keyboard over it, as any summon does.
    func reveal(_ urls: [URL]) {
        revealing = Date().addingTimeInterval(1)
        guard NSApp.isActive else {
            showFiles(revealing: urls)
            return
        }
        pendingReveal = urls
        handFrontBack()
        // Should the asking app not come back, Files opens all the same.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let urls = self.pendingReveal else { return }
            self.pendingReveal = nil
            self.showFiles(revealing: urls)
        }
    }

    /// Under cooperative activation an app gives the front away explicitly: deactivating leaves it nowhere.
    private func handFrontBack() {
        guard NSApp.isActive else { return }
        guard let pid = lastFront, let app = NSRunningApplication(processIdentifier: pid) else {
            NSApp.deactivate()
            return
        }
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }

    /// Files, with `urls` selected, or at `folder`, or searching the Mac for `text`, or where it was: the
    /// Finder tile, Show in Files, "Show in Finder", Files' "Show all…". From a query it goes back to the
    /// search; from nothing, Esc dismisses.
    func showFiles(revealing urls: [URL] = [], at folder: URL? = nil, searching text: String? = nil, found: [URL] = []) {
        guard let files, let views else { return }
        let fromSearch = state.hasKeyboard && (!panel.field.string.isEmpty || views.isActive)
        if !state.hasKeyboard { handle(.request) }
        if !urls.isEmpty { files.reveal(urls) } else if let folder { files.go(to: folder) }
        if views.top === files { files.focus() } else { views.push(files, fromSearch: fromSearch) }
        if let text { files.beginSearch(text, scope: nil, found: found) }
        updateEngagement()
    }

    func dismiss() { handle(.dismiss) }

    /// One of dock2's own windows opens from the panel: dock2 is dismissed without deactivating, which would
    /// take away the keyboard the window was just given.
    func handOver(_ open: () -> Void) {
        handingOver = true
        open()
        handle(.dismiss)
        handingOver = false
    }

    private func handle(_ event: Interaction.Event) {
        apply(state.handle(event))
    }

    private func apply(_ effects: [Interaction.Effect]) {
        for effect in effects {
            switch effect {
            case .startDwell(let delay):
                dwell?.cancel()
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + delay, leeway: .milliseconds(2))
                timer.setEventHandler { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.dwell?.cancel()
                        self.dwell = nil
                        let since = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                        self.handle(.dwellFired(secondsSinceKeystroke: since))
                    }
                }
                dwell = timer
                timer.resume()
            case .cancelDwell:
                dwell?.cancel()
                dwell = nil
            case .takeKeyboard:
                takeKeyboard()
            case .releaseKeyboard:
                releaseKeyboard()
            case .holdDock(let on):
                dock.hold(.engaged, on)
            }
        }
    }

    private func takeKeyboard() {
        // Over a full screen app, as Spotlight is; at rest the stage stays out of full screen Spaces.
        stage.window.collectionBehavior.insert(.fullScreenAuxiliary)
        stage.window.orderFrontRegardless()
        // Summoned with the dock away, the dock slides in after this: the field follows it up.
        panel.show(animated: true, after: dock.isShown ? 0 : EntryMotion.fieldLag)
        stage.window.makeKey()
        panel.focus()
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.hasKeyboard else { return }
                self.handle(.dismiss)
            }
        }
    }

    private func releaseKeyboard() {
        onUserMovedOn?()
        views?.closeAll()
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        hideBadges()
        dock.setRing(nil)
        panel.field.string = ""
        panel.hide(animated: true)
        if stage.window.isKeyWindow, !handingOver { NSApp.deactivate() }
        stage.window.collectionBehavior.remove(.fullScreenAuxiliary)
    }

    // MARK: - Keys

    /// The text system's commands from the field. With nothing typed the arrows walk the ring.
    private func command(_ selector: Selector) -> Bool {
        let empty = panel.field.string.isEmpty
        if let views, views.isActive {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                if empty { views.pop(); updateEngagement() } else { panel.field.string = "" }
                return true
            }
            return views.command(selector)
        }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if empty { handle(.dismiss) } else { panel.field.string = "" }
            return true
        case #selector(NSResponder.moveLeft(_:)) where empty:
            dock.moveRing(by: -1)
        case #selector(NSResponder.moveRight(_:)) where empty:
            dock.moveRing(by: 1)
        case #selector(NSResponder.moveToBeginningOfLine(_:)) where empty,
             #selector(NSResponder.moveToBeginningOfDocument(_:)) where empty,
             #selector(NSResponder.scrollToBeginningOfDocument(_:)) where empty:
            dock.ringToEnd(last: false)
        case #selector(NSResponder.moveToEndOfLine(_:)) where empty,
             #selector(NSResponder.moveToEndOfDocument(_:)) where empty,
             #selector(NSResponder.scrollToEndOfDocument(_:)) where empty:
            dock.ringToEnd(last: true)
        case #selector(NSResponder.insertNewline(_:)) where empty:
            dock.openRinged()
        case #selector(NSResponder.moveUp(_:)) where empty:
            dock.popUpRingedMenu()
        case #selector(NSResponder.moveUp(_:)):
            search?.moveSelection(by: 1)
        case #selector(NSResponder.moveDown(_:)):
            search?.moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            search?.runPrimary()
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            search?.runOption()
        default:
            return false
        }
        return true
    }

    /// ⌘-chords while the stage is key, before the field: ⌘1–9, ⌘W, ⌘,, ⌘K; ⌘Q quits nothing.
    private func keyEquivalent(_ event: NSEvent) -> Bool {
        panel.feedback.cancel()
        if views?.keyEquivalent(event) == true { return true }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        // A ⌘⇧ chord is a result's own, while the search is on top.
        if modifiers == [.command, .shift] { return views?.top == nil && search?.runShortcut(event) == true }
        guard modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if let digit = Int(key), (1...9).contains(digit) {
            hideBadges()
            dock.openTile(number: digit)
            return true
        }
        switch key {
        case "w":
            handle(.dismiss)
        case ",":
            onOpenSettings?()
        case "q":
            break
        // The search's own, only while it is on top: a view's unclaimed chords stop with it.
        case _ where views?.top != nil:
            return key == "\r" || key == "k"
        case "\r":
            search?.runSecondary()
        case "k":
            if panel.field.string.isEmpty { dock.popUpRingedMenu() } else { search?.showActions() }
        default:
            return key.count == 1 && search?.runShortcut(event) == true
        }
        return true
    }

    /// Number badges: ⌘ held alone for a moment; any other key or modifier ends them. And Esc while a form's
    /// own field has the keyboard, which the search field's delegate never hears: back one view.
    private func keyActivity(_ event: NSEvent) -> Bool {
        guard state.hasKeyboard else { return false }
        // A confirmation takes ↩ and Esc from whatever has the keys, a field or Files' columns.
        if event.type == .keyDown, panel.feedback.isConfirming {
            let key: Feedback.Key = switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter: .confirm
            case kVK_Escape: .cancel
            default: .other
            }
            if panel.feedback.answer(key) { return true }
        }
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape), let views, views.isActive,
           stage.window.firstResponder !== panel.field.text.currentEditor() {
            if !views.cancel() {
                views.pop()
                updateEngagement()
            }
            return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if event.type == .flagsChanged, modifiers == .command {
            guard badges == nil else { return false }
            let show = DispatchWorkItem { [weak self] in self?.dock.showBadges(true) }
            badges = show
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.badgeDelay, execute: show)
        } else {
            hideBadges()
        }
        return false
    }

    private func hideBadges() {
        badges?.cancel()
        badges = nil
        dock.showBadges(false)
    }
}
