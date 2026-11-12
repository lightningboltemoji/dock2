import Dock2Core
import Foundation
import Testing

@Suite struct ViewNodeTests {
    @Test func aTagIsOneLine() {
        #expect(Dock2Core.Tag(text: "Two\nlines").line == "Two lines")
        #expect(Dock2Core.Tag(text: " \n ").line.isEmpty)
    }

    /// What a plugin writes: a list of vault items, tagged by type, optional fields left out.
    @Test func aListDecodesAsAPluginWritesIt() throws {
        let json = """
        {"type": "list", "id": "vault", "filtering": "dock2", "preview": true,
         "sections": [{"title": "Logins", "items": [
           {"id": "1", "title": "GitHub", "subtitle": "octocat", "icon": {"symbol": "key"},
            "keywords": ["git"], "actions": [{"id": "copy-password", "title": "Copy Password"}],
            "detail": {"id": "1d", "body": "**octocat**", "metadata": [{"label": "URL", "value": "github.com"},
                                                                     {"label": "Password", "value": "", "masked": true}],
                       "status": ["Edited", "2 days ago"]}}]}]}
        """
        let node = try JSONDecoder().decode(ViewNode.self, from: Data(json.utf8))
        guard case .list(let list) = node else {
            Issue.record("not a list")
            return
        }
        #expect(list.id == "vault" && list.preview == true && list.filtering == .dock2)
        let item = try #require(list.sections.first?.items.first)
        #expect(item.icon == .symbol("key") && item.actions?.first?.id == "copy-password")
        #expect(item.detail?.metadata?.first?.value == "github.com" && item.detail?.status == ["Edited", "2 days ago"])
        #expect(item.detail?.metadata?.first?.masked == nil && item.detail?.metadata?.last?.masked == true)
        #expect(try JSONDecoder().decode(ViewNode.self, from: JSONEncoder().encode(node)) == node)
    }

