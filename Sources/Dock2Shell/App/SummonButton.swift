import AppKit
import Dock2System

/// A tab on the screen's right edge that does what the summon shortcut does: a VM's window leaves ⌘space to the host.
/// A window of dock2's own, so a click on it is not a click elsewhere, and it never becomes key, so the field stays so.
@MainActor
final class SummonButton: NSPanel {
    /// Under `DOCK2_DEBUG=1` and in a VM alone, so that it stands in no capture of a real Mac.
    static var isWanted: Bool { LaunchEnvironment.isDebug && isVirtualMachine }

    private static var isVirtualMachine: Bool {
        var present: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0 && present == 1
    }

    private static let tabSize = CGSize(width: 30, height: 64)

    init(screen: NSScreen, action: @escaping () -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        contentView = Tab(frame: CGRect(origin: .zero, size: Self.tabSize), action: action)
        place(on: screen)
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func place(on screen: NSScreen) {
        let edge = screen.frame
        setFrame(CGRect(x: edge.maxX - Self.tabSize.width, y: edge.midY - Self.tabSize.height / 2,
                        width: Self.tabSize.width, height: Self.tabSize.height), display: true)
    }

    private final class Tab: NSView {
        private let action: () -> Void

        init(frame: CGRect, action: @escaping () -> Void) {
            self.action = action
            super.init(frame: frame)
            wantsLayer = true
            layer!.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            layer!.cornerRadius = 10
            layer!.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            let glyph = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Summon")!)
            glyph.contentTintColor = .white
            glyph.frame = bounds
            addSubview(glyph)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { action() }
    }
}
