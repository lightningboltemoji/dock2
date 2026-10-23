import AppKit
import ApplicationServices

/// The windows of the apps on the dock through Accessibility — title, size, minimised, main — kept current by
/// their notifications on a thread of dock2's own, since an app that hangs holds up whoever asks it. `windows`
/// arrives on the main actor; without Accessibility nothing is watched, and each `watch` tries again.
public final class AppWindows: @unchecked Sendable {
    public struct Window: Sendable, Equatable, Identifiable {
        /// dock2's own number for the window, for as long as it lives.
        public let id: Int
        public let pid: pid_t
        public var title: String
        public var size: CGSize
        public var isMinimised: Bool
        public var isMain: Bool
        /// Among the minimised windows, the order they were minimised in. A group of tabs is minimised
        /// together, every tab saying so, the one on show last.
        public var minimisedOrder: Int
    }

    /// The standard and minimised windows of the apps watched: app by app, as `watch` ordered them, then as
    /// each app lists them.
    @MainActor public private(set) var windows: [Window] = []
    /// `windows` changed.
    @MainActor public var onChange: (() -> Void)?

    private let thread = RunLoopThread(name: "zip.tanner.dock2.windows")
    private var runLoop: CFRunLoop { thread.runLoop }

    // Everything below is the thread's alone.
    private var apps: [pid_t: App] = [:]
    private var order: [pid_t] = []
    private var published: [Window] = []
    private var lastID = 0
    private var lastMinimised = 0

    private final class App {
        let pid: pid_t
        let element: AXUIElement
        let observer: AXObserver
        var windows: [(element: AXUIElement, window: Window)] = []

        init(pid: pid_t, element: AXUIElement, observer: AXObserver) {
            (self.pid, self.element, self.observer) = (pid, element, observer)
        }
    }

    public init() {}

    /// Watches these apps' windows and no others', listing them in this order.
    @MainActor public func watch(_ pids: [pid_t]) {
        thread.perform { [self] in
            order = pids
            for pid in Set(apps.keys).subtracting(pids) { forget(pid) }
            if AXIsProcessTrusted() {
                for pid in pids where apps[pid] == nil { start(pid) }
            }
            publish()
        }
    }

    /// Brings the window forward, out of the Dock if it is minimised, and its app to the front.
    @MainActor public func raise(_ id: Int) {
        thread.perform { [self] in
            guard let app = apps.values.first(where: { $0.windows.contains { $0.window.id == id } }),
                  let element = app.windows.first(where: { $0.window.id == id })?.element else { return }
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(app.element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }

    // MARK: - On the thread

    private func start(_ pid: pid_t) {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1)
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            Unmanaged<AppWindows>.fromOpaque(refcon).takeUnretainedValue().handle(notification as String, element)
        }, &observer) == .success, let observer else { return }
        // An app still launching refuses; it is tried again at the next `watch`, which its launch ending brings.
        guard AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, refcon) == .success else { return }
        for name in [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        let app = App(pid: pid, element: element, observer: observer)
        apps[pid] = app
        for window in Self.value(of: element, kAXWindowsAttribute) as? [AXUIElement] ?? [] { add(window, to: app) }
    }

    private func forget(_ pid: pid_t) {
        guard let app = apps.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(app.observer), .defaultMode)
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// Takes a window on if it is one a person works in: standard, or minimised — which a minimised window
    /// does not say of itself, its subrole read as a dialog's.
    private func add(_ element: AXUIElement, to app: App) {
        guard !app.windows.contains(where: { $0.element == element }) else { return }
        lastID += 1
        var window = Window(id: lastID, pid: app.pid, title: "", size: .zero, isMinimised: false, isMain: false, minimisedOrder: 0)
        guard Self.value(of: element, kAXRoleAttribute) as? String == kAXWindowRole, read(element, into: &window) || window.isMinimised else { return }
        AXObserverAddNotification(app.observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
        AXObserverAddNotification(app.observer, element, kAXTitleChangedNotification as CFString, refcon)
        app.windows.append((element, window))
    }

    /// Reads a window's state into `window`, numbering it among the minimised if it has just become one;
    /// whether it is a standard window.
    @discardableResult
    private func read(_ element: AXUIElement, into window: inout Window) -> Bool {
        let attributes = [kAXTitleAttribute, kAXSizeAttribute, kAXMinimizedAttribute, kAXMainAttribute, kAXSubroleAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
              let values = values as? [Any], values.count == 5 else { return false }
        window.title = values[0] as? String ?? ""
        if CFGetTypeID(values[1] as CFTypeRef) == AXValueGetTypeID() {
            var size = CGSize.zero
            if AXValueGetValue(values[1] as! AXValue, .cgSize, &size) { window.size = size }
        }
        setMinimised(values[2] as? Bool ?? false, &window)
        window.isMain = values[3] as? Bool ?? false
        return values[4] as? String == kAXStandardWindowSubrole
    }

    private func setMinimised(_ minimised: Bool, _ window: inout Window) {
        if minimised, !window.isMinimised {
            lastMinimised += 1
            window.minimisedOrder = lastMinimised
        }
        window.isMinimised = minimised
    }

    private func handle(_ notification: String, _ element: AXUIElement) {
        var pid: pid_t = 0
        let app = AXUIElementGetPid(element, &pid) == .success ? apps[pid] : nil
        guard let app = app ?? apps.values.first(where: { $0.windows.contains { $0.element == element } }) else { return }
        let index = app.windows.firstIndex { $0.element == element }
        switch notification {
        case kAXWindowCreatedNotification:
            add(element, to: app)
        case kAXUIElementDestroyedNotification:
            if let index { app.windows.remove(at: index) }
        case kAXMainWindowChangedNotification:
            for i in app.windows.indices { app.windows[i].window.isMain = app.windows[i].element == element }
        case kAXWindowMiniaturizedNotification where index == nil:
            add(element, to: app)
        default:
            guard let index else { return }
            read(element, into: &app.windows[index].window)
            // Said by the notification itself, in case the window has not caught up when asked.
            if notification == kAXWindowMiniaturizedNotification { setMinimised(true, &app.windows[index].window) }
            if notification == kAXWindowDeminiaturizedNotification { setMinimised(false, &app.windows[index].window) }
        }
        publish()
    }

    private func publish() {
        let windows = order.flatMap { apps[$0]?.windows.map(\.window) ?? [] }
        guard windows != published else { return }
        published = windows
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                self.windows = windows
                onChange?()
            }
        }
    }

    private static func value(of element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}
