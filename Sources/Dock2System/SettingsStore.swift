import Dock2Core
import Dock2TOML
import Foundation
import Observation

/// dock2's settings: the config file, read as it changes and written back one value at a time, keeping
/// everything else in it as the person wrote it; and this Mac's own state. Reads fall back to each key's
/// default; a change — from dock2, an editor or another process — reaches every observer of its key.
@MainActor
@Observable
public final class SettingsStore {
    /// Bumped on every change, so a view reading through the store redraws.
    public private(set) var revision = 0
    /// What the file says that dock2 can't use, line by line. Each such key reads as its default.
    public private(set) var diagnostics: [SettingsDiagnostic] = []
    /// Why the file can't be read at all. Meanwhile dock2 runs on the last text that could be, and refuses
    /// to write, since it can't splice text whose meaning it doesn't know.
    public private(set) var unreadable: SettingsDiagnostic?

    public let file: SettingsFile
    /// The file stopped being readable: the caller says so where the person is looking.
    @ObservationIgnored public var onUnreadable: ((SettingsDiagnostic) -> Void)?
    /// A write refused because the file can't be read.
    @ObservationIgnored public var onRefused: ((SettingsDiagnostic) -> Void)?

    /// The file as last read or written, and the same with the edits not yet written applied.
    @ObservationIgnored private var fileDocument: TOMLDocument
    @ObservationIgnored private var document: TOMLDocument
    /// The file's text as last read or written — nil while there is none — which is how an edit by someone
    /// else is told from dock2's own write coming back.
    @ObservationIgnored private var lastText: String?
    @ObservationIgnored private var reading: SettingsReading
    @ObservationIgnored private var pending: [SettingsEdit] = []
    @ObservationIgnored private var machine: [String: String]
    @ObservationIgnored private var observers: [String: [Int: @MainActor () -> Void]] = [:]
    @ObservationIgnored private var nextObserver = 0
    @ObservationIgnored private var watcher: SettingsWatcher?
    @ObservationIgnored private var writeScheduled = false
    @ObservationIgnored private var reloadScheduled = false

    /// Edits are written this long after the first of them, so a slider dragged writes the file once.
    static let writeDelay: TimeInterval = 0.25
    /// A burst of file events is read once, this long after the first.
    static let reloadDelay: TimeInterval = 0.08

    public init(file: SettingsFile = .standard, watch: Bool = true) {
        self.file = file
        let text: String?
        var unreadable: SettingsDiagnostic?
        do {
            text = try file.read()
        } catch {
            text = nil
            unreadable = SettingsDiagnostic(line: 0, message: error.localizedDescription)
        }
        var parsed: TOMLDocument?
        if unreadable == nil {
            do {
                parsed = try TOMLDocument(text ?? Settings.starter)
                if let text { file.keepLastGood(text) }
            } catch {
                unreadable = Self.diagnostic(error)
            }
        }
        let document = parsed ?? (try? TOMLDocument(file.readLastGood() ?? Settings.starter)) ?? Self.empty
        self.lastText = text
        self.unreadable = unreadable
        self.fileDocument = document
        self.document = document
        self.reading = Settings.read(document.table)
        self.diagnostics = reading.diagnostics
        self.machine = file.machine.load() ?? [:]
        if let unreadable { warn("\(file.url.path):\(unreadable.line): \(unreadable.message); using the last settings that could be read") }
        for diagnostic in diagnostics { warn("\(file.url.path):\(diagnostic.line): \(diagnostic.message)") }
        if watch {
            try? FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            watcher = SettingsWatcher([file.url, file.target]) { [weak self] in self?.fileChanged() }
        }
    }

    private static let empty = try! TOMLDocument("")

    public subscript<Value>(key: SettingKey<Value>) -> Value {
        get {
            _ = revision
            if key.isMachine { return machine[key.name].flatMap(key.machineValue) ?? key.defaultValue }
            return reading[key]
        }
        set {
            if key.isMachine {
                guard let string = key.machineString(newValue), machine[key.name] != string else { return }
                machine[key.name] = string
                file.machine.save(machine)
                changed([key.name])
            } else {
                write(key.edits(for: newValue), describing: key.name)
            }
        }
    }

    /// Whether the config file writes `key`, rather than leaving it at its default.
    public func isWritten<Value>(_ key: SettingKey<Value>) -> Bool {
        _ = revision
        return key.paths.contains { document.table.value(at: $0) != nil }
    }

    // MARK: Open tables

    /// The table at `path` as the file now says it, `[plugins]` among them: keys the schema doesn't name.
    public func table(at path: [String]) -> TOMLTable? {
        _ = revision
        return document.table.table(at: path)
    }

    /// Writes keys the schema doesn't name, in an open table.
    public func write(_ edits: [SettingsEdit], describing what: String) {
        if let unreadable {
            onRefused?(unreadable)
            return
        }
        var edited = document
        do {
            for edit in edits { try edited.apply(edit) }
        } catch {
            warn("could not write \(what) to \(file.url.path): \(Self.diagnostic(error).message)")
            return
        }
        guard edited.rendered != document.rendered else { return }
        document = edited
        pending += edits
        take(Settings.read(document.table, previous: reading.values))
        scheduleWrite()
    }

