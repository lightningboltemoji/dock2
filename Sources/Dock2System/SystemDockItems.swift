import AppKit
import ApplicationServices
import Dock2Core

/// What the hidden system Dock shows that dock2 draws too, read through Accessibility on a thread of its
/// own: apps' badges, which an app tells only the Dock, and the minimised windows. Without Accessibility
/// both are empty, and each `watch` tries again.
public final class SystemDockItems: @unchecked Sendable {
    /// A minimised window as the Dock has it: a title, and nothing that says whose window it is.
    public struct Minimised: Sendable, Equatable, Identifiable {
        /// dock2's own number for the item, for as long as the Dock shows it.
        public let id: Int
        /// As the Dock has it now: it takes up a retitle made during the genie, not one made after.
        public let title: String
    }

    /// Each badged app's label as the Dock spells it: digits, a word, or a space for a bare dot.
    @MainActor public private(set) var badges: [AppRef: String] = [:]
    /// The minimised windows, in the order they were minimised; a group of tabs is one. One `open` pressed
    /// is gone at once, as the Dock's own gap starts closing, though the Dock keeps it until its window is back.
    @MainActor public private(set) var minimised: [Minimised] = []
    @MainActor public var onBadgesChange: (() -> Void)?
    @MainActor public var onMinimisedChange: (() -> Void)?

    /// The Dock posts nothing when a badge changes, so badges are read this often while the dock is on screen.
    public static let badgeInterval: TimeInterval = 0.25
    /// An item pressed that the Dock still has this long after is shown again: its window is not coming back.
    public static let leavingDeadline: TimeInterval = 2

    private let thread = RunLoopThread(name: "zip.tanner.dock2.system-dock")

    // Everything below is the thread's alone.
    private var dock: (pid: pid_t, list: AXUIElement, observer: AXObserver, exit: DispatchSourceProcess)?
    private var timer: CFRunLoopTimer?
    private var search: (timer: CFRunLoopTimer, attempts: Int)?
    private var items: [(element: AXUIElement, item: Minimised)] = []
    /// Items `open` pressed, left out of `minimised` until the Dock lets them go or the deadline passes.
    private var leaving: Set<Int> = []
    private var lastID = 0
    private var published: (badges: [AppRef: String], minimised: [Minimised]) = ([:], [])

    public init() {}

    /// Reads the Dock now and hears its minimised windows come and go from then on; reads its badges every
    /// `badgeInterval` while `shown`, and otherwise keeps those it last read.
    @MainActor public func watch(_ shown: Bool) {
        thread.perform { [self] in
            read()
            if shown, timer == nil {
                timer = thread.every(Self.badgeInterval) { [self] in read() }
            } else if !shown, let timer {
                CFRunLoopTimerInvalidate(timer)
                self.timer = nil
            }
        }
    }

    /// Brings the window back as a click on the Dock's own item does: restored, and its app in front.
    @MainActor public func open(_ id: Int) {
        thread.perform { [self] in
            guard let element = items.first(where: { $0.item.id == id })?.element,
                  AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { return }
            leaving.insert(id)
            read()
            thread.after(Self.leavingDeadline) { [self] in
                leaving.remove(id)
                read()
            }
        }
    }

    // MARK: - On the thread

    /// One reading of the Dock's items, in one call each — about 0.2 ms for them all.
    private func read() {
        guard AXIsProcessTrusted() else { return publish([:], []) }
        guard let list = attach() else {
            publish([:], [])
            return searchForDock()
        }
        endSearch()
        let attributes = [kAXSubroleAttribute, kAXURLAttribute, "AXStatusLabel", kAXTitleAttribute] as CFArray
        var badges: [AppRef: String] = [:]
        var minimised: [(element: AXUIElement, title: String)] = []
        for item in Self.children(list) {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(item, attributes, [], &values) == .success,
                  let values = values as? [Any], values.count == 4 else { continue }
            switch values[0] as? String {
            case "AXApplicationDockItem":
                guard let url = values[1] as? URL, let label = values[2] as? String else { continue }
                badges[AppRef(bundleIdentifier: Bundle(url: url)?.bundleIdentifier, path: url.path)] = label
            case "AXMinimizedWindowDockItem":
                minimised.append((item, values[3] as? String ?? ""))
            default:
                continue
            }
        }
        items = minimised.map { element, title in
            if let known = items.first(where: { $0.element == element }) { return (element, Minimised(id: known.item.id, title: title)) }
            lastID += 1
            return (element, Minimised(id: lastID, title: title))
        }
        leaving.formIntersection(items.map(\.item.id))
        publish(badges, items.map(\.item).filter { !leaving.contains($0.id) })
    }

    /// The Dock's list of items, observed for items created and destroyed — which is how a minimised window
    /// comes and goes. Found afresh after the Dock restarts, as dock2's own takeover restarts it.
    private func attach() -> AXUIElement? {
        guard let pid = SystemDock.processes(running: SystemDock.executable).first else {
            detach()
            return nil
        }
        if let dock, dock.pid == pid { return dock.list }
        detach()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var observer: AXObserver?
        guard let list = Self.children(app).first(where: { Self.value(of: $0, kAXRoleAttribute) as? String == kAXListRole }),
              AXObserverCreate(pid, { _, _, _, refcon in
                  guard let refcon else { return }
                  Unmanaged<SystemDockItems>.fromOpaque(refcon).takeUnretainedValue().read()
              }, &observer) == .success, let observer else { return nil }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXCreatedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(thread.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)
        exit.setEventHandler { [self] in thread.perform { [self] in read() } }
        exit.resume()
        dock = (pid, list, observer, exit)
        return list
    }

    private func detach() {
        guard let dock else { return }
        CFRunLoopRemoveSource(thread.runLoop, AXObserverGetRunLoopSource(dock.observer), .defaultMode)
        dock.exit.cancel()
        self.dock = nil
        items = []
    }

    /// No Dock to read — launchd is starting another, as after dock2's own takeover quits it — so it is
    /// looked for every half a second, for ten.
    private func searchForDock() {
        guard search == nil else { return }
        search = (thread.every(0.5) { [self] in
            search?.attempts += 1
            read()
            if let search, search.attempts >= 20 { endSearch() }
        }, 0)
    }

    private func endSearch() {
        guard let search else { return }
        CFRunLoopTimerInvalidate(search.timer)
        self.search = nil
    }

    private func publish(_ badges: [AppRef: String], _ minimised: [Minimised]) {
        let badgesChanged = badges != published.badges, minimisedChanged = minimised != published.minimised
        guard badgesChanged || minimisedChanged else { return }
        published = (badges, minimised)
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                if badgesChanged {
                    self.badges = badges
                    onBadgesChange?()
                }
                if minimisedChanged {
                    self.minimised = minimised
                    onMinimisedChange?()
                }
            }
        }
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(of: element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func value(of element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}
