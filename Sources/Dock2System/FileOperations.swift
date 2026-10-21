import Dock2Core
import Foundation

/// A name taken where an item is going: the operation waits for the user.
public struct ConflictQuestion: Sendable {
    public let item: URL
    public let existing: URL
    /// More items are coming, so "for all" is worth offering.
    public let more: Bool
}

public struct ConflictAnswer: Sendable, Equatable {
    public enum Choice: Sendable { case replace, keepBoth, skip }
    public var choice: Choice
    public var forAll: Bool

    public init(_ choice: Choice, forAll: Bool = false) {
        self.choice = choice
        self.forAll = forAll
    }
}

/// An item's journey: where it was and where it went — and, when it replaced something, where in the
/// Trash that went, for undo to put back.
public struct FileMove: Sendable, Equatable {
    public let from: URL
    public let to: URL
    public var displaced: URL?

    init(from: URL, to: URL, displaced: URL? = nil) {
        self.from = from
        self.to = to
        self.displaced = displaced
    }
}

/// A job that failed partway: what it did before is still recorded, and selected.
struct Interrupted: LocalizedError {
    let record: FileRecord?
    let made: [URL]
    let error: Error

    var errorDescription: String? { error.localizedDescription }

    /// Runs `work`; if it throws once something was done, the error carries what was.
    static func keeping(_ record: () -> FileRecord?, made: () -> [URL], _ work: () throws -> Void) throws {
        do {
            try work()
        } catch {
            guard let record = record() else { throw error }
            throw Interrupted(record: record, made: made(), error: error)
        }
    }
}

/// What an operation did, kept for undo and redo for as long as dock2 runs.
public enum FileRecord: Sendable, Equatable {
    /// Undone by trashing the copies.
    case copied([FileMove])
    case moved([FileMove])
    /// To where each went in the Trash, to be put back from.
    case trashed([FileMove])
    /// A new folder: undone only while it is still empty.
    case created(URL)
}

/// An operation running or waiting.
@MainActor
public final class FileJob: Identifiable {
    public let id = UUID()
    /// "Copying 3 items to Desktop".
    public let title: String
    public let destination: URL?
    public let progress: Progress
    public let started = Date()

    init(title: String, destination: URL?, units: Int64 = 1) {
        self.title = title
        self.destination = destination
        progress = Progress(totalUnitCount: max(units, 1))
    }
}

/// What Files does to files ([operations](product/files/operations.md)): one at a time on a queue of
/// their own, each with progress and a way to stop it, asking about a name already taken, recorded for undo.
/// Copies clone on one APFS volume, written under a hidden name until whole.
@MainActor
public final class FileOperations {
    public private(set) var jobs: [FileJob] = []
    /// Told when the jobs change, or the running one's progress does: Files' banner, the Finder tile.
    private var observers: [@MainActor () -> Void] = []
    /// A conflict to put to the user; the answer may come at any time.
    public var ask: ((ConflictQuestion, @escaping @Sendable (ConflictAnswer) -> Void) -> Void)?
    /// What could not be done, and to which item.
    public var onError: ((FileProblem) -> Void)?

    private var undoStack: [FileRecord] = []
    private var redoStack: [FileRecord] = []
    private let queue = DispatchQueue(label: "zip.tanner.dock2.file-operations", qos: .userInitiated)
    private let trashing: @Sendable (URL) throws -> URL

    /// `trashing` moves an item to the Trash and says where it went; tests give their own.
    public init(trashing: @escaping @Sendable (URL) throws -> URL = FileOperations.moveToTrash) {
        self.trashing = trashing
    }

    nonisolated public static func moveToTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    public func observe(_ observer: @escaping @MainActor () -> Void) {
        observers.append(observer)
    }

    private func changed() {
        for observer in observers { observer() }
    }

