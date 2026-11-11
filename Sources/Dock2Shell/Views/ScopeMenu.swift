import AppKit
import Dock2Core

/// What a screen's scope offers the bar along the panel's top: its options and the one chosen, and what choosing one
/// does.
struct ScopeOffer {
    var node: ScopeNode
    var choose: (String) -> Void
}

/// A view's scope ([views](product/plugins/views.md#scope)): the option chosen at the trailing end of the bar along the
/// panel's top — "Local ⌘P" — opening down into every option, by section, a check on the one chosen.
@MainActor
final class ScopeMenu: BarMenu {
    private var offer: ScopeOffer?
    /// Each entry's option, by its place among the entries.
    private var options: [Int: String] = [:]

    init() {
        super.init(edge: .top, chord: Chord("cmd+p")!)
        onChoose = { [weak self] index in
            guard let self, let id = self.options[index], let offer = self.offer, id != offer.node.chosen?.id else { return }
            offer.choose(id)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setOffer(_ offer: ScopeOffer?) {
        self.offer = offer
        guard let offer, let chosen = offer.node.chosen else {
            setEntries([])
            setPill(title: nil, key: "")
            return
        }
        var entries: [Entry] = []
        options = [:]
        for section in offer.node.sections where !section.options.isEmpty {
            if !entries.isEmpty { entries.append(.separator) }
            if let title = section.title { entries.append(.heading(title)) }
            for option in section.options {
                options[entries.count] = option.id
                entries.append(.item(Item(id: option.id, title: option.title, icon: option.icon, checked: option.id == chosen.id)))
            }
        }
        setEntries(entries)
        setPill(title: chosen.title, key: chord.glyphs, icon: chosen.icon, role: .popUpButton)
    }
}
