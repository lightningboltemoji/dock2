import Foundation

/// A screen in the panel, described rather than drawn ([views](../../.agents/product/plugins/views.md)): what
/// dock2's own views and every plugin's are made of. It travels as JSON, each node tagged by `type`.
public indirect enum ViewNode: Codable, Equatable, Sendable {
    case list(ListNode)
    case detail(DetailNode)
    case form(FormNode)
    case grid(GridNode)

    public var id: String {
        switch self {
        case .list(let node): node.id
        case .detail(let node): node.id
        case .form(let node): node.id
        case .grid(let node): node.id
        }
    }

    private enum Kind: String, Codable { case list, detail, form, grid }
    private enum Key: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        switch try decoder.container(keyedBy: Key.self).decode(Kind.self, forKey: .type) {
        case .list: self = .list(try ListNode(from: decoder))
        case .detail: self = .detail(try DetailNode(from: decoder))
        case .form: self = .form(try FormNode(from: decoder))
        case .grid: self = .grid(try GridNode(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .list(let node): try container.encode(Kind.list, forKey: .type); try node.encode(to: encoder)
        case .detail(let node): try container.encode(Kind.detail, forKey: .type); try node.encode(to: encoder)
        case .form(let node): try container.encode(Kind.form, forKey: .type); try node.encode(to: encoder)
        case .grid(let node): try container.encode(Kind.grid, forKey: .type); try node.encode(to: encoder)
        }
    }
}

/// An image: an SF Symbol, PNG bytes, a file's icon, or an app's. As JSON, one key naming which:
/// `{"symbol": "gearshape"}`, `{"png": "<base64>"}`, `{"file": "/path"}`, `{"app": "com.apple.Safari"}`.
/// The only colours a node can name ([views](product/plugins/views.md#what-a-plugin-cannot-do)): the system's
/// own, drawn as dock2 draws them in either appearance.
public enum Tint: String, Codable, Sendable, CaseIterable {
    case red, orange, yellow, green, blue, purple, pink, gray
}

/// A short label in a rounded pill: "Shared", "2FA".
public struct Tag: Codable, Equatable, Sendable {
    public var text: String
    public var tint: Tint?
    public init(text: String, tint: Tint? = nil) {
        self.text = text
        self.tint = tint
    }
}

public enum Icon: Codable, Equatable, Sendable {
    case symbol(String)
    case png(Data)
    case file(String)
    case app(String)

    private enum Key: String, CodingKey { case symbol, png, file, app }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        if let name = try container.decodeIfPresent(String.self, forKey: .symbol) { self = .symbol(name) }
        else if let data = try container.decodeIfPresent(Data.self, forKey: .png) { self = .png(data) }
        else if let path = try container.decodeIfPresent(String.self, forKey: .file) { self = .file(path) }
        else if let id = try container.decodeIfPresent(String.self, forKey: .app) { self = .app(id) }
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "an icon names symbol, png, file or app")) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .symbol(let name): try container.encode(name, forKey: .symbol)
        case .png(let data): try container.encode(data, forKey: .png)
        case .file(let path): try container.encode(path, forKey: .file)
        case .app(let id): try container.encode(id, forKey: .app)
        }
    }
}

/// Something to do to an item or a view. The first is ↩, the second ⌘↩; ⌘K lists them all.
/// The chords a plugin may bind ([views](product/plugins/views.md#shortcuts)): ⌘ or ⌘⇧ with a letter
/// dock2 does not use itself — not ⌘K, ⌘W, ⌘Q, nor the text-editing ⌘A ⌘C ⌘V ⌘X ⌘Z and ⇧⌘Z.
public enum PluginChord {
    static let reserved: Set<Character> = ["k", "w", "q", "a", "c", "v", "x", "z"]
    static let reservedWithShift: Set<Character> = ["z"]

    public static func isAllowed(_ key: String) -> Bool {
        let parts = key.lowercased().split(separator: "+").map(String.init)
        guard let letter = parts.last?.first, parts.last?.count == 1, letter.isLetter, letter.isASCII else { return false }
        switch Array(parts.dropLast()) {
        case ["cmd"]: return !reserved.contains(letter)
        case ["cmd", "shift"]: return !reservedWithShift.contains(letter)
        default: return false
        }
    }
}

