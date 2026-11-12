import Foundation

/// A list as it shows: a flat list's items, or a tree's under the items that are open
/// ([views](../../.agents/product/plugins/views.md#tree)).
extension ListNode {
    /// An item where it stands in what shows.
    public struct Row: Equatable, Sendable {
        public var item: Item
        public var depth: Int
        public var parent: String?
        /// Nil for an item with nothing under it to show; else whether what is under it shows.
        public var open: Bool?
        /// How the query matched it; nil with no query, and for an item shown only for a match under it.
        public var match: MatchKind?
    }

    public struct RowSection: Equatable, Sendable {
        public var title: String?
        public var rows: [Row]
    }

    /// Any item has items under it, in rows.
    public var isTree: Bool {
        layout != .flow && sections.contains { $0.items.contains(where: \.opens) }
    }

    /// Items under items in a flow, which shows none of them: the plugin's log says so.
    public var flowHidesChildren: Bool {
        layout == .flow && sections.contains { $0.items.contains(where: \.opens) }
    }

    /// Every item, the whole tree open or not, depth first, with its parent's id.
    public var everyItem: [(item: Item, parent: String?)] {
        var every: [(item: Item, parent: String?)] = []
        func walk(_ items: [Item], under parent: String?) {
            for item in items {
                every.append((item, parent))
                walk(item.children ?? [], under: item.id)
            }
        }
        for section in sections { walk(section.items, under: nil) }
        return every
    }

    /// What shows. A flat list is `filtered`. A tree shows the items under those `open`; with a query, every match
    /// and the items it stands under, open, in the tree's order, since an item's place is where it stands. An owner
    /// that filters answers with what to show, all of it open.
    public func rows(for query: Query, open: Set<String>) -> [RowSection] {
        let filters = !query.isEmpty && filtering != .owner
        guard isTree else {
            return filtered(by: query).map { section in
                RowSection(title: section.title, rows: section.items.map { item in
                    Row(item: item, depth: 0, parent: nil, open: nil, match: filters ? matchKind(item, query) : nil)
                })
            }
        }
        let opensAll = !query.isEmpty && filtering == .owner
        func walk(_ items: [Item], depth: Int, parent: String?) -> [Row] {
            var rows: [Row] = []
            for item in items {
                let children = item.children ?? []
                if filters {
                    let below = walk(children, depth: depth + 1, parent: item.id)
                    let match = matchKind(item, query)
                    guard match != nil || !below.isEmpty else { continue }
                    rows.append(Row(item: item, depth: depth, parent: parent, open: below.isEmpty ? nil : true, match: match))
                    rows += below
                } else {
                    let isOpen = item.opens ? opensAll || open.contains(item.id) : nil
                    rows.append(Row(item: item, depth: depth, parent: parent, open: isOpen, match: nil))
                    if isOpen == true { rows += walk(children, depth: depth + 1, parent: item.id) }
                }
            }
            return rows
        }
        return sections.compactMap { section in
            let rows = walk(section.items, depth: 0, parent: nil)
            return rows.isEmpty ? nil : RowSection(title: section.title, rows: rows)
        }
    }

    /// The row a query selects: the first of its best matches, else the first.
    public static func best(_ sections: [RowSection]) -> Row? {
        let rows = sections.flatMap(\.rows)
        guard let kind = rows.compactMap(\.match).min() else { return rows.first }
        return rows.first { $0.match == kind }
    }

    /// How `query` matches an item's title and keywords, at best.
    func matchKind(_ item: Item, _ query: Query) -> MatchKind? {
        Matcher.match(query, item.title, keywords: item.keywords ?? [], subsequence: true)?.kind
    }
}
