import AppKit

/// Where the pointer is, from a global mouse monitor (other apps' events) and a local one (dock2's own) —
/// neither needs a permission. Moves and drags only: no clicks, no keys. While a menu is up it hands the menu what it
/// hears, since a menu tracks the pointer from the moves sent to its app, and dock2, never active, is sent only some.
@MainActor
final class PointerMonitor {
    private var monitors: [Any] = []
    private var handlers: [(CGPoint, Int) -> Void] = []
    private var observers: [NSObjectProtocol] = []
    private var menuTracking = false
    /// Marks a move this posted, which has told everyone already.
    private static let forwarded = -2

    init() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let window = Self.window(under: event)
            MainActor.assumeIsolated {
                self?.moved(over: window)
                self?.forwardToMenu()
            }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard event.type != .mouseMoved || event.eventNumber != Self.forwarded else { return event }
            let window = Self.window(under: event)
            MainActor.assumeIsolated { self?.moved(over: window) }
            return event
        } as Any)
        for (name, tracking) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTracking = tracking }
            })
        }
    }

    private func forwardToMenu() {
        guard menuTracking, let move = NSEvent.mouseEvent(with: .mouseMoved, location: NSEvent.mouseLocation, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                                          eventNumber: Self.forwarded, clickCount: 0, pressure: 0) else { return }
        NSApp.postEvent(move, atStart: false)
    }

    /// `handler` hears the pointer at every move: its location, in screen coordinates, and the number of the
    /// window under it — the window server's pick, which passes over transparent pixels as a click does.
    func onMove(_ handler: @escaping (CGPoint, Int) -> Void) {
        handlers.append(handler)
    }

    private nonisolated static func window(under event: NSEvent) -> Int {
        Int(event.cgEvent?.getIntegerValueField(.mouseEventWindowUnderMousePointer) ?? 0)
    }

    private func moved(over window: Int) {
        let location = NSEvent.mouseLocation
        for handler in handlers { handler(location, window) }
    }

    isolated deinit {
        monitors.forEach(NSEvent.removeMonitor)
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
