import AppKit
import Dock2Core
import Dock2Plugins
import Dock2System
import SwiftUI

/// The app: the first launch if it has not run, then the guard, the takeovers the settings ask for, and the
/// stage; everything given back on the way out.
@MainActor
public final class AppController: NSObject, NSApplicationDelegate {
    private let lock: InstanceLock
    private let settings = SettingsStore()
    private let guardKeeper = GuardKeeper()
    private let running = RunningApps()
    private let apps = AppDirectory()
    private let catalog = AppCatalog()
    private let usage = Usage()
    private let picks = PicksStore()
    /// Files' operations, which carry on with the panel dismissed.
    private let operations = FileOperations()
    private var clipboard: ClipboardController?
    private var clipboardShortcut: HotKeys.Registration?
    /// Which global shortcuts the system refused, for Settings to say so.
    private let shortcutStatus = ShortcutStatus()
    private var plugins: PluginsController?
    private var search: SearchController?
    private var takeovers: Takeovers?
    private var stage: Stage?
    private var dock: DockController?
    private var panel: PanelController?
    private var interaction: InteractionController?
    private var pointer: PointerMonitor?
    private var summon: HotKeys.Registration?
    private var observations: [SettingsObservation] = []
    private var settingsWindow: SettingsWindowController?
    private var onboarding: NSWindow?
    private var onboardingClose: NSObjectProtocol?
    /// Settings and the first launch: while either is open dock2 is a regular app.
    private var ordinaryWindows: Set<String> = []
    private var signalSources: [DispatchSourceSignal] = []
    private var observers: [NSObjectProtocol] = []

