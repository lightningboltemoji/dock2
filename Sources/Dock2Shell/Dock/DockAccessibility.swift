import AppKit
import Dock2Core

/// One tile as VoiceOver finds it: a dock item, as the system Dock's are — its name, whether its app runs,
/// and Press and Show Menu. A minimised window is the system Dock's kind of item for one.
@MainActor
final class DockItemElement: NSAccessibilityElement {
    nonisolated let slot: Int
    private let name: String
    let kind: TileKind
    private let running: Bool
    private nonisolated let press: @MainActor @Sendable (Int) -> Void
    private nonisolated let showMenu: @MainActor @Sendable (Int) -> Void

    init(slot: Int, kind: TileKind, name: String, running: Bool, frame: CGRect, parent: NSView,
         press: @escaping @MainActor @Sendable (Int) -> Void, showMenu: @escaping @MainActor @Sendable (Int) -> Void) {
        self.slot = slot
        self.kind = kind
        self.name = name
        self.running = running
        self.press = press
        self.showMenu = showMenu
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frame)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { NSAccessibility.Role(rawValue: "AXDockItem") }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        switch kind {
        case .plugin: NSAccessibility.Subrole(rawValue: "AXURLDockItem")
        case .window: NSAccessibility.Subrole(rawValue: "AXMinimizedWindowDockItem")
        default: NSAccessibility.Subrole(rawValue: "AXApplicationDockItem")
        }
    }

    override func accessibilityRoleDescription() -> String? { "dock item" }
    override func accessibilityLabel() -> String? { name }
    override func accessibilityValue() -> Any? { running ? "running" : nil }
    override func isAccessibilityElement() -> Bool { true }

    // Accessibility asks on the main thread, though the SDK leaves these nonisolated.
    override func accessibilityPerformPress() -> Bool {
        let (press, slot) = (press, slot)
        MainActor.assumeIsolated { press(slot) }
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        let (showMenu, slot) = (showMenu, slot)
        MainActor.assumeIsolated { showMenu(slot) }
        return true
    }
}
