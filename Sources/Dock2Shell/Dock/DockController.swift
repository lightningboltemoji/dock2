import AppKit
import Dock2Core

/// The app: starts the guard, hides the system Dock, shows dock2's, and puts the system Dock back on
/// the way out. Everything AppKit tells it — screens, appearance, apps launching and quitting — it
/// turns into calls on the view.
@MainActor
public final class DockController: NSObject, NSApplicationDelegate {
    private let lock: InstanceLock
    private let panel = DockPanel()
    private let view = DockView()
    private let label = LabelPanel()
    private var apps: [TileApp] = []
    private var layout: DockLayout?
    /// Tiles hopping because their app is starting, by bundle identifier.
    private var launching: Set<String> = []
    private var guardWatch: DispatchSourceProcess?
    private var guardStarts: [Date] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var observers: [NSObjectProtocol] = []
    private var terminating = false

    /// `lock` is held for the controller's life: it is what makes the journal this process's.
    public init(lock: InstanceLock) {
        self.lock = lock
        super.init()
    }

    // MARK: - Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // The guard first, so there is never a moment the Dock is hidden and nothing will bring it back.
        startGuard()
        do {
            try Suppressor.suppress()
        } catch {
            warn("could not record the system Dock's settings, so it is left alone: \(error.localizedDescription)")
        }

        apps = DockItem.pinned(environment: ProcessInfo.processInfo.environment).compactMap(TileApp.init)
        panel.contentView = view
        view.onHover = { [weak self] index in self?.hover(index) }
        view.onOpen = { [weak self] index in self?.open(index) }
        view.onQuit = { NSApp.terminate(nil) }
        relayout()
        panel.orderFrontRegardless()
        observe()
        handleSignals()
        note("dock2 \(dock2Version): \(apps.map(\.name).joined(separator: ", ")) at tile size \(SystemDock.tileSize)")
    }

    public func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        guardWatch?.cancel()
        if Suppressor.restore() { note("restored the system Dock") }
    }

    // MARK: - Layout

    /// Above the platter, room for a launch hop: half a tile, plus the rim.
    private static let headroom = 8.0
    /// Either side of the platter, room for its rim and the hairline outside it.
    private static let sideMargin = 8.0

    private func relayout() {
        guard let screen = NSScreen.screens.first else { return }
        let metrics = DockMetrics(tileSize: SystemDock.tileSize)
        let layout = DockLayout(metrics: metrics, tileCount: apps.count, screen: screen.frame)
        self.layout = layout
        let frame = CGRect(x: layout.platter.minX - Self.sideMargin, y: screen.frame.minY,
                           width: layout.platter.width + 2 * Self.sideMargin,
                           height: layout.platter.maxY - screen.frame.minY + metrics.tileSize / 2 + Self.headroom).integral
        panel.setFrame(frame, display: false)
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.show(layout, icons: apps.map(\.icon),
                  platterOrigin: CGPoint(x: Self.sideMargin, y: layout.platter.minY - screen.frame.minY),
                  scale: screen.backingScaleFactor)
        for (index, app) in apps.enumerated() { view.setRunning(app.isRunning, at: index) }
        label.orderOut(nil)
    }

    // MARK: - Tiles

    private func hover(_ index: Int?) {
        guard let index, let layout else {
            label.orderOut(nil)
            return
        }
        label.show(apps[index].name, centerX: layout.tiles[index].slot.midX, platterTop: layout.platter.maxY,
                   dark: view.isDark)
    }

    private func open(_ index: Int) {
        let app = apps[index]
        if !app.isRunning { setLaunching(true, app.item.bundleIdentifier) }
        app.open { [weak self] opened in
            if !opened { self?.setLaunching(false, app.item.bundleIdentifier) }
        }
        // An app that never reports in still stops hopping eventually, as in the Dock.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.setLaunching(false, app.item.bundleIdentifier)
        }
    }

    private func setLaunching(_ isLaunching: Bool, _ bundleIdentifier: String) {
        guard let index = apps.firstIndex(where: { $0.item.bundleIdentifier == bundleIdentifier }) else { return }
        if isLaunching ? launching.insert(bundleIdentifier).inserted : launching.remove(bundleIdentifier) != nil {
            view.setBouncing(isLaunching, at: index)
        }
    }

    private func setRunning(_ bundleIdentifier: String) {
        guard let index = apps.firstIndex(where: { $0.item.bundleIdentifier == bundleIdentifier }) else { return }
        view.setRunning(apps[index].isRunning, at: index)
    }

    // MARK: - The system

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        let bundleIdentifier = Self.bundleIdentifier
        observers.append(workspace.addObserver(forName: NSWorkspace.willLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let id = bundleIdentifier(note) else { return }
            MainActor.assumeIsolated { self?.setLaunching(true, id) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let id = bundleIdentifier(note) else { return }
            MainActor.assumeIsolated {
                self?.setLaunching(false, id)
                self?.setRunning(id)
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let id = bundleIdentifier(note) else { return }
            MainActor.assumeIsolated {
                self?.setLaunching(false, id)
                self?.setRunning(id)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        })
    }

    nonisolated private static func bundleIdentifier(_ note: Notification) -> String? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    /// Ctrl-C, `kill` and a hangup quit the way Quit does, which restores the Dock.
    private func handleSignals() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - The guard

    private func startGuard() {
        // A guard that dies as soon as it starts is not worth restarting forever.
        guardStarts = guardStarts.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
        guard guardStarts.count <= 5, let pid = Guard.spawn() else {
            warn("running without a guard: if dock2 crashes, `dock2 --restore` or its next launch brings the Dock back")
            return
        }
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watch.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                waitpid(pid, nil, WNOHANG)
                guard let self, !self.terminating else { return }
                warn("the guard (pid \(pid)) exited; starting another")
                self.guardWatch?.cancel()
                self.startGuard()
            }
        }
        watch.resume()
        guardWatch = watch
    }
}
