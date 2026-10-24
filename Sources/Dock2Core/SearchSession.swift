import Foundation

/// A source's section of results. The order of the cases is the order of the sections.
public enum SectionID: Hashable, Sendable, Comparable {
    /// The answer to a query that asks something: first, since a question has one answer.
    case calculator
    case apps, commands, clipboard, files
    /// A plugin's results, in the order the user sets, under the title its manifest gives.
    case plugin(String, order: Int, title: String)

    private var rank: (Int, Int, String) {
        switch self {
        case .calculator: (0, 0, "")
        case .apps: (1, 0, "")
        case .commands: (2, 0, "")
        case .clipboard: (3, 0, "")
        case .files: (4, 0, "")
        case .plugin(let id, let order, _): (5, order, id)
        }
    }

    public static func < (lhs: SectionID, rhs: SectionID) -> Bool { lhs.rank < rhs.rank }

    /// The sections the user can switch off as a whole in Settings → Search.
    public static let builtIn: [SectionID] = [.calculator, .apps, .commands, .clipboard, .files]

    /// How many of its results a section shows before "Show all…".
    public var share: Int { self == .files ? 5 : 3 }

    public var title: String {
        switch self {
        case .calculator: "Calculator"
        case .apps: "Apps"
        case .commands: "Commands"
        case .clipboard: "Clipboard"
        case .files: "Files"
        case .plugin(_, _, let title): title
        }
    }
}

/// What a result stands for, for the actions to act on.
public enum ResultPayload: Hashable, Sendable {
    case app(AppRef)
    case file(String)
    case command(String)
    case clip(String)
    case plugin(plugin: String, item: String)
    /// The calculator's, as it is copied.
    case answer(String)

    /// Whether choosing it is a learned pick: an answer is its query's own, with nothing to choose between.
    public var isLearned: Bool {
        if case .answer = self { false } else { true }
    }
}

public struct SearchResult: Sendable, Equatable, Identifiable {
    /// Stable across queries: `app:<identity>`, `file:<path>`, `cmd:<id>`, `clip:<id>`, `plugin:<id>:<item>`, and
    /// `calc`, one row whatever its answer.
    public var id: String
    public var section: SectionID
    public var title: String
    public var subtitle: String?
    /// A state shown on the right: "Running".
    public var accessory: String?
    public var match: Match
    /// The source's own ranking signal, higher first, after how it matched.
    public var signal: Double
    /// What decides between equal signals, higher first: the system's own use, for apps.
    public var tiebreak: Double
    public var payload: ResultPayload

    public init(id: String, section: SectionID, title: String, subtitle: String? = nil, accessory: String? = nil,
                match: Match, signal: Double = 0, tiebreak: Double = 0, payload: ResultPayload) {
        self.id = id
        self.section = section
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.match = match
        self.signal = signal
        self.tiebreak = tiebreak
        self.payload = payload
    }
}

/// One query's results, kept still ([search](../../.agents/product/search/README.md#order)): ranked until the
/// first frame, frozen by it, and after it only ever added to at the far end of a section.
public struct SearchSession: Sendable {
    public enum Row: Equatable, Sendable {
        case result(SearchResult, topHit: Bool)
        case showAll(SectionID, count: Int)
        /// A section's last word: Files' row naming the places it cannot see.
        case note(SectionID, String)
        case title(SectionID)

        /// The identity selection follows: a result's id, or a section's "Show all…".
        public var id: String {
            switch self {
            case .result(let result, _): result.id
            case .showAll(let section, _): "all:\(section)"
            case .note(let section, _): "note:\(section)"
            case .title(let section): "title:\(section)"
            }
        }

        public var isSelectable: Bool {
            if case .title = self { return false }
            return true
        }
    }

    public let query: Query
    /// Said at the end of a section that has results.
    public var notes: [SectionID: String] = [:]
    /// The learned pick for this query that its results still contain, if any.
    private let picks: [String]
    private var sections: [SectionID: [SearchResult]] = [:]
    private var ids: Set<String> = []
    public private(set) var frozen = false
    public private(set) var topHit: SearchResult?
    /// Results that went away while shown: drawn dimmed until the next keystroke.
    public private(set) var vanished: Set<String> = []

    /// `picks` are the learned picks that apply to the query, best first.
    public init(query: Query, picks: [String] = []) {
        self.query = query
        self.picks = picks
    }

    private func pickRank(_ result: SearchResult) -> Int {
        picks.firstIndex(of: result.id) ?? picks.count
    }