    /// The jobs running for at least `age` seconds, their progress together; nil when there are none.
    public func fraction(olderThan age: TimeInterval) -> Double? {
        let due = jobs.filter { Date().timeIntervalSince($0.started) >= age }
        guard !due.isEmpty else { return nil }
        let total = due.map(\.progress.totalUnitCount).reduce(0, +)
        let done = due.map(\.progress.completedUnitCount).reduce(0, +)
        return total > 0 ? Double(done) / Double(total) : 0
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Operations

    /// Copies `items` into `folder`; `done` hears what was made, to select it.
    public func copy(_ items: [URL], to folder: URL, done: (@MainActor ([URL]) -> Void)? = nil) {
        transfer(items, to: folder, moving: false, done: done)
    }

    /// Moves `items` into `folder`: a rename on one volume, a copy and then removal across.
    public func move(_ items: [URL], to folder: URL, done: (@MainActor ([URL]) -> Void)? = nil) {
        transfer(items, to: folder, moving: true, done: done)
    }

    /// ⌘D: a copy of each beside it, named as Finder names one.
    public func duplicate(_ items: [URL], done: (@MainActor ([URL]) -> Void)? = nil) {
        let job = FileJob(title: "Duplicating \(Self.describe(items))", destination: nil)
        run(job, done: done) { worker in
            worker.progress.totalUnitCount = max(Worker.size(of: items), 1)
            var made: [FileMove] = []
            try Interrupted.keeping({ made.isEmpty ? nil : .copied(made) }, made: { made.map(\.to) }) {
                for item in items {
                    let target = Worker.duplicateName(of: item, in: item.parentFolder)
                    guard try ItemError.about(item, { try worker.copy(item, to: target) }) != nil else { break }
                    made.append(FileMove(from: item, to: target))
                }
            }
            return (made.isEmpty ? nil : .copied(made), made.map(\.to))
        }
    }

    /// ⇧⌘N: "untitled folder" in `folder`, at once.
    public func newFolder(in folder: URL) throws -> URL {
        let name = CopyNaming.newFolder { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        record(.created(url))
        return url
    }

    /// A new name, in the same folder.
    public func rename(_ url: URL, to name: String) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") || url.lastPathComponent.hasPrefix(".") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        guard target != url else { return url }
        // A change of case alone is the same name to the file system, and is no conflict.
        if FileManager.default.fileExists(atPath: target.path), target.path.lowercased() != url.path.lowercased() {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.moveItem(at: url, to: target)
        record(.moved([FileMove(from: url, to: target)]))
        return target
    }

    /// ⌘⌫: to the system's Trash.
    public func trash(_ items: [URL], done: (@MainActor ([URL]) -> Void)? = nil) {
        let trashing = self.trashing
        let job = FileJob(title: "Moving \(Self.describe(items)) to the Trash", destination: nil, units: Int64(items.count))
        run(job, done: done) { worker in
            var moves: [FileMove] = []
            try Interrupted.keeping({ moves.isEmpty ? nil : .trashed(moves) }, made: { [] }) {
                for item in items {
                    try worker.check()
                    moves.append(FileMove(from: item, to: try ItemError.about(item) { try trashing(item) }))
                    worker.advance(1)
                }
            }
            return (moves.isEmpty ? nil : .trashed(moves), [])
        }
    }

    /// ⌥⌘⌫, once confirmed: gone, with no undo.
    public func delete(_ items: [URL], done: (@MainActor ([URL]) -> Void)? = nil) {
        let job = FileJob(title: "Deleting \(Self.describe(items))", destination: nil, units: Int64(items.count))
        run(job, done: done) { worker in
            for item in items {
                try worker.check()
                try ItemError.about(item) { try FileManager.default.removeItem(at: item) }
                worker.advance(1)
            }
            return (nil, [])
        }
    }

    /// ⌘.: the running job stops, leaving nothing half-made.
    public func cancel() {
        jobs.first?.progress.cancel()
    }

    // MARK: - Undo

    /// ⌘Z. `done` hears what to select: what came back.
    public func undo(done: (@MainActor ([URL]) -> Void)? = nil) {
        guard let last = undoStack.popLast() else { return }
        replay(last, backwards: true, done: done)
    }

    /// ⇧⌘Z.
    public func redo(done: (@MainActor ([URL]) -> Void)? = nil) {
        guard let last = redoStack.popLast() else { return }
        replay(last, backwards: false, done: done)
    }

    private func replay(_ record: FileRecord, backwards: Bool, done: (@MainActor ([URL]) -> Void)?) {
        let trashing = self.trashing
        let job = FileJob(title: backwards ? "Undoing" : "Redoing", destination: nil, units: 1)
        run(job, recordsAs: backwards ? .redo : .undo, done: done) { worker in
            switch (record, backwards) {
            case (.copied(let moves), true):
                for move in moves.reversed() { try worker.takeBack(move, moved: false, trashing: trashing) }
                return (.copied(moves), moves.map(\.from))
            case (.copied(let moves), false):
                let again = try moves.compactMap { try worker.put($0.from, at: $0.to, moving: false, replacing: $0.displaced != nil, trashing: trashing) }
                return (.copied(again), again.map(\.to))
            case (.moved(let moves), true):
                for move in moves.reversed() { try worker.takeBack(move, moved: true, trashing: trashing) }
                return (.moved(moves), moves.map(\.from))
            case (.moved(let moves), false):
                let again = try moves.compactMap { try worker.put($0.from, at: $0.to, moving: true, replacing: $0.displaced != nil, trashing: trashing) }
                return (.moved(again), again.map(\.to))
            case (.trashed(let moves), true):
                for move in moves { _ = try worker.put(move.to, at: move.from, moving: true, replacing: false, trashing: trashing) }
                return (.trashed(moves), moves.map(\.from))
            case (.trashed(let moves), false):
                let again = try moves.map { FileMove(from: $0.from, to: try trashing($0.from)) }
                return (.trashed(again), [])
            case (.created(let url), true):
                guard (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty == true else {
                    throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” is no longer empty."])
                }
                try FileManager.default.removeItem(at: url)
                return (.created(url), [])
            case (.created(let url), false):
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return (.created(url), [url])
            }
        }
    }

    private func record(_ record: FileRecord) {
        undoStack.append(record)
        redoStack.removeAll()
    }

    // MARK: - Running

    private enum Stack { case undo, redo, fresh }

    private func transfer(_ items: [URL], to folder: URL, moving: Bool, done: (@MainActor ([URL]) -> Void)?) {
        let verb = moving ? "Moving" : "Copying"
        let job = FileJob(title: "\(verb) \(Self.describe(items)) to \(folder.lastPathComponent)", destination: folder)
        let trashing = self.trashing
        let folder = folder.canonical
        run(job, done: done) { worker in
            worker.progress.totalUnitCount = max(Worker.size(of: items), 1)
            var made: [FileMove] = []
            var standing: ConflictAnswer?
            let record = { made.isEmpty ? nil : moving ? FileRecord.moved(made) : .copied(made) }
            try Interrupted.keeping(record, made: { made.map(\.to) }) {
                for (index, item) in items.map(\.canonical).enumerated() {
                    // Into itself: nothing to do.
                    if folder.path.hasPrefix(item.path + "/") || folder.path == item.path { continue }
                    var target = folder.appendingPathComponent(item.lastPathComponent)
                    var replacing = false
                    if item.parentFolder == folder {
                        // Where it already is: a move does nothing; a copy is a duplicate, as Finder makes one.
                        if moving { continue }
                        target = Worker.duplicateName(of: item, in: folder)
                    } else if FileManager.default.fileExists(atPath: target.path) {
                        let answer = standing ?? worker.ask(ConflictQuestion(item: item, existing: target, more: index < items.count - 1))
                        if answer.forAll { standing = answer }
                        switch answer.choice {
                        case .skip: continue
                        case .replace: replacing = true
                        case .keepBoth:
                            let name = CopyNaming.keepBoth(item.lastPathComponent, isFolder: Worker.isFolder(item)) {
                                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
                            }
                            target = folder.appendingPathComponent(name)
                        }
                    }
                    guard let move = try ItemError.about(item, { try worker.put(item, at: target, moving: moving, replacing: replacing, trashing: trashing) })
                    else { break }
                    made.append(move)
                }
            }
            return (record(), made.map(\.to))
        }
    }

    private func run(_ job: FileJob, recordsAs stack: Stack = .fresh, done: (@MainActor ([URL]) -> Void)?,
                     _ work: @escaping @Sendable (Worker) throws -> (FileRecord?, [URL])) {
        jobs.append(job)
        changed()
        let worker = Worker(progress: job.progress, asker: { [weak self] question, reply in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let ask = self?.ask { ask(question, reply) } else { reply(ConflictAnswer(.skip)) }
                }
            }
        }, changed: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.changed() } }
        })
        queue.async {
            let outcome = Result { try work(worker) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finish(job, outcome, stack: stack, done: done)
                }
            }
        }
    }

    private func finish(_ job: FileJob, _ outcome: Result<(FileRecord?, [URL]), Error>, stack: Stack,
                        done: (@MainActor ([URL]) -> Void)?) {
        jobs.removeAll { $0 === job }
        switch outcome {
        case .success(let (record, made)):
            if let record {
                switch stack {
                case .fresh: self.record(record)
                case .undo: undoStack.append(record)
                case .redo: redoStack.append(record)
                }
            }
            done?(made.map(\.canonical))
        case .failure(let error):
            let interrupted = error as? Interrupted
            if let record = interrupted?.record { self.record(record) }
            if !job.progress.isCancelled { onError?(FileProblem(interrupted?.error ?? error)) }
            done?((interrupted?.made ?? []).map(\.canonical))
        }
        changed()
    }

    private static func describe(_ items: [URL]) -> String {
        items.count == 1 ? "“\(items[0].lastPathComponent)”" : "\(items.count) items"
    }
}

