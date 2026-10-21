import AppKit

/// Where the pointer is, from a global mouse monitor (other apps' events) and a local one (dock2's own) —
/// neither needs a permission. Moves and drags only: no clicks, no keys.
@MainActor
final class PointerMonitor {
    private var monitors: [Any] = []
    private var handlers: [(CGPoint) -> Void] = []

    init() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.moved() }
            return event
        } as Any)
    }

    /// `handler` hears the pointer's location, in screen coordinates, at every move.
    func onMove(_ handler: @escaping (CGPoint) -> Void) {
        handlers.append(handler)
    }

    private func moved() {
        let location = NSEvent.mouseLocation
        for handler in handlers { handler(location) }
    }

    isolated deinit {
        monitors.forEach(NSEvent.removeMonitor)
    }
}
