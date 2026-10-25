import AppKit
import Dock2Core

/// What the panel shows over the search: a view built from a `ViewNode`, or Files.
@MainActor
protocol Screen: AnyObject {
    var view: NSView { get }
    /// The panel's width and the height above the field; nil is search's width at the views' maximum.
    var size: CGSize? { get }
    /// Drawn in the field's place — Files' path bar. Without one the field stays, as the filter.
    var bar: NSView? { get }
    /// "Search *title*" in the field; ignored with a bar.
    var title: String? { get }
    /// The field filters this screen; otherwise it dims and the screen's own controls take the keys.
    var usesField: Bool { get }
    /// The dock's tile it belongs to, which wears the caret while it shows: Files' is Finder's.
    var tile: TileKind? { get }
    var isLoading: Bool { get }
    /// Set by the stack: call it when the title or loading changes.
    var onChange: (() -> Void)? { get set }
    func filter(_ text: String)
    /// ↑ ↓ ↩ from the field; true if handled.
    func command(_ selector: Selector) -> Bool
    /// ⌘-chords; true if handled.
    func keyEquivalent(_ event: NSEvent) -> Bool
    /// Esc, for something of the screen's own to close first — a typed path, Quick Look; true if it did.
    func cancel() -> Bool
    /// On top, again or for the first time: where the keys go.
    func focus()
    func closed()
}

extension Screen {
    var size: CGSize? { nil }
    var bar: NSView? { nil }
    var tile: TileKind? { nil }
    func cancel() -> Bool { false }
    func focus() {}
    func closed() {}
}

/// A `ViewNode` from its host, drawn by the component for its kind.
@MainActor
final class NodeScreen: Screen {
    let host: ViewHost
    private let component: Component
    var onChange: (() -> Void)?

    init(host: ViewHost, context: ViewContext) {
        self.host = host
        switch host.node {
        case .list: component = ListComponent(host: host, context: context)
        case .detail: component = DetailComponent(host: host, context: context)
        case .form: component = FormComponent(host: host, context: context)
        case .grid: component = GridComponent(host: host, context: context)
        }
        host.onUpdate = { [weak self] in
            guard let self else { return }
            self.component.show(self.host.node)
            self.onChange?()
        }
    }

    var view: NSView { component }
    var usesField: Bool { component.usesField }

    var title: String? {
        switch host.node {
        case .list(let list): list.title
        case .grid(let grid): grid.title
        case .form(let form): form.title
        case .detail: nil
        }
    }

    var isLoading: Bool {
        if case .list(let list) = host.node { list.loading == true } else { false }
    }

    func filter(_ text: String) { component.filter(text) }
    func command(_ selector: Selector) -> Bool { component.command(selector) }
    func keyEquivalent(_ event: NSEvent) -> Bool { component.keyEquivalent(event) }

    func focus() {
        component.show(host.node)
        if !component.usesField { component.window?.makeFirstResponder(component) }
    }

    func closed() { host.closed() }
}

/// The panel's stack of screens ([views](product/plugins/views.md#navigation)), each over the search it came
/// from; Esc pops, and the last pop goes back where the first came from: the search with its query, or —
/// for a screen opened from nothing, as Files from the Finder tile — dismissed.
@MainActor
final class ViewsController {
    private struct Entry {
        let screen: Screen
        /// The field's text below it; nil when it was opened from nothing.
        let query: String?
    }

    private let panel: PanelController
    private var stack: [Entry] = []
    /// dock2 should let go: an action that opens something.
    var onDismiss: (() -> Void)?
    /// The field's text to put back when the last screen pops.
    var onPopToSearch: ((String) -> Void)?
    /// The screen on top changed: the one now showing, or nil for none.
    var onTop: ((Screen?) -> Void)?

    init(panel: PanelController) {
        self.panel = panel
    }

    var isActive: Bool { !stack.isEmpty }
    var top: Screen? { stack.last?.screen }

    var context: ViewContext {
        ViewContext(dismiss: { [weak self] in self?.onDismiss?() },
                    push: { [weak self] host in self?.push(host) },
                    pop: { [weak self] in self?.pop() },
                    toast: { [weak panel] text in panel?.toast(text) },
                    notice: { [weak panel] text in panel?.notice(text) },
                    confirm: { [weak panel] title, run in panel?.confirm(.init(question: "\(title)?", action: title), run) },
                    undoManager: panel.field.window?.undoManager)
    }

    func push(_ host: ViewHost) {
        push(NodeScreen(host: host, context: context))
    }

    /// `fromSearch` false: popping it dismisses rather than going back to the search.
    func push(_ screen: Screen, fromSearch: Bool = true) {
        stack.append(Entry(screen: screen, query: fromSearch ? panel.field.string : nil))
        screen.onChange = { [weak self, weak screen] in
            guard let self, let screen, self.top === screen else { return }
            self.dress(screen)
        }
        show(screen)
    }

    /// Back one level; false when there was nothing to pop.
    @discardableResult
    func pop() -> Bool {
        guard let entry = stack.popLast() else { return false }
        entry.screen.closed()
        if let below = stack.last?.screen {
            show(below)
        } else if let query = entry.query {
            panel.showScreen(nil)
            onTop?(nil)
            panel.field.setBusy(false)
            panel.field.setFilterMode(true, placeholder: nil)
            onPopToSearch?(query)
        } else {
            onDismiss?()
        }
        return true
    }

    /// Everything closed, as dock2 lets go.
    func closeAll() {
        while let entry = stack.popLast() { entry.screen.closed() }
        panel.showScreen(nil)
        onTop?(nil)
        panel.field.setBusy(false)
        panel.field.setFilterMode(true, placeholder: nil)
    }

    private func show(_ screen: Screen) {
        panel.showScreen(screen)
        onTop?(screen)
        dress(screen)
        if screen.bar == nil {
            panel.field.string = ""
            if screen.usesField { panel.focus() }
        }
        screen.focus()
    }

    private func dress(_ screen: Screen) {
        panel.field.setBusy(screen.isLoading)
        if screen.bar == nil { panel.field.setFilterMode(screen.usesField, placeholder: screen.title) }
    }

    func filter(_ text: String) { top?.filter(text) }
    func command(_ selector: Selector) -> Bool { top?.command(selector) ?? false }
    func keyEquivalent(_ event: NSEvent) -> Bool { top?.keyEquivalent(event) ?? false }
    func cancel() -> Bool { top?.cancel() ?? false }
}
