import AppKit
import Dock2Core

/// The regular apps that are running — the ones with a place in the Dock and ⌘⇥ — in the order they
/// started, and which of them are still launching. dock2 itself is never among them.
@MainActor
public final class RunningApps {
    public struct App: Equatable {
        public let ref: AppRef
        public let pid: pid_t
        public let isFinishedLaunching: Bool
    }

    public private(set) var apps: [App] = []
    /// The list changed: an app started, finished launching, quit, or changed its activation policy.
    public var onChange: (() -> Void)?
    /// An app is about to start, before it is in the list: the dock bounces it from here.
    public var onWillLaunch: ((AppRef) -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var observers: [NSObjectProtocol] = []
    /// One per app still launching, until it finishes.
    private var launches: [pid_t: NSKeyValueObservation] = [:]

    public init() {
        refresh()
        observations.append(NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        })
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let ref = Self.ref(app)
            MainActor.assumeIsolated { if let ref { self?.onWillLaunch?(ref) } }
        })
    }

    public func isRunning(_ ref: AppRef) -> Bool {
        apps.contains { $0.ref == ref }
    }

    public func isLaunching(_ ref: AppRef) -> Bool {
        apps.contains { $0.ref == ref && !$0.isFinishedLaunching }
    }

    public func running(_ ref: AppRef) -> NSRunningApplication? {
        guard let app = apps.first(where: { $0.ref == ref }) else { return nil }
        return NSRunningApplication(processIdentifier: app.pid)
    }

    private func refresh() {
        let me = getpid()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
            .sorted { ($0.launchDate ?? .distantPast, $0.processIdentifier) < ($1.launchDate ?? .distantPast, $1.processIdentifier) }
        let apps = running.compactMap { app in
            Self.ref(app).map { App(ref: $0, pid: app.processIdentifier, isFinishedLaunching: app.isFinishedLaunching) }
        }
        // Finishing a launch is no change to `runningApplications`; the app itself reports it.
        let unfinished = Set(running.filter { !$0.isFinishedLaunching }.map(\.processIdentifier))
        launches = launches.filter { unfinished.contains($0.key) }
        for app in running where !app.isFinishedLaunching && launches[app.processIdentifier] == nil {
            launches[app.processIdentifier] = app.observe(\.isFinishedLaunching) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
            }
        }
        guard apps != self.apps else { return }
        self.apps = apps
        onChange?()
    }

    nonisolated public static func ref(_ app: NSRunningApplication) -> AppRef? {
        guard let url = app.bundleURL ?? app.executableURL else { return nil }
        return AppRef(bundleIdentifier: app.bundleIdentifier, path: url.path)
    }
}
