import AppKit

/// The one window dock2 draws in, covering the screen; its transparent parts pass the mouse through
/// (IMPLEMENTATION.md §5), so nothing sets `ignoresMouseEvents`: set at all, even to false, every pixel takes
/// clicks. It becomes key only when asked: that is how dock2 takes the keyboard.
@MainActor
final class StageWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        // Not `.fullScreenAuxiliary`: like the Dock, it stays out of full screen apps' Spaces.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌘-chords, before the field or the menus see them; true when handled.
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    /// Every modifier change and key press while the stage is key, before anything else sees it: number
    /// badges watch ⌘ held alone, and a form's Esc is caught here. True swallows the event.
    var onKeyActivity: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged || event.type == .keyDown, onKeyActivity?(event) == true { return }
        super.sendEvent(event)
    }

    /// Covers `screen`.
    func place(on screen: NSScreen) {
        let frame = screen.frame
        guard frame != self.frame else { return }
        setFrame(frame, display: false)
        contentView?.frame = CGRect(origin: .zero, size: frame.size)
    }
}
