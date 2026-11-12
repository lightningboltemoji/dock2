import Dock2Core
@testable import Dock2Plugins
import Dock2System
import Foundation
import Testing

/// A plugin's storage: SQLite under an ordered key-value store, on its own queue. The store is driven directly for
/// its ranges and limits, and through the host and the test guest for order, answers and its files.
@MainActor
@Suite(.serialized) struct PluginStorageTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-storage-\(UUID().uuidString)", isDirectory: true)
    let id = TestHost.id

    func storage(_ limits: PluginStorage.Limits = .init()) -> PluginStorage {
        PluginStorage(directory: directory, label: "test", limits: limits)
    }

    func keys(_ storage: PluginStorage, _ listing: StorageListing) throws -> [String] {
        try storage.list(listing).entries.map(\.key)
    }

    func set(_ storage: PluginStorage, _ keys: [String]) throws {
        try storage.write(keys.map { .set(key: $0, value: "v") })
    }

    /// Swift's `==` takes canonically equivalent strings for one; storage keeps their bytes apart.
    func bytes(_ keys: [String]) -> [[UInt8]] {
        keys.map { Array($0.utf8) }
    }

    func failure(_ work: () throws -> Void) -> String? {
        do {
            try work()
            return nil
        } catch {
            return (error as? PluginFailure)?.message
        }
    }

    @Test func aBatchAppliesInOrderAndWhatFollowsSeesIt() throws {
        let storage = storage()
        try storage.write([.set(key: "item/1", value: "one"), .set(key: "item/2", value: "two"), .set(key: "meta/a", value: "a"),
                           .deletePrefix("item/"), .set(key: "item/3", value: "three"), .delete(key: "meta/a"), .set(key: "meta/b", value: ""),
                           .set(key: "item/3", value: "three again")])
        #expect(try storage.read(["item/1", "item/3", "meta/b", "meta/a", "item/3"])
            == [StorageEntry(key: "item/3", value: "three again"), StorageEntry(key: "meta/b", value: ""), StorageEntry(key: "item/3", value: "three again")])
        #expect(try keys(storage, StorageListing(request: "r")) == ["item/3", "meta/b"])
        try storage.write([])
        #expect(try keys(storage, StorageListing(request: "r")) == ["item/3", "meta/b"])
    }

    /// By UTF-8 bytes, as SQLite's BINARY collation compares: not Swift's order, nor its equality.
    @Test func keysOrderByTheirBytes() throws {
        let storage = storage()
        let ordered = ["", "B", "a", "a\u{0}b", "b", "e\u{301}", "z", "é", "😀"]
        try storage.write(ordered.reversed().enumerated().map { .set(key: $1, value: "\($0)") })
        #expect(bytes(try keys(storage, StorageListing(request: "r"))) == bytes(ordered))
        #expect(bytes(try keys(storage, StorageListing(request: "r", reverse: true))) == bytes(ordered.reversed()))
        let both = try storage.read(["é", "e\u{301}"])
        #expect(bytes(both.map(\.key)) == bytes(["é", "e\u{301}"]) && both.map(\.value) == ["1", "3"])
    }

    @Test func aPrefixEndsWhereItsLastScalarStepsUp() {
        #expect(PluginStorage.end(of: "") == nil)
        #expect(PluginStorage.end(of: "item/") == "item0")
        #expect(PluginStorage.end(of: "x\u{10FFFF}") == "y")
        #expect(PluginStorage.end(of: "\u{10FFFF}\u{10FFFF}") == nil)
        #expect(PluginStorage.end(of: "k\u{D7FF}") == "k\u{E000}")
        #expect(PluginStorage.end(of: "m\u{7F}") == "m\u{80}")
        #expect(PluginStorage.end(of: "n\u{0}") == "n\u{1}")
    }

    /// The empty prefix is every key; a prefix whose next string is awkward — its last scalar the greatest, the one
    /// before the surrogates, the last of ASCII — still holds exactly the keys that start with it, listed and deleted.
    @Test func aPrefixIsExactlyTheKeysThatStartWithIt() throws {
        let storage = storage()
        let all = ["`", "a", "a/1", "ab", "a\u{10FFFF}", "b", "k\u{D7FF}", "k\u{D7FF}z", "k\u{E000}", "k\u{FFFF}", "m\u{7F}", "m\u{7F}\u{7F}", "m\u{80}",
                   "x\u{10FFFE}", "x\u{10FFFF}", "x\u{10FFFF}a", "x\u{10FFFF}\u{10FFFF}", "y", "\u{10FFFF}", "\u{10FFFF}z"]
        try set(storage, all)
        let cases: [(String, [String])] = [
            ("", all),
            ("a", ["a", "a/1", "ab", "a\u{10FFFF}"]),
            ("k\u{D7FF}", ["k\u{D7FF}", "k\u{D7FF}z"]),
            ("m\u{7F}", ["m\u{7F}", "m\u{7F}\u{7F}"]),
            ("x\u{10FFFF}", ["x\u{10FFFF}", "x\u{10FFFF}a", "x\u{10FFFF}\u{10FFFF}"]),
            ("\u{10FFFF}", ["\u{10FFFF}", "\u{10FFFF}z"]),
            ("nothing", []),
        ]
        for (prefix, expected) in cases {
            #expect(bytes(try keys(storage, StorageListing(request: "r", prefix: prefix))) == bytes(expected), "prefix \(prefix.debugDescription)")
            #expect(bytes(try keys(storage, StorageListing(request: "r", prefix: prefix, reverse: true))) == bytes(expected.reversed()))
        }
        for (prefix, gone) in cases.dropFirst() {
            try storage.write([.deletePrefix(prefix)])
            #expect(bytes(try keys(storage, StorageListing(request: "r", prefix: prefix))).isEmpty)
            #expect(try storage.read(gone).isEmpty)
        }
        #expect(bytes(try keys(storage, StorageListing(request: "r"))) == bytes(["`", "b", "k\u{E000}", "k\u{FFFF}", "m\u{80}", "x\u{10FFFE}", "y"]))
        try storage.write([.deletePrefix("")])
        #expect(try keys(storage, StorageListing(request: "r")).isEmpty)
    }

    /// `after` the last key of a page goes on past it, either way; one outside the prefix starts it or ends it.
    @Test func aListingPagesOnFromAfter() throws {
        let storage = storage(.init(pageEntries: 5))
        let items = (0..<10).map { "item/0\($0)" }
        try set(storage, ["itel", "iten", "j"] + items)
        func page(after: String? = nil, limit: Int? = nil, reverse: Bool = false) throws -> ([String], Bool) {
            let (entries, more) = try storage.list(StorageListing(request: "r", prefix: "item/", after: after, limit: limit, reverse: reverse))
            return (entries.map(\.key), more)
        }
        #expect(try page(limit: 4) == (Array(items[0..<4]), true))
        #expect(try page(after: "item/03", limit: 4) == (Array(items[4..<8]), true))
        #expect(try page(after: "item/07", limit: 4) == (Array(items[8..<10]), false))
        #expect(try page(after: "item/09") == ([], false))
        #expect(try page(limit: 3, reverse: true) == (["item/09", "item/08", "item/07"], true))
        #expect(try page(after: "item/07", limit: 3, reverse: true) == (["item/06", "item/05", "item/04"], true))
        #expect(try page(after: "item/00", reverse: true) == ([], false))
        #expect(try page(after: "a") == (Array(items[0..<5]), true))
        #expect(try page(after: "z") == ([], false))
        #expect(try page(after: "z", limit: 2, reverse: true) == (["item/09", "item/08"], true))
        #expect(try page(after: "a", reverse: true) == ([], false))
        // A limit is one at the least, and never past the page.
        #expect(try page(limit: 0) == (["item/00"], true))
        #expect(try page(limit: 10_000) == (Array(items[0..<5]), true))
        let bare = try storage.list(StorageListing(request: "r", prefix: "item/", limit: 2, keysOnly: true)).entries
        #expect(bare == [StorageEntry(key: "item/00"), StorageEntry(key: "item/01")])
    }

    /// A page ends before the entry that would take it past its bytes, but always holds one: a value past the
    /// page comes alone.
    @Test func aPageEndsAtItsBytesButIsNeverEmpty() throws {
        let storage = storage(.init(pageBytes: 100))
        try storage.write([.set(key: "a", value: String(repeating: "a", count: 50)), .set(key: "b", value: String(repeating: "b", count: 200)),
                           .set(key: "c", value: "c")])
        func page(after: String? = nil, keysOnly: Bool = false) throws -> ([String], Bool) {
            let (entries, more) = try storage.list(StorageListing(request: "r", after: after, keysOnly: keysOnly))
            return (entries.map(\.key), more)
        }
        #expect(try page() == (["a"], true))
        #expect(try page(after: "a") == (["b"], true))
        #expect(try page(after: "b") == (["c"], false))
        #expect(try page(keysOnly: true) == (["a", "b", "c"], false))
        #expect(try storage.list(StorageListing(request: "r", after: "a")).entries.first?.value?.count == 200)
    }

    /// Past a key's, a value's or the plugin's limit, the whole batch is refused and nothing of it kept — the quota
    /// after its steps have run, which roll back. One already past it may still shrink.
    @Test func aWritePastALimitKeepsNothing() throws {
        let storage = storage(.init(quota: 200, value: 100, key: 8))
        let ninety = String(repeating: "x", count: 90)
        #expect(failure { try storage.write([.set(key: "a", value: "1"), .set(key: "ninechars", value: "x")]) } == "a key past 8 bytes: ninechars…")
        #expect(failure { try storage.write([.set(key: "a", value: "1"), .set(key: "b", value: String(repeating: "x", count: 101))]) }
            == "b: a value past 100 bytes")
        #expect(try storage.read(["a", "b"]).isEmpty)
        // 1 + 90 + 16 = 107 each.
        try storage.write([.set(key: "a", value: ninety)])
        #expect(failure { try storage.write([.deletePrefix(""), .set(key: "b", value: ninety), .set(key: "c", value: ninety)]) }
            == "past its 200 bytes of storage: nothing of this write was kept")
        #expect(try keys(storage, StorageListing(request: "r")) == ["a"])
        try storage.write([.deletePrefix(""), .set(key: "b", value: ninety)])
        #expect(try keys(storage, StorageListing(request: "r")) == ["b"])
        try storage.write([.set(key: "b", value: "small"), .set(key: "c", value: ninety)])
        #expect(try keys(storage, StorageListing(request: "r")) == ["b", "c"])

        // What storage.json brings is carried in whole, past the quota; a write that grows it is refused, one that shrinks it is not.
        storage.close()
        storage.drain()
        try JSONEncoder().encode(["big": String(repeating: "x", count: 300)]).write(to: directory.appendingPathComponent("storage.json"))
        #expect(failure { try storage.write([.set(key: "d", value: "1")]) } == "past its 200 bytes of storage: nothing of this write was kept")
        try storage.write([.delete(key: "c")])
        try storage.write([.delete(key: "big"), .set(key: "d", value: "1")])
        #expect(try keys(storage, StorageListing(request: "r")) == ["b", "d"])
    }

    /// What the entries cost is measured as the database opens, so the quota holds across a close, or another launch.
    @Test func theQuotaHoldsAcrossAClose() throws {
        let limits = PluginStorage.Limits(quota: 200)
        let first = storage(limits)
        try first.write([.set(key: "a", value: String(repeating: "x", count: 150))])
        first.close()
        first.drain()
        let second = storage(limits)
        #expect(failure { try second.write([.set(key: "b", value: String(repeating: "x", count: 30))]) } != nil)
        try second.write([.set(key: "a", value: String(repeating: "x", count: 100)), .set(key: "b", value: String(repeating: "x", count: 30))])
        #expect(try second.read(["a"]).first?.value?.count == 100)
    }

    /// `storage.json` is carried in as the database opens, its keys over the database's, then removed; an older build
    /// that wrote one again is carried in again.
    @Test func storageJSONIsCarriedInThenGoes() throws {
        let json = directory.appendingPathComponent("storage.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(["a": "1", "b": "2"]).write(to: json)
        let storage = storage()
        #expect(try storage.read(["a", "b"]).map(\.value) == ["1", "2"])
        #expect(!FileManager.default.fileExists(atPath: json.path))
        try storage.write([.set(key: "a", value: "3")])
        storage.close()
        storage.drain()
        try JSONEncoder().encode(["b": "9"]).write(to: json)
        #expect(try storage.read(["a", "b"]).map(\.value) == ["3", "9"])
        #expect(!FileManager.default.fileExists(atPath: json.path))
    }

    // MARK: - Through the host

    /// From one event, a write and then a read and a page of what it wrote: each answer under its request, and what
    /// follows sees what went before.
    @Test func oneEventsStorageEffectsApplyInOrder() async throws {
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory)
        host.send(.command(id: "store"), to: id)
        try await TestHost.settle(until: { recorder.toasts.contains { $0.hasPrefix("keys ls") } }, seconds: 5)
        let answers = recorder.toasts.filter { $0.hasPrefix("written") || $0.hasPrefix("values") || $0.hasPrefix("keys") }
        #expect(answers == ["written w", "values rd item/2=two meta/n=1", "keys ls item/1 item/2 more=true"])
        host.send(.command(id: "store-next"), to: id)
        try await TestHost.settle(until: { recorder.toasts.contains("keys ls item/3 more=false") }, seconds: 5)
        host.send(.command(id: "store-clear"), to: id)
        try await TestHost.settle(until: { recorder.toasts.contains("keys all meta/n more=false") }, seconds: 5)
        #expect(recorder.toasts.contains("keys ls item/3 more=false") && recorder.toasts.contains("keys all meta/n more=false"))
    }

    /// Past a limit comes back as an `error` under the write's request; without one, still to a running plugin.
    @Test func aWritePastALimitIsRefusedBackToThePlugin() async throws {
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory)
        try await TestHost.answered(host, recorder)
        let big = String(repeating: "x", count: PluginStorage.Limits().value + 1)
        host.perform([.storageWrite(request: "big", ops: [.set(key: "k", value: big)]), .storageSet(key: "j", value: big)], from: id,
                     answering: .timer(id: "t"))
        try await TestHost.settle(until: { recorder.toasts.contains("error: j: a value past 24 MiB") }, seconds: 5)
        #expect(recorder.toasts.contains("error: k: a value past 24 MiB") && recorder.toasts.contains("error: j: a value past 24 MiB"))
        #expect(!recorder.toasts.contains("written big"))
    }

    /// An answer it waits on keeps the instance loaded; stopping drops the answer, never the write.
    @Test func stoppingDropsAnAnswerNotAWrite() async throws {
        let recorder = Recorder(), host = TestHost.make(recorder, in: directory)
        host.perform([.storageWrite(request: "w", ops: [.set(key: "a", value: "1")]), .storageRead(request: "r", keys: ["a"])], from: id,
                     answering: .timer(id: "t"))
        #expect(!host.resources.isIdle(id))
        host.stop(id)
        #expect(host.resources.isIdle(id))
        let storage = host.storage(id)
        storage.drain()
        try await TestHost.settle(until: { false }, seconds: 0.2)
        #expect(!recorder.toasts.contains { $0.hasPrefix("written") || $0.hasPrefix("values") })
        #expect(try storage.read(["a"]) == [StorageEntry(key: "a", value: "1")])
    }

    /// Removing a plugin closes its database, then its data folder goes with the database, its `-wal` and `-shm`;
    /// installed again, it starts with nothing.
    @Test func removingAPluginTakesItsDatabase() throws {
        let file = SettingsFile(url: directory.appendingPathComponent("config.toml"), lastGood: nil, lock: directory.appendingPathComponent("config.lock"),
                                state: directory.appendingPathComponent("state.json"))
        let store = PluginStore(settings: SettingsStore(file: file, watch: false), firstParty: nil, directory: directory)
        try store.install(TestGuest.folder)
        let host = PluginHost(store: store, nowPlaying: NowPlaying(helpers: nil))
        host.perform([.storageSet(key: "a", value: "1")], from: id, answering: .timer(id: "t"))
        let storage = host.storage(id)
        storage.drain()
        let data = store.dataDirectory.appendingPathComponent(id)
        let files = ["storage.db", "storage.db-wal", "storage.db-shm"].map { data.appendingPathComponent($0).path }
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        try host.remove(id)
        #expect(!FileManager.default.fileExists(atPath: data.path))
        try store.install(TestGuest.folder)
        #expect(try storage.read(["a"]).isEmpty)
    }
}