    // MARK: Observing

    /// Calls `handler` with the new value whenever the key's value changes, until the returned token is
    /// released. Called on the main queue after the change, never during it.
    public func observe<Value>(_ key: SettingKey<Value>, _ handler: @escaping @MainActor (Value) -> Void) -> SettingsObservation {
        var last = self[key]
        return observe(name: key.name) { [weak self] in
            guard let self else { return }
            let value = self[key]
            guard value != last else { return }
            last = value
            handler(value)
        }
    }

    /// Calls `handler` whenever an open table changes, `[plugins]` among them.
    public func observeTables(_ handler: @escaping @MainActor () -> Void) -> SettingsObservation {
        observe(name: Self.tablesName, handler)
    }

    private static let tablesName = "\u{0}tables"

    private func observe(name: String, _ handler: @escaping @MainActor () -> Void) -> SettingsObservation {
        nextObserver += 1
        let id = nextObserver
        observers[name, default: [:]][id] = handler
        return SettingsObservation { [weak self] in self?.observers[name]?[id] = nil }
    }

    /// Takes a new reading, telling each observer whose key it changed.
    private func take(_ next: SettingsReading) {
        let previous = reading
        reading = next
        if diagnostics != next.diagnostics { diagnostics = next.diagnostics }
        var names = Settings.all.filter { setting in
            !setting.isMachine && previous.values[setting.name].map { old in next.values[setting.name].map { !setting.isEqual(old, $0) } ?? true } ?? true
        }.map(\.name)
        if previous.plugins.spelled != next.plugins.spelled { names.append(Self.tablesName) }
        changed(names)
    }

    private func changed(_ names: [String]) {
        revision += 1
        for name in names {
            for handler in (observers[name] ?? [:]).values {
                DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
            }
        }
    }

    // MARK: The file

    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDelay) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Writes what isn't written yet, now: before quitting, and in tests. The file is read again first, under
    /// the lock, and edits made by anyone else since are kept — dock2's own are applied over them.
    public func flush() {
        writeScheduled = false
        guard !pending.isEmpty else { return }
        file.withLock {
            let disk: String?
            do {
                disk = try file.read()
            } catch {
                warn("could not read \(file.url.path) to write it: \(error.localizedDescription)")
                return
            }
            if disk != lastText { rebase(onto: disk) }
            guard unreadable == nil, !pending.isEmpty else { return }
            let text = document.rendered
            do {
                try file.write(text)
            } catch {
                warn("could not write \(file.url.path): \(error.localizedDescription)")
                return
            }
            lastText = text
            fileDocument = document
            pending = []
            file.keepLastGood(text)
        }
    }

    private func fileChanged() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reloadDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadScheduled = false
                self?.reload()
            }
        }
    }

    /// Reads the file again if it changed; dock2's own write, coming back, did not.
    public func reload() {
        let disk: String?
        do {
            disk = try file.read()
        } catch {
            warn("could not read \(file.url.path): \(error.localizedDescription)")
            return
        }
        guard disk != lastText else { return }
        rebase(onto: disk)
    }

    /// Takes `disk` as the file, with the edits not yet written applied over it. One that no longer applies
    /// is dropped. Text that can't be read changes nothing but `unreadable`, and drops the edits waiting on it.
    private func rebase(onto disk: String?) {
        lastText = disk
        let parsed: TOMLDocument
        do {
            parsed = try TOMLDocument(disk ?? Settings.starter)
        } catch {
            let problem = Self.diagnostic(error)
            if unreadable != problem {
                unreadable = problem
                onUnreadable?(problem)
            }
            warn("\(file.url.path):\(problem.line): \(problem.message); keeping the settings as they were")
            if !pending.isEmpty {
                pending = []
                document = fileDocument
                take(Settings.read(document.table, previous: reading.values))
            } else {
                revision += 1
            }
            return
        }
        if unreadable != nil { unreadable = nil }
        if let disk { file.keepLastGood(disk) }
        fileDocument = parsed
        var edited = parsed
        pending = pending.filter { (try? edited.apply($0)) != nil }
        document = edited
        let next = Settings.read(document.table, previous: reading.values)
        for diagnostic in next.diagnostics where !reading.diagnostics.contains(diagnostic) {
            warn("\(file.url.path):\(diagnostic.line): \(diagnostic.message)")
        }
        take(next)
        if !pending.isEmpty { scheduleWrite() }
    }

    private static func diagnostic(_ error: any Error) -> SettingsDiagnostic {
        guard let error = error as? TOMLError else { return SettingsDiagnostic(line: 0, message: "\(error)") }
        return SettingsDiagnostic(line: error.line, message: error.message)
    }
}

/// Keeps an observation alive; dropping it stops the calls.
@MainActor
public final class SettingsObservation {
    private let cancel: () -> Void

    init(cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    isolated deinit { cancel() }
}
