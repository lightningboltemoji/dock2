import AppKit
import Dock2Core

/// What a view offers in its bar, at the field's trailing end ([views](product/plugins/views.md#the-bar)).
enum ViewActions {
    /// A form's submit: a click, or ⌘↩.
    case submit(String, run: () -> Void)
    /// The selection's actions, then the view's own, as ⌘K lists them; `perform` runs one on its item.
    case menu(ActionSet, perform: (ActionNode, String?) -> Void)
}

/// The bar's one control: "Actions ⌘K" at the field's trailing end, opening up into the actions' menu, or a form's submit.
@MainActor
final class ActionsBubble: BarMenu {
    private var offers: ViewActions?
    /// Each entry's action and the item it runs on, by its place among the entries.
    private var targets: [Int: (ActionNode, String?)] = [:]

    init() {
        super.init(edge: .bottom, chord: Chord("cmd+k")!)
        onChoose = { [weak self] index in
            guard let self, let (node, item) = self.targets[index], case .menu(_, let perform) = self.offers else { return }
            perform(node, item)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setOffers(_ offers: ViewActions?) {
        self.offers = offers
        switch offers {
        case .submit(let title, let run):
            onPillClick = run
            setEntries([])
            setPill(title: title, key: "⌘↩")
        case .menu(let set, _):
            onPillClick = nil
            setEntries(entries(for: set))
            setPill(title: set.isEmpty ? nil : "Actions", key: "⌘K")
        case nil:
            onPillClick = nil
            setEntries([])
            setPill(title: nil, key: "")
        }
    }

    /// The item's actions, then the view's: the first two primary — ↩ and ⌘↩ — unless they have chords of their own.
    private func entries(for set: ActionSet) -> [Entry] {
        var entries: [Entry] = []
        targets = [:]
        func add(_ actions: [ActionNode], item: String?, primary: Bool) {
            for (index, node) in actions.enumerated() {
                let chord = Chord(node.key) ?? (primary ? Chord(index == 0 ? "return" : index == 1 ? "cmd+return" : nil) : nil)
                targets[entries.count] = (node, item)
                entries.append(.item(Item(id: node.id, title: node.title, icon: node.icon, chord: chord, destructive: node.destructive == true)))
            }
        }
        add(set.items, item: set.item, primary: true)
        if !set.items.isEmpty, !set.view.isEmpty { entries.append(.separator) }
        add(set.view, item: nil, primary: set.items.isEmpty)
        return entries
    }
}