    /// Before the first frame, merges and ranks; after it, appends what is new to the end of its section.
    public mutating func add(_ results: [SearchResult]) {
        let new = results.filter { ids.insert($0.id).inserted }
        guard !new.isEmpty else { return }
        for (section, batch) in Dictionary(grouping: new, by: \.section) {
            let sorted = batch.sorted(by: ranksBefore)
            if frozen {
                sections[section, default: []] += sorted
                if topHit == nil { chooseTopHit() }
            } else {
                sections[section] = (sections[section, default: []] + sorted).sorted(by: ranksBefore)
            }
        }
    }

    /// The first frame: the top hit is chosen and the order fixed.
    public mutating func freeze() {
        guard !frozen else { return }
        frozen = true
        chooseTopHit()
    }

    /// The best result there is. After the first frame only when it had none: nothing was selected to move.
    private mutating func chooseTopHit() {
        let best = sections.values.compactMap(\.first).min { a, b in
            let pa = pickRank(a), pb = pickRank(b)
            if pa != pb { return pa < pb }
            if a.match.kind != b.match.kind { return a.match.kind < b.match.kind }
            if a.section != b.section { return a.section < b.section }
            return ranksBefore(a, b)
        }
        if let best {
            topHit = best
            sections[best.section]?.removeAll { $0.id == best.id }
        }
    }

    public mutating func vanish(_ id: String) {
        if ids.contains(id) { vanished.insert(id) }
    }

    /// Every result of a section, in order: what "Show all…" opens.
    public func all(in section: SectionID) -> [SearchResult] {
        (topHit?.section == section ? [topHit!] : []) + (sections[section] ?? [])
    }

    /// Nearest the field first: the top hit, then per section its best rows, "Show all…", its note, and its
    /// title. A note stands alone, its section otherwise empty, when nothing at all was found: then it is
    /// what explains why.
    public var rows: [Row] {
        guard frozen else { return [] }
        var rows: [Row] = topHit.map { [.result($0, topHit: true)] } ?? []
        let alone = isEmpty ? Set(notes.keys) : []
        for section in Set(sections.keys).union(alone).sorted() {
            let results = sections[section] ?? []
            guard !results.isEmpty || alone.contains(section) else { continue }
            rows += results.prefix(section.share).map { .result($0, topHit: false) }
            if results.count > section.share { rows.append(.showAll(section, count: results.count)) }
            if let note = notes[section] { rows.append(.note(section, note)) }
            rows.append(.title(section))
        }
        return rows
    }

    public var isEmpty: Bool { topHit == nil && sections.values.allSatisfy(\.isEmpty) }

    /// Within a section: learned pick, how it matched, the source's signal, then name and identity.
    private func ranksBefore(_ a: SearchResult, _ b: SearchResult) -> Bool {
        let pa = pickRank(a), pb = pickRank(b)
        if pa != pb { return pa < pb }
        if a.match.kind != b.match.kind { return a.match.kind < b.match.kind }
        if a.signal != b.signal { return a.signal > b.signal }
        if a.tiebreak != b.tiebreak { return a.tiebreak > b.tiebreak }
        let ta = Matcher.fold(a.title), tb = Matcher.fold(b.title)
        if ta != tb { return ta < tb }
        return a.id < b.id
    }
}

/// What search learns: a result chosen for a query is put first the next time that query, or a longer one
/// that still matches it, is typed.
public struct LearnedPicks: Codable, Sendable, Equatable {
    public struct Pick: Codable, Sendable, Equatable {
        public var query: String
        public var id: String
        public var date: Date
        /// What it was called when picked, for Settings to list it by.
        public var title: String?
    }

    public private(set) var picks: [Pick] = []

    public init(picks: [Pick] = []) {
        self.picks = picks
    }

    /// The results picked for a prefix of `query`, the longest query first, then the latest.
    public func candidates(for query: Query) -> [String] {
        let typed = query.folded
        return picks.filter { typed.hasPrefix($0.query) }
            .sorted { ($0.query.count, $0.date) > ($1.query.count, $1.date) }
            .map(\.id)
    }

    /// Records the choice, replacing what that query picked before.
    public mutating func record(_ id: String, title: String? = nil, for query: Query, at date: Date = Date()) {
        guard !query.isEmpty else { return }
        picks.removeAll { $0.query == query.folded }
        picks.append(Pick(query: query.folded, id: id, date: date, title: title))
    }

    /// Forgets what one query picked.
    public mutating func forget(_ query: String) {
        picks.removeAll { $0.query == query }
    }

    public mutating func clear() {
        picks = []
    }
}