    /// `lock` is held for the controller's life: it is what makes the journal this process's.
    public init(lock: InstanceLock) {
        self.lock = lock
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(settings: #selector(openSettings), target: self)
        // For development: dock2 in one appearance whatever the system's, to check the other without
        // changing the Mac's.
        if let look = ProcessInfo.processInfo.environment["DOCK2_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        }
        handleSignals()
        // Reading the journal changes nothing; a run that died left the user's state in it.
        let takeovers = Takeovers()
        self.takeovers = takeovers
        if settings[Settings.onboarded] {
            start()
        } else {
            // Nothing is taken over before the first launch ends, so anything held is a dead run's.
            takeovers.release(allBut: [])
            showFirstLaunch(firstRun: true)
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        plugins?.host.stopAll()
        guardKeeper.stop()
        guard let takeovers else { return }
        let held = !takeovers.journal.entries.isEmpty
        let kept = takeovers.releaseAll()
        if !kept.isEmpty {
            warn("could not give back \(kept.map(\.description).joined(separator: ", ")); the guard tries again as dock2 exits")
        } else if held {
            note("gave back the system Dock and every takeover")
        }
    }

    /// dock2 proper: the guard, then the takeovers, then the stage.
    private func start() {
        guard stage == nil, let takeovers else { return }
        // The guard first, so there is never a moment something is taken over and nothing will give it back.
        guardKeeper.start()
        let wanted: Set<TakeoverID> = Set([.systemDock] + (takesSpotlightsShortcut ? [.hotKey(HotKeyTable.spotlight)] : [])
                                          + (takesFileViewer ? [.fileViewer] : []))
        takeovers.release(allBut: wanted)
        for id in wanted.sorted() {
            do {
                try takeovers.engage(id)
            } catch {
                warn("could not journal \(id), so it is left alone: \(error.localizedDescription)")
            }
        }

        let stage = Stage(screen: NSScreen.screens.first ?? NSScreen.main!)
        self.stage = stage
        let dock = DockController(stage: stage, settings: settings, running: running, apps: apps)
        self.dock = dock
        dock.onQuit = { NSApp.terminate(nil) }
        dock.onOpenSettings = { [weak self] in self?.openSettings() }
        dock.start()
        let panel = PanelController(stage: stage)
        self.panel = panel
        let interaction = InteractionController(stage: stage, panel: panel, dock: dock, settings: settings)
        self.interaction = interaction
        interaction.onOpenSettings = { [weak self] in self?.openSettings() }
        interaction.start()
        // An app moved or updated: its tile and its results find it as it is now.
        catalog.onChange = { [weak self] in
            guard let self, self.apps.forgetChanged(self.catalog.apps) else { return }
            self.dock?.relayout(motion: nil)
        }
        catalog.start()
        let files = FilesScreen(operations: operations, settings: settings)
        operations.observe { [weak dock, weak operations] in dock?.setFilesProgress(operations?.fraction(olderThan: FilesBanner.delay)) }
        interaction.files = files
        dock.onFiles = { [weak interaction] folder, urls in interaction?.showFiles(revealing: urls, at: folder) }
        dock.onOpenedApp = { [usage] app in usage.record(AppsSource.id(app)) }
        let clipboard = ClipboardController(settings: settings)
        self.clipboard = clipboard
        clipboard.notice = { [weak panel] text in panel?.notice(text) }
        clipboard.start()
        interaction.clipboard = clipboard
        let pluginStore = PluginStore()
        let plugins = PluginsController(host: PluginHost(store: pluginStore, nowPlaying: NowPlaying()), dock: dock, panel: panel,
                                        settings: settings)
        plugins.interaction = interaction
        interaction.onUserMovedOn = { [weak plugins] in plugins?.host.userMovedOn() }
        self.plugins = plugins
        let actions = ResultActions(dock: dock, settings: settings, running: running,
                                    openSettings: { [weak self] in self?.openSettings() },
                                    showInFiles: { [weak interaction] urls in interaction?.showFiles(revealing: urls) },
                                    quickLook: { [weak interaction] url in interaction?.showQuickLook(url) },
                                    clipboard: clipboard,
                                    openClipboardHistory: { [weak interaction] in interaction?.showClipboardHistory() },
                                    plugins: plugins)
        let builtIn: [SearchSource] = [AppsSource(catalog: catalog, running: running, usage: usage), CommandsSource(usage: usage),
                                       PluginCommandsSource(store: pluginStore, usage: usage),
                                       ClipboardSource(clipboard: clipboard, settings: settings), FilesSource(settings: settings)]
        // A section for each plugin that answers search, in the order they are installed.
        let withPlugins = { [weak plugins, settings] () -> [SearchSource] in
            guard let plugins else { return builtIn }
            let answering = pluginStore.plugins.filter { $0.manifest.results != nil }.ordered(by: settings[Settings.pluginOrder])
            return builtIn + answering.enumerated().map { order, plugin in
                PluginResultsSource(plugin: plugin, order: order, plugins: plugins)
            }
        }
        let search = SearchController(sources: withPlugins(), panel: panel, dock: dock, picks: picks, usage: usage, actions: actions)
        pluginStore.onChange = { [weak search] in search?.sources = withPlugins() }
        observations.append(settings.observe(Settings.pluginOrder) { [weak search] _ in search?.sources = withPlugins() })
        search.isOff = { [settings] section in settings[Settings.searchSourcesOff].contains(section.title) }
        // `dock2 plugin install` and `remove`, from a terminal.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: PluginStore.changedNotification, object: nil,
                                                                             queue: .main) { [weak plugins] note in
            guard let id = note.userInfo?[PluginStore.pluginKey] as? String else { return }
            MainActor.assumeIsolated { plugins?.host.changedElsewhere(id) }
        })
        self.search = search
        search.fileAccess = { [settings] in settings[Settings.fileAccess] }
        observers.append(NotificationCenter.default.addObserver(forName: FileAccess.foldersChanged, object: nil, queue: .main) { [weak search, weak interaction] _ in
            MainActor.assumeIsolated { search?.requery(now: interaction?.views?.top == nil) }
        })
        // Learned off the main thread from launch, so Files' first look finds macOS's answers known.
        if settings[Settings.fileAccess] == .folders, !FileAccess.hasFullDiskAccess { _ = FileAccess.refused }
        search.notes = { [settings] in
            guard !FileAccess.hasFullDiskAccess else { return [:] }
            guard settings[Settings.fileAccess] == .folders else { return [.files: "Not searched: Desktop, Documents and Downloads"] }
            // Asked about each: what macOS refused, by name, and other apps' data.
            let refused = FileAccess.protectedFolders.filter(FileAccess.refused.contains).map(\.lastPathComponent)
            return [.files: "Not searched: " + (refused + ["other apps' data"]).joined(separator: ", ")]
        }
        search.onNote = { [weak self] _ in self?.showSettings(at: .permissions) }
        interaction.views = ViewsController(panel: panel)
        interaction.search = search
        let pointer = PointerMonitor()
        pointer.onMove { [weak dock, weak panel] point, window in
            dock?.pointerMoved(to: point, over: window)
            panel?.pointerMoved(to: point, over: window)
        }
        self.pointer = pointer
        stage.show()
        plugins.host.startTiles()
        applySummon()
        observations.append(settings.observe(Settings.summon) { [weak self] _ in self?.applySummon() })
        applyClipboardShortcut()
        observations.append(settings.observe(Settings.clipboardShortcut) { [weak self] _ in self?.applyClipboardShortcut() })
        observations.append(settings.observe(Settings.showInFinderTakeover) { [weak self] _ in self?.applyFileViewer() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let stage = self.stage else { return }
                stage.move(to: NSScreen.screens.first ?? stage.screen)
                self.dock?.relayout(motion: nil)
            }
        })
        // Sent while dock2 was starting: "Show in Finder" launched it.
        let early = pendingReveal
        pendingReveal = []
        if !early.isEmpty { application(NSApp, open: early) }
    }

