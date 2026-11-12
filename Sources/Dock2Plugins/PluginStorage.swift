import Dock2Core
import Dock2System
import Foundation
import SQLite3

/// A plugin's storage ([runtime](product/plugins/runtime.md#storage)): string keys to string values in SQLite,
/// `storage.db` in its data folder, keys in the order of their UTF-8 bytes. Every key and value is a bound
/// parameter; a plugin never names SQL. Worked on a queue of its own, in the order asked, opened at first use.
final class PluginStorage: @unchecked Sendable {
    struct Limits: Sendable {
        /// What every entry costs together: its key and value, and `entryCost`.
        var quota = 256 << 20
        var value = 24 << 20
        var key = 1 << 10
        /// A listed page ends before the entry that would take it past either, but never empty.
        var pageEntries = 1_000
        var pageBytes = 4 << 20
    }

    /// An entry's cost past its key and value, about what SQLite spends on one: tiny entries count as what they take.
    static let entryCost = 16

    let limits: Limits
    let directory: URL
    private let queue: DispatchQueue
    // Touched only on `queue`.
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    /// What the entries cost, measured as the database opens.
    private var used = 0

    init(directory: URL, label: String, limits: Limits = Limits()) {
        self.directory = directory
        self.limits = limits
        queue = DispatchQueue(label: "\(Dock2Identity.bundleIdentifier).plugin-storage.\(label)", qos: .userInitiated)
    }

    var file: URL { directory.appendingPathComponent("storage.db") }

    /// `work` on the storage's queue, after everything asked before it.
    func async(_ work: @escaping @Sendable (PluginStorage) -> Void) {
        queue.async { work(self) }
    }

    /// Closed once what was asked before is done; what is asked after opens it again.
    func close() {
        queue.async { self.closeDatabase() }
    }

    /// Waits for everything asked so far.
    func drain() {
        queue.sync {}
    }

    // MARK: - On its queue

    /// Each of `keys` that holds a value, with it, in the order asked.
    func read(_ keys: [String]) throws -> [StorageEntry] {
        try open()
        var entries: [StorageEntry] = []
        for key in keys {
            try query("SELECT value FROM entries WHERE key = ?", [.text(key)]) { row in
                entries.append(StorageEntry(key: key, value: Self.blob(row, 0)))
                return false
            }
        }
        return entries
    }

    /// A page of `listing`, and whether its range goes on past it.
    func list(_ listing: StorageListing) throws -> (entries: [StorageEntry], more: Bool) {
        try open()
        let limit = min(max(listing.limit ?? limits.pageEntries, 1), limits.pageEntries)
        var range = KeyRange(prefix: listing.prefix)
        if let after = listing.after { range.narrow(past: after, reverse: listing.reverse) }
        let columns = listing.keysOnly ? "key" : "key, value"
        let sql = "SELECT \(columns) FROM entries\(range.sql) ORDER BY key\(listing.reverse ? " DESC" : "") LIMIT ?"
        var entries: [StorageEntry] = [], bytes = 0, more = false
        try query(sql, range.bound + [.int(limit + 1)]) { row in
            let key = Self.text(row, 0)
            let size = key.utf8.count + (listing.keysOnly ? 0 : Int(sqlite3_column_bytes(row, 1)))
            guard entries.count < limit, entries.isEmpty || bytes + size <= limits.pageBytes else {
                more = true
                return false
            }
            entries.append(StorageEntry(key: key, value: listing.keysOnly ? nil : Self.blob(row, 1)))
            bytes += size
            return true
        }
        return (entries, more)
    }

    /// `ops` in order as one transaction: every one of them, or, past a limit or failing, none.
    func write(_ ops: [StorageOp]) throws {
        for case .set(let key, let value) in ops {
            guard key.utf8.count <= limits.key else { throw PluginFailure("a key past \(Self.size(limits.key)): \(key.prefix(40))…") }
            guard value.utf8.count <= limits.value else { throw PluginFailure("\(key.prefix(200)): a value past \(Self.size(limits.value))") }
        }
        try open()
        var change = 0
        try transaction {
            for op in ops {
                switch op {
                case .set(let key, let value):
                    change -= try cost(KeyRange(key: key))
                    try query("INSERT OR REPLACE INTO entries (key, value) VALUES (?, ?)", [.text(key), .blob(value)])
                    change += key.utf8.count + value.utf8.count + Self.entryCost
                case .delete(let key):
                    let range = KeyRange(key: key)
                    change -= try cost(range)
                    try query("DELETE FROM entries\(range.sql)", range.bound)
                case .deletePrefix(let prefix):
                    let range = KeyRange(prefix: prefix)
                    change -= try cost(range)
                    try query("DELETE FROM entries\(range.sql)", range.bound)
                }
            }
            // One already past the quota, from before it or from storage.json, may still shrink.
            guard change <= 0 || used + change <= limits.quota else {
                throw PluginFailure("past its \(Self.size(limits.quota)) of storage: nothing of this write was kept")
            }
        }
        used += change
    }

    /// What the entries in `range` cost together.
    private func cost(_ range: KeyRange) throws -> Int {
        var total = 0
        try query("SELECT sum(length(CAST(key AS BLOB)) + length(value) + \(Self.entryCost)) FROM entries\(range.sql)", range.bound) { row in
            total = Int(sqlite3_column_int64(row, 0))
            return false
        }
        return total
    }

