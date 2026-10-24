import Foundation

// emira's `ConfigDocument` (eed25dc) with its schema taken out: validation is the caller's, keys are paths.
// An edit splices over one value's text, or adds one line; every other byte stays as the author left it.
// No I/O: `rendered` is a `String`, and the caller writes it.

/// A TOML file, its text and its parse held together, so a value can be changed in place. Every field
/// is a `let`: an edit replaces the whole document, so the text and the spans cannot disagree.
public struct TOMLDocument: Sendable {

    /// The file's text. `rendered` is this and nothing else, so a document read and written back is the
    /// same bytes.
    private let text: String
    /// The same text parsed, kept whole: a reader takes from a copy, so the spans survive the read.
    public let table: TOMLTable
    /// The terminator this file's lines end with, which any line this adds has to match.
    private let terminator: String

    /// - Throws: `TOMLError` for text that is not TOML. A document that cannot be read is one nothing
    ///   may splice.
    public init(_ text: String) throws {
        self.table = try TOMLTable.parse(text)
        self.text = text
        self.terminator = text.first(where: \.isNewline).map(String.init) ?? "\n"
    }

    /// The file as it now stands, for the caller to write.
    public var rendered: String { text }

    /// Set `path` to `value` — splicing over the value already there, or inserting a line for a key the
    /// file doesn't set. Throws `TOMLError` when the edit cannot be made or the result would not parse, and
    /// the document is untouched.
    public mutating func set(_ path: [String], to value: TOMLValue) throws {
        var edited = text
        if let span = table.span(of: path) {
            edited.replaceSubrange(span.value, with: spell(value))
        } else {
            try insert(path, value, into: &edited)
        }
        try commit(edited)
    }

    /// Unset `path`, taking its whole statement with it — its trailing comment included, and every line
    /// of a multi-line value. A key the file doesn't set is left alone.
    public mutating func remove(_ path: [String]) throws {
        guard let span = table.span(of: path) else { return }
        if table.origin(of: Array(path.dropLast())) == .inline {
            throw TOMLError.inline(line: table.line(of: path) ?? 0, key: Self.spell(path))
        }
        var edited = text
        edited.removeSubrange(withTerminator(span.statement))
        try commit(edited)
    }

    /// Rename the key at `path` to `name`, leaving its value, its line and its trailing comment where
    /// they are. One splice rather than a `remove` and a `set`, which would move the line to the end of
    /// its table. A key the file doesn't set is left alone.
    public mutating func rename(_ path: [String], to name: String) throws {
        guard let last = path.last, last != name, let span = table.span(of: path) else { return }
        var edited = text
        edited.replaceSubrange(span.key, with: TOMLTable.spell(key: name))
        try commit(edited)
    }

    /// The keys holding values directly under `path`, spelled the way the file spells them, in file order.
    public func names(under path: [String]) -> [String] {
        table.names(under: path)
    }

    /// How a value is written into this file: an array too long for one line gets a line per element.
    private func spell(_ value: TOMLValue) -> String {
        value.spelled(wrappingAt: Self.wrapWidth, terminator: terminator)
    }

    /// The longest array, in columns, written on one line.
    public static let wrapWidth = 80

    /// A path as a dotted key, each segment quoted where it has to be.
    public static func spell(_ path: [String]) -> String {
        path.map(TOMLTable.spell(key:)).joined(separator: ".")
    }

    /// Take the edit by reading the edited text from scratch: spans move when text is spliced, and
    /// reading again is the one way to keep them in step that cannot fall out of it.
    private mutating func commit(_ edited: String) throws {
        self = try TOMLDocument(edited)
    }

    // Where a new line goes: at the end of the run of the nearest table the file wrote — as a dotted key if
    // the tables between aren't written — or under a header of its own, appended.

    private func insert(_ path: [String], _ value: TOMLValue, into edited: inout String) throws {
        guard let name = path.last else { return }
        var anchor = Array(path.dropLast())
        var written = [name]
        walk: while true {
            switch table.origin(of: anchor) {
            case .inline:
                throw TOMLError.inline(line: table.table(at: anchor)?.line ?? 0, key: Self.spell(path))
            case .header, .root, .implicit:
                break walk
            case .dotted:
                // Its keys live in the statement of a table further up.
                written.insert(anchor.removeLast(), at: 0)
            case nil:
                // A table the file wrote further up takes it as a dotted key; otherwise it gets a header.
                guard let existing = nearestExisting(above: anchor), existing.origin == .header || existing.origin == .dotted
                else { break walk }
                written.insert(anchor.removeLast(), at: 0)
            }
        }

        let statement = Self.spell(written) + " = " + spell(value)
        if let extent = table.extent(of: anchor) {
            // The run ends at the last key line, not at the blank line or comment that may follow it.
            edited.insert(contentsOf: terminator + statement, at: extent.upperBound)
        } else if anchor.isEmpty {
            // A top-level key has to precede every header — TOML's rule, not a preference.
            if let first = table.firstHeaderStart {
                edited.insert(contentsOf: statement + terminator + terminator, at: first)
            } else {
                append(statement, to: &edited)
            }
        } else {
            append("[" + Self.spell(anchor) + "]" + terminator + statement, to: &edited)
        }
    }

    /// The nearest table above `path` that exists, and how it came to.
    private func nearestExisting(above path: [String]) -> (path: [String], origin: TOMLTable.Origin)? {
        var prefix = path
        while !prefix.isEmpty {
            prefix.removeLast()
            if let origin = table.origin(of: prefix) { return (prefix, origin) }
        }
        return nil
    }

    /// At the end of the file, a blank line clear of whatever was there. A file that didn't end in a
    /// terminator gains one, which is the one byte an append moves that it wasn't asked to.
    private func append(_ block: String, to edited: inout String) {
        if let last = edited.last, !last.isNewline { edited += terminator }
        if !edited.isEmpty { edited += terminator }
        edited += block + terminator
    }

    /// A statement's range grown to swallow the terminator that ends it — or, on a last line that has
    /// none, the terminator before it, so removing it doesn't leave a blank line in its place.
    private func withTerminator(_ statement: Range<String.Index>) -> Range<String.Index> {
        if statement.upperBound < text.endIndex, text[statement.upperBound].isNewline {
            return statement.lowerBound..<text.index(after: statement.upperBound)
        }
        if statement.lowerBound > text.startIndex {
            return text.index(before: statement.lowerBound)..<statement.upperBound
        }
        return statement
    }
}
