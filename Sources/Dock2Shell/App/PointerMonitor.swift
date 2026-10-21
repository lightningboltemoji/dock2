import AppKit

/// Where the pointer is, from a global mouse monitor (other apps' events) and a local one (dock2's own) —
/// neither needs a permission. Moves and drags only: no clicks, no keys.
@MainActor
final class PointerMonitor {
    private var monitors: [Any] = []
    private var handlers: [(CGPoint, Int) -> Void] = []

    init() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let window = Self.window(under: event)
            MainActor.assumeIsolated { self?.moved(over: window) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let window = Self.window(under: event)
            MainActor.assumeIsolated { self?.moved(over: window) }
            return event
        } as Any)
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
    }
}