    // MARK: - The summon shortcut

    /// ⌘space is Spotlight's until dock2 takes it over, which it can only where the hot key table exists.
    private var takesSpotlightsShortcut: Bool {
        settings[Settings.summon] == .commandSpace && HotKeyTable.isAvailable
    }

    /// Takes over Spotlight's ⌘space, or gives it back, as the setting now asks; then registers the chord.
    private func applySummon() {
        guard let takeovers else { return }
        summon = nil
        let spotlight = TakeoverID.hotKey(HotKeyTable.spotlight)
        var chord: KeyChord?
        switch settings[Settings.summon] {
        case .commandSpace where takesSpotlightsShortcut:
            do {
                try takeovers.engage(spotlight)
                chord = KeyChord(keyCode: KeyChord.space, modifiers: KeyChord.command)
            } catch {
                warn("could not journal Spotlight's shortcut, so ⌘space is left to it: \(error.localizedDescription)")
            }
        case .chord(let custom):
            chord = custom
        case .commandSpace, .none:
            break
        }
        if chord?.keyCode != KeyChord.space || chord?.modifiers != KeyChord.command, takeovers.holds(spotlight) {
            takeovers.release(spotlight)
        }
        if let chord {
            summon = HotKeys.register(chord) { [weak self] in self?.interaction?.summon() }
        }
        shortcutStatus.set(Settings.summon.name, registered: chord == nil || summon != nil)
    }

    /// Clipboard History's own shortcut, if the user set one.
    private func applyClipboardShortcut() {
        clipboardShortcut = nil
        defer { shortcutStatus.set(Settings.clipboardShortcut.name, registered: clipboardShortcut != nil || settings[Settings.clipboardShortcut] == .none) }
        guard case .chord(let chord) = settings[Settings.clipboardShortcut] else { return }
        clipboardShortcut = HotKeys.register(chord) { [weak self] in self?.interaction?.showClipboardHistory() }
    }

    // MARK: - "Show in Finder"

    /// Only an app LaunchServices knows by dock2's identifier can be named the file viewer: a build run
    /// from a terminal would leave every app's "Show in Finder" going nowhere.
    private var takesFileViewer: Bool {
        settings[Settings.showInFinderTakeover] && Bundle.main.bundleIdentifier == Dock2Identity.bundleIdentifier
    }

    private func applyFileViewer() {
        guard let takeovers else { return }
        if takesFileViewer {
            do {
                try takeovers.engage(.fileViewer)
            } catch {
                warn("could not journal the file viewer, so Show in Finder is left to Finder: \(error.localizedDescription)")
            }
        } else if takeovers.holds(.fileViewer) {
            takeovers.release(.fileViewer)
        }
    }

    /// "Show in Finder" from any app, once dock2 is the file viewer: every item it is sent is a reveal —
    /// kept until dock2 has started, when the reveal is what launched it, since AppKit sends it first.
    public func application(_ application: NSApplication, open urls: [URL]) {
        guard let interaction else {
            pendingReveal += urls.filter(\.isFileURL)
            return
        }
        guard takeovers?.holds(.fileViewer) == true else { return }
        interaction.reveal(urls.filter(\.isFileURL))
    }

    private var pendingReveal: [URL] = []

    // MARK: - The first launch