public struct ActionNode: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var icon: Icon?
    /// A chord of the remaining ⌘- and ⌘⇧-letters, written "cmd+shift+c"; or "opt+return".
    public var key: String?
    public var destructive: Bool?

    public init(id: String, title: String, icon: Icon? = nil, key: String? = nil, destructive: Bool? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.key = key
        self.destructive = destructive
    }
}

public struct ListNode: Codable, Equatable, Sendable {
    public enum Filtering: String, Codable, Sendable {
        /// dock2 matches the field's text against every item, as search does.
        case dock2
        /// The owner is told the text and answers with new items.
        case owner
    }

    public struct Section: Codable, Equatable, Sendable {
        public var title: String?
        public var items: [Item]
        public init(title: String? = nil, items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    public struct Accessory: Codable, Equatable, Sendable {
        public var text: String?
        public var icon: Icon?
        public var tag: Tag?
        public init(text: String? = nil, icon: Icon? = nil, tag: Tag? = nil) {
            self.text = text
            self.icon = icon
            self.tag = tag
        }
    }

    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var icon: Icon?
        public var title: String
        public var subtitle: String?
        public var accessories: [Accessory]?
        public var keywords: [String]?
        public var actions: [ActionNode]?
        /// Shown beside the list, for a list with `preview`.
        public var detail: DetailNode?

        public init(id: String, icon: Icon? = nil, title: String, subtitle: String? = nil, accessories: [Accessory]? = nil,
                    keywords: [String]? = nil, actions: [ActionNode]? = nil, detail: DetailNode? = nil) {
            self.id = id
            self.icon = icon
            self.title = title
            self.subtitle = subtitle
            self.accessories = accessories
            self.keywords = keywords
            self.actions = actions
            self.detail = detail
        }
    }

    public struct EmptyState: Codable, Equatable, Sendable {
        public var title: String
        public var subtitle: String?
        public init(title: String, subtitle: String? = nil) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    public var id: String
    public var title: String?
    public var sections: [Section]
    public var filtering: Filtering?
    public var preview: Bool?
    public var empty: EmptyState?
    public var loading: Bool?
    public var actions: [ActionNode]?

    public init(id: String, title: String? = nil, sections: [Section], filtering: Filtering? = nil, preview: Bool? = nil,
                empty: EmptyState? = nil, loading: Bool? = nil, actions: [ActionNode]? = nil) {
        self.id = id
        self.title = title
        self.sections = sections
        self.filtering = filtering
        self.preview = preview
        self.empty = empty
        self.loading = loading
        self.actions = actions
    }

    /// The items as dock2 filters them: every item a query matches, by title then keywords, best first;
    /// sections kept, emptied ones dropped. An empty query keeps everything as it is.
    public func filtered(by query: Query) -> [Section] {
        guard !query.isEmpty, filtering != .owner else { return sections }
        return sections.compactMap { section in
            let ranked = section.items.compactMap { item -> (Item, MatchKind)? in
                let kinds = ([item.title] + (item.keywords ?? [])).compactMap { Matcher.match(query, $0, subsequence: true)?.kind }
                return kinds.min().map { (item, $0) }
            }
            let items = ranked.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
            return items.isEmpty ? nil : Section(title: section.title, items: items)
        }
    }
}

public struct DetailNode: Codable, Equatable, Sendable {
    public struct Metadata: Codable, Equatable, Sendable {
        public var label: String
        public var value: String
        public var link: String?
        /// After the value, or in its place when it is empty.
        public var tags: [Tag]?
        public init(label: String, value: String, link: String? = nil, tags: [Tag]? = nil) {
            self.label = label
            self.value = value
            self.link = link
            self.tags = tags
        }
    }

    /// A position to drag, between 0 and `maximum`: where a track is. Let go, it submits `[id: value]`.
    public struct Scrubber: Codable, Equatable, Sendable {
        public var id: String
        public var value: Double
        public var maximum: Double
        /// Either side of it: "1:02", "3:45".
        public var leading: String?
        public var trailing: String?
        public init(id: String, value: Double, maximum: Double, leading: String? = nil, trailing: String? = nil) {
            self.id = id
            self.value = value
            self.maximum = maximum
            self.leading = leading
            self.trailing = trailing
        }
    }