    // MARK: - The database

    /// WAL, so a write that fails or a process that dies mid-write leaves what was there; `synchronous = NORMAL`
    /// keeps that, and loses at worst the last writes to a power cut.
    private func open() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no memory"
            sqlite3_close(handle)
            throw PluginFailure("its storage did not open: \(message)")
        }
        db = handle
        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try execute("CREATE TABLE IF NOT EXISTS entries (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL) WITHOUT ROWID")
            try importJSON()
            used = try cost(KeyRange(prefix: ""))
        } catch {
            closeDatabase()
            throw error
        }
    }

    /// `storage.json`, where storage was kept before: its keys over the database's, then it goes. Carried in again
    /// if it outlived the transaction, which nothing has written after.
    private func importJSON() throws {
        let legacy = JSONFile<[String: String]>("storage.json", in: directory)
        guard FileManager.default.fileExists(atPath: legacy.url.path) else { return }
        let values = legacy.load() ?? [:]
        try transaction {
            for (key, value) in values { try query("INSERT OR REPLACE INTO entries (key, value) VALUES (?, ?)", [.text(key), .blob(value)]) }
        }
        try FileManager.default.removeItem(at: legacy.url)
    }

    private func closeDatabase() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements = [:]
        sqlite3_close(db)
        db = nil
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func failure() -> PluginFailure {
        PluginFailure("its storage failed: \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "not open")")
    }

    private enum Bound {
        case text(String)
        /// A value: UTF-8 kept as bytes, whose length SQLite knows without reading them.
        case blob(String)
        case int(Int)
    }

    /// `sql`, prepared once a connection, run with `bound`; `row` has each row in turn until it says stop.
    private func query(_ sql: String, _ bound: [Bound], row: (OpaquePointer) throws -> Bool = { _ in true }) throws {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (index, value) in bound.enumerated() {
            let at = Int32(index + 1)
            // `withCString` is never a null pointer, which SQLite would bind as NULL rather than "".
            let status = switch value {
            case .text(let text): text.withCString { sqlite3_bind_text(statement, at, $0, Int32(text.utf8.count), transient) }
            case .blob(let text): text.withCString { sqlite3_bind_blob(statement, at, $0, Int32(text.utf8.count), transient) }
            case .int(let number): sqlite3_bind_int64(statement, at, Int64(number))
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: guard try row(statement) else { return }
            case SQLITE_DONE: return
            default: throw failure()
            }
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        statements[sql] = statement
        return statement
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(row, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(row, column))), as: UTF8.self)
    }

    private static func blob(_ row: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_blob(row, column) else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(row, column))), as: UTF8.self)
    }

    static func size(_ bytes: Int) -> String {
        if bytes >= 1 << 20, bytes % (1 << 20) == 0 { return "\(bytes >> 20) MiB" }
        if bytes >= 1 << 10, bytes % (1 << 10) == 0 { return "\(bytes >> 10) KiB" }
        return "\(bytes) bytes"
    }

    /// The keys between two bounds, as a `WHERE` clause and what it binds: one bound of each side at most, so the
    /// index is searched from where the range starts rather than scanned up to it.
    private struct KeyRange {
        var lower: (key: String, inclusive: Bool)?
        /// Exclusive.
        var upper: String?
        var exactly: String?

        init(prefix: String) {
            lower = prefix.isEmpty ? nil : (prefix, true)
            upper = PluginStorage.end(of: prefix)
        }

        init(key: String) {
            exactly = key
        }

        /// From past `after`: the side the listing goes on from is cut there, if `after` lies inside it.
        mutating func narrow(past after: String, reverse: Bool) {
            if reverse {
                if upper.map({ PluginStorage.precedes(after, $0) }) ?? true { upper = after }
            } else if lower.map({ !PluginStorage.precedes(after, $0.key) }) ?? true {
                lower = (after, false)
            }
        }

        var sql: String {
            if exactly != nil { return " WHERE key = ?" }
            let conditions = [lower.map { $0.inclusive ? "key >= ?" : "key > ?" }, upper.map { _ in "key < ?" }].compactMap { $0 }
            return conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        }

        var bound: [Bound] {
            if let exactly { return [.text(exactly)] }
            return [lower.map { Bound.text($0.key) }, upper.map { Bound.text($0) }].compactMap { $0 }
        }
    }

    /// The least key past every key under `prefix`, or none for "" or a prefix of the last scalars alone. UTF-8's
    /// bytes order as its scalars do, so its last scalar steps up one — over the surrogates, which no string holds.
    static func end(of prefix: String) -> String? {
        var scalars = Array(prefix.unicodeScalars)
        while let last = scalars.popLast() {
            let next = last.value == 0xD7FF ? 0xE000 : last.value + 1
            if let scalar = Unicode.Scalar(next) { return String(String.UnicodeScalarView(scalars + [scalar])) }
        }
        return nil
    }

    /// Whether `a` sorts before `b` as SQLite's BINARY collation does: by UTF-8 bytes.
    static func precedes(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }
}

/// SQLite copies what it binds: `SQLITE_TRANSIENT`, which Swift does not import.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
