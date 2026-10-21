import AppKit

/// A control in the panel lit while the pointer is over it. dock2 is never the active app, so a tracking
/// area hears only some of the pointer's moves; the panel lights its controls from the monitors, which hear
/// every one (`PanelController.pointerMoved`).
@MainActor
protocol Hoverable: NSView {
    var isHovered: Bool { get set }
}
