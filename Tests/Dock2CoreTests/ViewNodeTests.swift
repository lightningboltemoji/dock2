import Dock2Core
import Foundation
import Testing

@Suite struct ViewNodeTests {
    /// What a plugin writes: a list of vault items, tagged by type, optional fields left out.
    @Test func aListDecodesAsAPluginWritesIt() throws {
        let json = """
        {"type": "list", "id": "vault", "filtering": "dock2", "preview": true,
         "sections": [{"title": "Logins", "items": [
           {"id": "1", "title": "GitHub", "subtitle": "octocat", "icon": {"symbol": "key"},
            "keywords": ["git"], "actions": [{"id": "copy-password", "title": "Copy Password"}],
            "detail": {"id": "1d", "body": "**octocat**", "metadata": [{"label": "URL", "value": "github.com"}]}}]}]}
        """
        let node = try JSONDecoder().decode(ViewNode.self, from: Data(json.utf8))
        guard case .list(let list) = node else {
            Issue.record("not a list")
            return
        }
        #expect(list.id == "vault" && list.preview == true && list.filtering == .dock2)
        let item = try #require(list.sections.first?.items.first)
        #expect(item.icon == .symbol("key") && item.actions?.first?.id == "copy-password")
        #expect(item.detail?.metadata?.first?.value == "github.com")
        #expect(try JSONDecoder().decode(ViewNode.self, from: JSONEncoder().encode(node)) == node)
    }

    @Test func everyKindRoundTrips() throws {
        let nodes: [ViewNode] = [
            .detail(DetailNode(id: "d", body: "# Hi", image: .png(Data([1, 2, 3])))),
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
        #expect(list.filtered(by: Query("")).count == 2)
        var owned = list
        owned.filtering = .owner
        #expect(owned.filtered(by: Query("zzz")).count == 2)
    }

    /// ⌘ or ⌘⇧ with a letter dock2 does not use; anything else comes off the action, which stays.
    @Test func aPluginBindsOnlyTheChordsLeftToIt() {
        #expect(PluginChord.isAllowed("cmd+e") && PluginChord.isAllowed("cmd+shift+O") && PluginChord.isAllowed("cmd+shift+c"))
        for key in ["cmd+k", "cmd+w", "cmd+q", "cmd+c", "cmd+shift+z", "cmd+1", "cmd+,", "ctrl+e", "opt+return", "cmd+opt+e", "e", "cmd+é"] {
            #expect(!PluginChord.isAllowed(key), "\(key)")
        }
        let item = ListNode.Item(id: "1", title: "One", actions: [ActionNode(id: "a", title: "A", key: "cmd+w"), ActionNode(id: "b", title: "B", key: "cmd+e")])
        let (node, refused) = ViewNode.list(ListNode(id: "l", sections: [.init(items: [item])])).withoutReservedChords()
        guard case .list(let list) = node else { return }
        #expect(refused == ["cmd+w"])
        #expect(list.sections[0].items[0].actions?.map(\.key) == [nil, "cmd+e"])
    }
}
