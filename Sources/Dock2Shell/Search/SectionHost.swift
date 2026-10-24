import AppKit
import Dock2Core

/// "Show all…": a section's results as a list view, filtered by the field, their actions the results' own
/// and run as search runs them.
@MainActor
final class SectionHost: ViewHost {
    let node: ViewNode
    var onUpdate: (() -> Void)?
    private let results: [String: SearchResult]
    private let actions: ResultActions
    private let run: (ResultAction, SearchResult) -> Void
    private var icons: [String: NSImage] = [:]

    init(section: SectionID, results: [SearchResult], actions: ResultActions, run: @escaping (ResultAction, SearchResult) -> Void) {
        self.actions = actions
        self.run = run
        self.results = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = results.map { result in
            ListNode.Item(id: result.id, icon: Self.icon(result.payload), title: result.title, subtitle: result.subtitle,
                          accessories: result.accessory.map { [.init(text: $0)] },
                          actions: Self.nodes(actions.actions(for: result)))
        }
        node = .list(ListNode(id: "section", title: section.title, sections: [.init(items: items)], filtering: .dock2))
    }

    /// A result's actions as a view's, with search's chords: an ⌥ alternate stands as an action of its own,
    /// and a submenu — Open With… — opens a list of its choices.
    static func nodes(_ actions: [ResultAction]) -> [ActionNode] {
        actions.enumerated().map { index, action in
            ActionNode(id: String(index), title: action.title, key: action.chord ?? (action.onOptionReturn ? "opt+return" : nil),
                       destructive: action.isDestructive ? true : nil)
        }
    }

    func perform(action: String, item: String?, in context: ViewContext) {
        guard let item, let result = results[item], let index = Int(action) else { return }
        let list = actions.actions(for: result)
        guard list.indices.contains(index) else { return }
        if let children = list[index].children {
            context.push(ChoicesHost(title: list[index].title, choices: children()) { [run] choice in run(choice, result) })
        } else {
            run(list[index], result)
        }
    }

    func icon(for item: String) -> NSImage? {
        if let icon = icons[item] { return icon }
        let icon = results[item].flatMap(actions.icon(for:))
        icons[item] = icon
        return icon
    }

    /// What a row stands for before search's icon is drawn in its place.
    private static func icon(_ payload: ResultPayload) -> Icon? {
        switch payload {
        case .app(let app): app.bundleIdentifier.map(Icon.app) ?? .file(app.path)
        case .file(let path): .file(path)
        case .command: .symbol("command")
        case .clip: .symbol("doc.on.clipboard")
        case .plugin: .symbol("puzzlepiece.extension")
        }
    }
}

/// A submenu's choices as a list of their own: Open With…'s apps.
@MainActor
private final class ChoicesHost: ViewHost {
    let node: ViewNode
    var onUpdate: (() -> Void)?
    private let choices: [ResultAction]
    private let run: (ResultAction) -> Void

    init(title: String, choices: [ResultAction], run: @escaping (ResultAction) -> Void) {
        self.choices = choices
        self.run = run
        let items = choices.enumerated().map { index, choice in
            ListNode.Item(id: String(index), title: choice.title, actions: [ActionNode(id: "run", title: "Open")])
        }
        node = .list(ListNode(id: "choices", title: title.replacingOccurrences(of: "…", with: ""), sections: [.init(items: items)],
                              filtering: .dock2))
    }

    func perform(action: String, item: String?, in context: ViewContext) {
        guard let item, let index = Int(item), choices.indices.contains(index) else { return }
        run(choices[index])
    }
}
