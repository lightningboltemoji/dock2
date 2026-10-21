import AppKit
import Dock2Core

/// An `NSMenu` built from closures: dock2's menus are lists of actions, not responder-chain selectors.
@MainActor
final class MenuBuilder: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private var handlers: [Int: () -> Void] = [:]
    /// Told when the menu opens and closes: auto-hide holds the dock while a menu is up.
    var onOpen: ((Bool) -> Void)?

    override init() {
        super.init()
        menu.autoenablesItems = false
        // The system's own items — Ask Siri — at the top of a list of dock2's actions.
        menu.allowsContextMenuPlugIns = false
        menu.delegate = self
    }

    @discardableResult
    func item(_ title: String, state: NSControl.StateValue = .off, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.state = state
        item.isEnabled = enabled
        item.tag = handlers.count
        handlers[item.tag] = handler
        menu.addItem(item)
        return item
    }

    /// An action: its icon, its chord shown as a menu shows one, in red when it is destructive.
    @discardableResult
    func action(_ title: String, icon: NSImage? = nil, chord: Chord? = nil, destructive: Bool = false,
                _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = self.item(title, handler)
        item.image = icon
        if let chord {
            item.keyEquivalent = chord.menuKey
            item.keyEquivalentModifierMask = chord.modifiers
        }
        if destructive { item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed]) }
        return item
    }

    /// A view's actions ([views](product/plugins/views.md)): the first is ↩ and the second ⌘↩ when they are
    /// the primary ones, unless they have chords of their own.
    func actions(_ actions: [ActionNode], primary: Bool = true, _ run: @escaping (ActionNode) -> Void) {
        for (index, node) in actions.enumerated() {
            let chord = Chord(node.key) ?? (primary ? Chord(index == 0 ? "return" : index == 1 ? "cmd+return" : nil) : nil)
            action(node.title, icon: IconImages.image(node.icon, size: 16), chord: chord, destructive: node.destructive == true) { run(node) }
        }
    }

    /// An item shown in place of the one before it while ⌥ is held: AppKit pairs them by their key, the
    /// alternate's with ⌥ added.
    func alternate(_ title: String, _ handler: @escaping () -> Void) {
        let previous = menu.items.last
        let item = self.item(title, handler)
        item.keyEquivalent = previous?.keyEquivalent ?? ""
        item.keyEquivalentModifierMask = (previous?.keyEquivalentModifierMask ?? []).union(.option)
        item.isAlternate = true
    }

    /// A submenu whose items `fill` adds when it opens.
    func submenu(_ title: String, _ fill: @escaping (MenuBuilder) -> Void) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let child = MenuBuilder()
        child.fill = fill
        children.append(child)
        item.submenu = child.menu
        menu.addItem(item)
    }

    private var children: [MenuBuilder] = []
    private var fill: ((MenuBuilder) -> Void)?

    func separator() {
        menu.addItem(.separator())
    }

    @objc private func run(_ sender: NSMenuItem) {
        handlers[sender.tag]?()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let fill {
            self.fill = nil
            fill(self)
        }
        onOpen?(true)
    }
    func menuDidClose(_ menu: NSMenu) { onOpen?(false) }
}
