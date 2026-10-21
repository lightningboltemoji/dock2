import Foundation

/// How a name matched a query, best first ([search](../../.agents/product/search/README.md#the-query)).
public enum MatchKind: Int, Sendable, Comparable, Codable {
    /// The whole name, spaces ignored.
    case exact
    /// The name's start.
    case prefix
    /// Each query word begins a distinct word of the name.
    case words
    /// A one-word query is the initials of a run of the name's words: "vsc" for Visual Studio Code.
    case initials
    /// The query's characters in order: apps and commands only.
    case subsequence

    public static func < (lhs: MatchKind, rhs: MatchKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Match: Sendable, Equatable {
    public var kind: MatchKind
    /// The parts of the name that matched, as UTF-16 offsets, for drawing them in bold.
    public var ranges: [Range<Int>]

    public init(kind: MatchKind, ranges: [Range<Int>]) {
        self.kind = kind
        self.ranges = ranges
    }
}

/// The field's text, trimmed and folded, and split into words at spaces.
public struct Query: Sendable, Equatable, Hashable {
    public let text: String
    public let folded: String
    public let words: [String]

    public init(_ text: String) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        folded = Matcher.fold(self.text)
        words = folded.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public var isEmpty: Bool { words.isEmpty }
    /// A query that starts with `~` or `/` is a path, not a search.
    public var isPath: Bool { PathInput.isPath(text) }
}

public enum Matcher {
    /// Case, diacritics and width folded away, as every comparison in search sees text.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// A name's words: split at spaces and punctuation, at a lower-to-upper change (GitHub → Git·Hub), before
    /// the last capital of a run followed by lower case (VSCode → VS·Code), and at letter–digit changes
    /// (1Password → 1·Password). Each with its folded text and its UTF-16 range in the name.
    public static func words(of name: String) -> [(folded: String, range: Range<Int>)] {
        let characters = Array(name.utf16)
        var words: [(String, Range<Int>)] = []
        var start: Int?
        func kind(_ unit: UInt16) -> Int {
            guard let scalar = Unicode.Scalar(unit) else { return 3 }
            if CharacterSet.uppercaseLetters.contains(scalar) { return 2 }
            if CharacterSet.letters.contains(scalar) { return 1 }
            if CharacterSet.decimalDigits.contains(scalar) { return 4 }
            return 0
        }
        func close(_ end: Int) {
            if let begin = start, begin < end {
                let text = String(utf16CodeUnits: Array(characters[begin..<end]), count: end - begin)
                words.append((fold(text), begin..<end))
            }
            start = nil
        }
        for index in characters.indices {
            let current = kind(characters[index])
            if current == 0 {
                close(index)
                continue
            }
            if let begin = start, index > begin {
                let previous = kind(characters[index - 1])
                let next = index + 1 < characters.count ? kind(characters[index + 1]) : 0
                let isLetter = { (k: Int) in k == 1 || k == 2 }
                if (previous == 1 && current == 2)
                    || (previous == 2 && current == 2 && next == 1)
                    || (isLetter(previous) && current == 4) || (previous == 4 && isLetter(current)) {
                    close(index)
                }
            }
            if start == nil { start = index }
        }
        close(characters.count)
        return words
    }

    /// How `name` matches `query`, or nil. `subsequence` allows the loosest kind.
    public static func match(_ query: Query, _ name: String, subsequence: Bool = false) -> Match? {
        guard !query.isEmpty else { return nil }
        let folded = fold(name)
        let compactName = folded.filter { !$0.isWhitespace }
        let compactQuery = query.words.joined()
        let length = name.utf16.count
        if compactName == compactQuery { return Match(kind: .exact, ranges: [0..<length]) }
        if folded.hasPrefix(query.folded) {
            return Match(kind: .prefix, ranges: [0..<min(length, query.text.utf16.count)])
        }
        let words = Self.words(of: name)
        if let ranges = wordMatch(query.words, words) { return Match(kind: .words, ranges: ranges) }
        if query.words.count == 1, let ranges = initialsMatch(query.words[0], words) {
            return Match(kind: .initials, ranges: ranges)
        }
        if subsequence, let ranges = subsequenceMatch(compactQuery, name) {
            return Match(kind: .subsequence, ranges: ranges)
        }
        return nil
    }

    /// Each query word to a distinct name word it begins, taking the earliest free one.
    private static func wordMatch(_ query: [String], _ words: [(folded: String, range: Range<Int>)]) -> [Range<Int>]? {
        var used = Set<Int>()
        var ranges: [Range<Int>] = []
        for word in query {
            guard let index = words.indices.first(where: { !used.contains($0) && words[$0].folded.hasPrefix(word) }) else {
                return nil
            }
            used.insert(index)
            let range = words[index].range
            ranges.append(range.lowerBound..<min(range.upperBound, range.lowerBound + word.utf16.count))
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    private static func initialsMatch(_ query: String, _ words: [(folded: String, range: Range<Int>)]) -> [Range<Int>]? {
        let letters = Array(query)
        guard letters.count >= 2, letters.count <= words.count else { return nil }
        for start in 0...(words.count - letters.count) {
            let run = words[start..<(start + letters.count)]
            if zip(run, letters).allSatisfy({ $0.folded.first == $1 }) {
                return run.map { $0.range.lowerBound..<($0.range.lowerBound + 1) }
            }
        }
        return nil
    }

    private static func subsequenceMatch(_ query: String, _ name: String) -> [Range<Int>]? {
        var ranges: [Range<Int>] = []
        var remaining = query[...]
        for (offset, unit) in name.utf16.enumerated() {
            guard let next = remaining.first else { break }
            let character = fold(String(utf16CodeUnits: [unit], count: 1))
            if character.first == next {
                ranges.append(offset..<(offset + 1))
                remaining = remaining.dropFirst()
            }
        }
        return remaining.isEmpty ? ranges : nil
    }
}