    /// The first launch's sequence. On a first run its last page copies the system Dock and starts dock2;
    /// run again from Settings it applies only the choices, and shows dock2's own dock.
    private func showFirstLaunch(firstRun: Bool) {
        guard onboarding == nil, let takeovers else { return }
        let system = SystemDockSettings.read(takeovers.usersDockPreference)
        var shown = system
        if !firstRun {
            shown.pinned = settings[Settings.pinned]
            shown.tileSize = settings[Settings.tileSize]
            shown.autohide = settings[Settings.autohide]
        }
        let icons = ([AppRef.finder] + shown.pinned).compactMap { apps.entry($0)?.icon }
        let view = OnboardingView(dock: shown, preview: { DockPreview(icons: icons, tileSize: shown.tileSize) },
                                  finish: { [weak self] choices in self?.finishFirstLaunch(choices, copying: firstRun ? system : nil) },
                                  quit: { [weak self] in firstRun ? NSApp.terminate(nil) : self?.onboarding?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to dock2"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(window.contentViewController?.view.fittingSize ?? NSSize(width: 620, height: 440))
        window.center()
        onboarding = window
        onboardingClose = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onboarding = nil
                self.onboardingClose.map(NotificationCenter.default.removeObserver)
                self.onboardingClose = nil
                self.setOrdinaryWindow("onboarding", open: false)
                // Closed before its end on a first run: nothing changed, so dock2 has nothing to do.
                if firstRun, !self.settings[Settings.onboarded] { NSApp.terminate(nil) }
            }
        }
        setOrdinaryWindow("onboarding", open: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finishFirstLaunch(_ choices: OnboardingChoices, copying system: SystemDockSettings?) {
        if let system {
            system.copy(into: settings)
            note("copied the system Dock's settings: \(settings[Settings.pinned].count) apps, tile size \(settings[Settings.tileSize])")
        }
        settings[Settings.summon] = choices.summon
        settings[Settings.fileAccess] = choices.fileAccess
        settings[Settings.showInFinderTakeover] = choices.showInFinder
        settings[Settings.clipboardHistory] = choices.clipboard
        if LoginItem.isEnabled != choices.openAtLogin, let error = LoginItem.set(choices.openAtLogin) {
            warn("could not change open at login: \(error)")
        }
        settings[Settings.onboarded] = true
        onboarding?.close()
        start()
        // Sent to System Settings for Full Disk Access: dock2 says when it lands.
        if choices.fileAccess == .fullDisk, !FileAccess.hasFullDiskAccess {
            FileAccess.awaitFullDiskAccess { [weak self] in self?.panel?.notice("dock2 can see all your files now") }
        }
    }

    // MARK: - Settings

    @objc func openSettings() {
        showSettings(at: nil)
    }

    private func showSettings(at section: SettingsView.Section?) {
        let controller = settingsWindow ?? {
            let actions = SettingsActions(quit: { NSApp.terminate(nil) },
                                          runFirstLaunch: { [weak self] in self?.showFirstLaunch(firstRun: false) },
                                          collectLogs: { Self.collectLogs() },
                                          clearClipboard: { [weak self] in self?.clipboard?.clear() },
                                          clipboardUnsaved: { [weak self] in self?.clipboard?.isUnsaved ?? false },
                                          plugins: plugins.map { PluginsModel(host: $0.host) }, picks: picks,
                                          shortcuts: shortcutStatus)
            let controller = SettingsWindowController(model: SettingsModel(store: settings), actions: actions)
            controller.onVisibilityChange = { [weak self] open in self?.setOrdinaryWindow("settings", open: open) }
            return controller
        }()
        settingsWindow = controller
        if let interaction { interaction.handOver { controller.show(section) } } else { controller.show(section) }
    }

    /// dock2 has a menu bar and a place in ⌘⇥ exactly while an ordinary window is open.
    private func setOrdinaryWindow(_ name: String, open: Bool) {
        if open { ordinaryWindows.insert(name) } else { ordinaryWindows.remove(name) }
        let policy: NSApplication.ActivationPolicy = ordinaryWindows.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    /// The last day of dock2's log, in `~/Library/Logs/dock2`, shown in Finder.
    private static func collectLogs() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/dock2")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent("dock2-\(stamp).log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "1d", "--style", "compact", "--predicate", "subsystem == \"\(Dock2Identity.bundleIdentifier)\""]
        process.standardOutput = handle
        process.terminationHandler = { _ in
            try? handle.close()
            DispatchQueue.main.async { MainActor.assumeIsolated { FileViewerTakeover.showInFinder([file]) } }
        }
        do { try process.run() } catch { warn("could not collect logs: \(error.localizedDescription)") }
    }

    // MARK: - Signals

    /// Ctrl-C, `kill` and a hangup quit the way Quit does, which gives everything back.
    private func handleSignals() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }
}