    public var id: String
    /// Formatted text, as Markdown.
    public var body: String?
    /// An image above the text: a copied picture, album art.
    public var image: Icon?
    public var metadata: [Metadata]?
    public var scrubber: Scrubber?
    public var actions: [ActionNode]?

    public init(id: String, body: String? = nil, image: Icon? = nil, metadata: [Metadata]? = nil, scrubber: Scrubber? = nil,
                actions: [ActionNode]? = nil) {
        self.id = id
        self.body = body
        self.image = image
        self.metadata = metadata
        self.scrubber = scrubber
        self.actions = actions
    }
}

public struct FormNode: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, secure, multiline, toggle, choice, date, folder
    }

    public struct Option: Codable, Equatable, Sendable {
        public var value: String
        public var title: String
        public init(value: String, title: String) {
            self.value = value
            self.title = title
        }
    }

    public struct Field: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var kind: Kind
        /// The text, the choice's value, a toggle's "true" or "false", a date's ISO 8601, a folder's path.
        public var value: String?
        public var placeholder: String?
        public var error: String?
        public var options: [Option]?

        public init(id: String, title: String, kind: Kind, value: String? = nil, placeholder: String? = nil,
                    error: String? = nil, options: [Option]? = nil) {
            self.id = id
            self.title = title
            self.kind = kind
            self.value = value
            self.placeholder = placeholder
            self.error = error
            self.options = options
        }
    }

    public var id: String
    public var title: String?
    public var fields: [Field]
    public var submit: String

    public init(id: String, title: String? = nil, fields: [Field], submit: String) {
        self.id = id
        self.title = title
        self.fields = fields
        self.submit = submit
    }
}

public struct GridNode: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var image: Icon
        public var title: String?
        public var actions: [ActionNode]?
        public init(id: String, image: Icon, title: String? = nil, actions: [ActionNode]? = nil) {
            self.id = id
            self.image = image
            self.title = title
            self.actions = actions
        }
    }

    public var id: String
    public var title: String?
    public var items: [Item]
    public var columns: Int?
    /// The view's own, on ⌘K after the selected item's.
    public var actions: [ActionNode]?

    public init(id: String, title: String? = nil, items: [Item], columns: Int? = nil, actions: [ActionNode]? = nil) {
        self.id = id
        self.title = title
        self.items = items
        self.columns = columns
        self.actions = actions
    }
}

extension [ActionNode] {
    /// These actions with every chord a plugin may not bind taken off — the action stays, on ⌘K — adding
    /// the chords taken to `refused`.
    public func withoutReservedChords(_ refused: inout [String]) -> [ActionNode] {
        map { action in
            guard let key = action.key, !PluginChord.isAllowed(key) else { return action }
            refused.append(key)
            var action = action
            action.key = nil
            return action
        }
    }
}

extension ViewNode {
    /// The node with every chord a plugin may not bind taken off its action — the action stays, on ⌘K —
    /// and the chords taken.
    public func withoutReservedChords() -> (node: ViewNode, refused: [String]) {
        var refused: [String] = []
        func clean(_ actions: [ActionNode]?) -> [ActionNode]? { actions?.withoutReservedChords(&refused) }
        switch self {
        case .list(var list):
            list.actions = clean(list.actions)
            list.sections = list.sections.map { section in
                var section = section
                section.items = section.items.map { item in
                    var item = item
                    item.actions = clean(item.actions)
                    let previewActions = clean(item.detail?.actions)
                    item.detail?.actions = previewActions
                    return item
                }
                return section
            }
            return (.list(list), refused)
        case .detail(var detail):
            detail.actions = clean(detail.actions)
            return (.detail(detail), refused)
        case .grid(var grid):
            grid.actions = clean(grid.actions)
            grid.items = grid.items.map { item in
                var item = item
                item.actions = clean(item.actions)
                return item
            }
            return (.grid(grid), refused)
        case .form:
            return (self, [])
        }
    }
}