    @Test func everyKindRoundTrips() throws {
        let nodes: [ViewNode] = [
            .detail(DetailNode(id: "d", body: "# Hi", image: .png(Data([1, 2, 3])), status: ["Safari", "5 min ago"])),
            .form(FormNode(id: "f", fields: [FormNode.Field(id: "server", title: "Server", kind: .choice,
                                                             options: [.init(value: "us", title: "bitwarden.com")]),
                                             FormNode.Field(id: "password", title: "Master password", kind: .secure)], submit: "Sign In")),
            .grid(GridNode(id: "g", items: [GridNode.Item(id: "a", image: .app("com.apple.Safari"))], columns: 4)),
        ]
        for node in nodes {
            #expect(try JSONDecoder().decode(ViewNode.self, from: JSONEncoder().encode(node)) == node)
        }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ViewNode.self, from: Data(#"{"type": "canvas", "id": "x"}"#.utf8)) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Icon.self, from: Data(#"{"svg": "x"}"#.utf8)) }
    }

    /// A symbol's tint rides beside it, one key apart; violet is dock2's and no plugin's.
    @Test func anIconsTintRidesBesideItsSymbol() throws {
        let tinted = try JSONDecoder().decode(Icon.self, from: Data(#"{"symbol": "forward", "tint": "pink"}"#.utf8))
        #expect(tinted == .symbol("forward", tint: .pink))
        #expect(try JSONDecoder().decode(Icon.self, from: JSONEncoder().encode(tinted)) == tinted)
        #expect(String(decoding: try JSONEncoder().encode(Icon.symbol("key")), as: UTF8.self) == #"{"symbol":"key"}"#)
        #expect(try JSONDecoder().decode(Icon.self, from: Data(#"{"image": "icon.png"}"#.utf8)) == .image("icon.png"))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Icon.self, from: Data(#"{"symbol": "x", "tint": "violet"}"#.utf8)) }
    }

    @Test func dock2FiltersByTitleAndKeywordsBestFirstKeepingSections() {
        let list = ListNode(id: "l", sections: [
            .init(title: "A", items: [.init(id: "1", title: "Notes"), .init(id: "2", title: "Network", keywords: ["wifi"]),
                                      .init(id: "3", title: "Calendar")]),
            .init(title: "B", items: [.init(id: "4", title: "Calculator")]),
        ])
        // Calendar by subsequence, after the prefixes; nothing of B.
        #expect(list.filtered(by: Query("n")).map { $0.items.map(\.id) } == [["1", "2", "3"]])
        #expect(list.filtered(by: Query("wifi")).first?.items.map(\.id) == ["2"])
        #expect(list.filtered(by: Query("cal")).map(\.title) == ["A", "B"])
        #expect(list.filtered(by: Query("wifi net")).first?.items.map(\.id) == ["2"])
        #expect(list.filtered(by: Query("")).count == 2)
        var owned = list
        owned.filtering = .owner
        #expect(owned.filtered(by: Query("zzz")).count == 2)
    }

    /// ⌘ or ⌘⇧ with a letter dock2 does not use; anything else comes off the action, which stays.
    @Test func aPluginBindsOnlyTheChordsLeftToIt() {
        #expect(PluginChord.isAllowed("cmd+e") && PluginChord.isAllowed("cmd+shift+O") && PluginChord.isAllowed("cmd+shift+c"))
        for key in ["cmd+k", "cmd+p", "cmd+w", "cmd+q", "cmd+c", "cmd+shift+z", "cmd+1", "cmd+,", "ctrl+e", "opt+return", "cmd+delete", "cmd+opt+e", "e", "cmd+é"] {
            #expect(!PluginChord.isAllowed(key), "\(key)")
        }
        let item = ListNode.Item(id: "1", title: "One", actions: [ActionNode(id: "a", title: "A", key: "cmd+w"), ActionNode(id: "b", title: "B", key: "cmd+e")])
        let (node, refused) = ViewNode.list(ListNode(id: "l", sections: [.init(items: [item])])).withoutReservedChords()
        guard case .list(let list) = node else { return }
        #expect(refused == ["cmd+w"])
        #expect(list.sections[0].items[0].actions?.map(\.key) == [nil, "cmd+e"])
    }

    /// A scope as a plugin writes it: the choice by id, its options in sections, the untitled first; a list's and a
    /// grid's, and nothing else's.
    @Test func aScopeDecodesAsAPluginWritesIt() throws {
        let json = """
        {"type": "list", "id": "shares", "sections": [],
         "scope": {"value": "nas", "sections": [
           {"options": [{"id": "all", "title": "All"}, {"id": "mac", "title": "This Mac", "icon": {"symbol": "laptopcomputer"}}]},
           {"title": "Servers", "options": [{"id": "nas", "title": "nas.local"}]}]}}
        """
        let node = try JSONDecoder().decode(ViewNode.self, from: Data(json.utf8))
        let scope = try #require(node.scope)
        #expect(scope.chosen?.title == "nas.local" && scope.options.map(\.id) == ["all", "mac", "nas"])
        #expect(scope.sections.map(\.title) == [nil, "Servers"] && scope.options[1].icon == .symbol("laptopcomputer"))
        #expect(try JSONDecoder().decode(ViewNode.self, from: JSONEncoder().encode(node)) == node)
        let grid = ViewNode.grid(GridNode(id: "g", items: [], scope: scope))
        #expect(try JSONDecoder().decode(ViewNode.self, from: JSONEncoder().encode(grid)).scope == scope)
        #expect(ViewNode.detail(DetailNode(id: "d")).scope == nil)
    }

    /// The item a list or a grid starts on, by id, as a plugin writes it; a node that names none says nothing of it.
    @Test func aSelectionDecodesAsAPluginWritesIt() throws {
        let list = try JSONDecoder().decode(ViewNode.self, from: Data(#"{"type": "list", "id": "l", "sections": [], "selected": "d142"}"#.utf8))
        guard case .list(let node) = list else { Issue.record("not a list"); return }
        #expect(node.selected == "d142")
        let grid = ViewNode.grid(GridNode(id: "g", items: [], selected: "130"))
        #expect(try JSONDecoder().decode(ViewNode.self, from: JSONEncoder().encode(grid)) == grid)
        let none = String(decoding: try JSONEncoder().encode(ViewNode.list(ListNode(id: "l", sections: []))), as: UTF8.self)
        #expect(!none.contains("selected"))
    }

    /// src/{app/{main, view}, lib}, docs/{guide}, a README beside them: a tree two levels deep.
    private var tree: ListNode {
        typealias Item = ListNode.Item
        let src = Item(id: "src", title: "src", children: [
            Item(id: "app", title: "app", children: [Item(id: "main", title: "main.rs"), Item(id: "view", title: "view.rs")]),
            Item(id: "lib", title: "lib.rs"),
        ])
        let docs = Item(id: "docs", title: "docs", children: [Item(id: "guide", title: "guide.md", keywords: ["manual"])])
        return ListNode(id: "files", sections: [.init(items: [src, docs, Item(id: "readme", title: "README.md")])])
    }

    private func shown(_ sections: [ListNode.RowSection]) -> [String] {
        sections.flatMap(\.rows).map { String(repeating: "  ", count: $0.depth) + $0.item.id + ($0.open.map { $0 ? " v" : " >" } ?? "") }
    }

    /// A tree shows the items under the open ones, each at its depth, a closed one's children hidden however deep.
    @Test func aTreeShowsWhatIsUnderTheOpenItems() {
        #expect(tree.isTree && !ListNode(id: "l", sections: [.init(items: [.init(id: "a", title: "A", children: [])])]).isTree)
        #expect(shown(tree.rows(for: Query(""), open: [])) == ["src >", "docs >", "readme"])
        #expect(shown(tree.rows(for: Query(""), open: ["src", "app"])) == ["src v", "  app v", "    main", "    view", "  lib", "docs >", "readme"])
        #expect(shown(tree.rows(for: Query(""), open: ["app"])) == ["src >", "docs >", "readme"])
        #expect(tree.rows(for: Query(""), open: ["src"]).flatMap(\.rows).first { $0.item.id == "lib" }?.parent == "src")
        let parents = Dictionary(uniqueKeysWithValues: tree.everyItem.map { ($0.item.id, $0.parent) })
        #expect(parents.count == 8 && parents["main"] == "app" && parents["src"] == .some(nil))
    }

    /// Typing shows every match, closed or not, under the items it stands in, open, in the tree's order; a match with
    /// nothing matching under it does not open. The query selects the best match, not the first row.
    @Test func aQueryShowsEachMatchUnderItsAncestors() {
        let rows = tree.rows(for: Query("rs"), open: [])
        #expect(shown(rows) == ["src v", "  app v", "    main", "    view", "  lib"])
        #expect(rows[0].rows[0].match == nil && rows[0].rows[2].match != nil)
        #expect(shown(tree.rows(for: Query("manual"), open: [])) == ["docs v", "  guide"])
        #expect(shown(tree.rows(for: Query("src"), open: [])) == ["src"])
        #expect(ListNode.best(tree.rows(for: Query("lib"), open: []))?.item.id == "lib")
        #expect(ListNode.best(tree.rows(for: Query(""), open: []))?.item.id == "src")
        var owned = tree
        owned.filtering = .owner
        #expect(shown(owned.rows(for: Query("anything"), open: [])).count == 8)
    }

    /// A tree travels as a plugin writes it, and a chord a plugin may not bind comes off an item however deep.
    @Test func aTreeDecodesAndLosesItsReservedChordsAtEveryDepth() throws {
        let json = #"{"type": "list", "id": "t", "sections": [{"items": [{"id": "a", "title": "A", "expanded": true, "children": [{"id": "b", "title": "B", "actions": [{"id": "x", "title": "X", "key": "cmd+w"}]}]}]}]}"#
        let node = try JSONDecoder().decode(ViewNode.self, from: Data(json.utf8))
        guard case .list(let list) = node else { Issue.record("not a list"); return }
        #expect(list.sections[0].items[0].expanded == true && list.sections[0].items[0].children?.first?.id == "b")
        #expect(try JSONDecoder().decode(ViewNode.self, from: JSONEncoder().encode(node)) == node)
        let (clean, refused) = node.withoutReservedChords()
        guard case .list(let cleaned) = clean else { return }
        #expect(refused == ["cmd+w"] && cleaned.sections[0].items[0].children?[0].actions?[0].key == nil)
    }

    /// A scope always shows one option: the one its value names, else its first; with none, there is nothing to show.
    @Test func aScopeShowsTheOptionItsValueNamesElseItsFirst() {
        var scope = ScopeNode(value: "gone", sections: [.init(options: []), .init(title: "Servers", options: [.init(id: "a", title: "A"), .init(id: "b", title: "B")])])
        #expect(scope.chosen?.id == "a")
        scope.value = "b"
        #expect(scope.chosen?.id == "b")
        #expect(ScopeNode(value: "a", sections: [.init(options: [])]).chosen == nil)
    }
}