/// The file system work of one job, on the operations' queue.
struct Worker: Sendable {
    let progress: Progress
    let asker: @Sendable (ConflictQuestion, @escaping @Sendable (ConflictAnswer) -> Void) -> Void
    let changed: @Sendable () -> Void

    func check() throws {
        if progress.isCancelled { throw CocoaError(.userCancelled) }
    }

    func advance(_ units: Int64) {
        progress.completedUnitCount += units
        changed()
    }

    /// Asks on the main queue and waits for the answer: the queue holds one job at a time anyway.
    func ask(_ question: ConflictQuestion) -> ConflictAnswer {
        let semaphore = DispatchSemaphore(value: 0)
        let answer = Box(ConflictAnswer(.skip))
        asker(question) { reply in
            answer.value = reply
            semaphore.signal()
        }
        semaphore.wait()
        return answer.value
    }

    /// `item` to `target`, moved or copied whole. Replacing, what is there goes to the Trash once the newcomer
    /// is ready — kept in the move for undo — or is deleted where there is no Trash. Nil when cancelled.
    func put(_ item: URL, at target: URL, moving: Bool, replacing: Bool, trashing: (URL) throws -> URL) throws -> FileMove? {
        try check()
        if replacing, item.path.hasPrefix(target.path + "/") {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSLocalizedDescriptionKey: "“\(target.lastPathComponent)” could not be replaced: it holds “\(item.lastPathComponent)”.",
            ])
        }
        func makeRoom() throws -> URL? {
            guard replacing else { return nil }
            do { return try trashing(target) } catch {
                try FileManager.default.removeItem(at: target)
                return nil
            }
        }
        if moving, Worker.sameVolume(item, target.parentFolder) {
            let displaced = try makeRoom()
            do {
                try FileManager.default.moveItem(at: item, to: target)
            } catch {
                if let displaced { try? FileManager.default.moveItem(at: displaced, to: target) }
                throw error
            }
            advance(Worker.size(of: [target]))
            return FileMove(from: item, to: target, displaced: displaced)
        }
        guard let placed = try copy(item, to: target, makingRoom: makeRoom) else { return nil }
        if moving { try FileManager.default.removeItem(at: item) }
        return FileMove(from: item, to: target, displaced: placed.displaced)
    }

    /// Undoes `put`: a copy to the Trash, a move moved back; then what it replaced back from the Trash.
    func takeBack(_ move: FileMove, moved: Bool, trashing: (URL) throws -> URL) throws {
        try check()
        if moved {
            guard try put(move.to, at: move.from, moving: true, replacing: false, trashing: trashing) != nil else { throw CocoaError(.userCancelled) }
        } else {
            _ = try trashing(move.to)
        }
        if let displaced = move.displaced { try FileManager.default.moveItem(at: displaced, to: move.to) }
    }

    /// What was in the way of a copy, gone to the Trash; nil when nothing was, or there is no Trash.
    struct Placed {
        let displaced: URL?
    }

    /// Copies under a hidden name beside `target`, then puts it in place once `makingRoom` cleared the way.
    /// Nil, with nothing left behind, when cancelled; a file that cannot be read fails it all.
    @discardableResult
    func copy(_ source: URL, to target: URL, makingRoom: () throws -> URL? = { nil }) throws -> Placed? {
        try check()
        let partial = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).dock2-\(UUID().uuidString.prefix(8))")
        let context = CopyContext(progress: progress, base: progress.completedUnitCount, changed: changed)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let unmanaged = Unmanaged.passRetained(context)
        defer { unmanaged.release() }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), unmanaged.toOpaque())
        let callback: copyfile_callback_t = { what, stage, state, src, _, ctx in
            guard let ctx else { return COPYFILE_CONTINUE }
            let context = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
            if context.progress.isCancelled { return COPYFILE_QUIT }
            // Carrying on past an error would skip the file, and a move would then remove it with its source.
            if stage == COPYFILE_ERR {
                context.failure = (errno, src.map { String(cString: $0) })
                return COPYFILE_QUIT
            }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                context.update(file: Int64(copied))
            } else if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_FINISH {
                // A clone copies no data and reports none: the file's size stands in for it.
                var info = stat()
                let size = src.map { lstat($0, &info) == 0 ? Int64(info.st_size) : 0 } ?? 0
                context.fileDone(size: size)
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_EXCL)
        let result = copyfile(source.path, partial.path, state, flags)
        if result != 0 || context.failure != nil || progress.isCancelled {
            let (code, file) = context.failure ?? (errno, nil)
            try? FileManager.default.removeItem(at: partial)
            if progress.isCancelled, context.failure == nil { return nil }
            let name = file.map { URL(fileURLWithPath: $0).lastPathComponent } ?? source.lastPathComponent
            let what = code == EACCES || code == EPERM ? "can't be read" : "couldn't be copied: \(String(cString: strerror(code)).lowercased())"
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO, userInfo: [NSLocalizedDescriptionKey: "“\(name)” \(what)."])
        }
        let displaced: URL?
        do {
            displaced = try makingRoom()
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        do {
            try FileManager.default.moveItem(at: partial, to: target)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            if let displaced { try? FileManager.default.moveItem(at: displaced, to: target) }
            throw error
        }
        progress.completedUnitCount = context.base + Worker.size(of: [source])
        changed()
        return Placed(displaced: displaced)
    }

    /// "one copy.txt" beside "one.txt", as ⌘D names it.
    static func duplicateName(of item: URL, in folder: URL) -> URL {
        let name = CopyNaming.duplicate(item.lastPathComponent, isFolder: isFolder(item)) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        return folder.appendingPathComponent(name)
    }

    static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let first = try? a.resourceValues(forKeys: key).volumeIdentifier,
              let second = try? b.resourceValues(forKeys: key).volumeIdentifier else { return false }
        return first.isEqual(second)
    }

    /// Bytes, for progress: a folder's every file.
    static func size(of items: [URL]) -> Int64 {
        var total: Int64 = 0
        for item in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey])
            if values?.isDirectory == true {
                let files = FileManager.default.enumerator(at: item, includingPropertiesForKeys: [.fileSizeKey])
                while let file = files?.nextObject() as? URL {
                    total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            } else {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}

/// What copyfile's callback needs: the bytes of the files finished, and of the one in hand.
private final class CopyContext: @unchecked Sendable {
    let progress: Progress
    let base: Int64
    let changed: @Sendable () -> Void
    /// The errno and the file copyfile stopped on.
    var failure: (Int32, String?)?
    private var finished: Int64 = 0
    private var current: Int64 = 0
    private var lastReport = Date.distantPast

    init(progress: Progress, base: Int64, changed: @escaping @Sendable () -> Void) {
        self.progress = progress
        self.base = base
        self.changed = changed
    }

    func update(file copied: Int64) {
        current = copied
        report()
    }

    func fileDone(size: Int64) {
        finished += max(current, size)
        current = 0
        report()
    }

    private func report() {
        progress.completedUnitCount = min(progress.totalUnitCount, base + finished + current)
        // Ten times a second is as often as anyone can see.
        guard Date().timeIntervalSince(lastReport) > 0.1 else { return }
        lastReport = Date()
        changed()
    }
}

/// A value handed between threads under a lock.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Reads and changes the value under one lock: a check and a set no other thread comes between.
    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&stored) }
    }
}
