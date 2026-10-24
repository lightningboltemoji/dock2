import Dock2TOML

/// Something wrong in the config file, and the line it is on.
public struct SettingsDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var description: String { "line \(line): \(message)" }
}

/// One change to the config file: a key set to a value, or taken out.
public struct SettingsEdit: Equatable, Sendable {
    public let path: [String]
    public let value: TOMLValue?

    public init(_ path: [String], _ value: TOMLValue?) {
        self.path = path
        self.value = value
    }
}

extension TOMLDocument {
    public mutating func apply(_ edit: SettingsEdit) throws {
        if let value = edit.value { try set(edit.path, to: value) } else { try remove(edit.path) }
    }
}

extension SettingKey {
    /// The edits that write `value`. A key that would only repeat its default is taken out instead: an absent
    /// key already means the default, and writing it down would pin it against the default ever changing.
    public func edits(for value: Value) -> [SettingsEdit] {
        guard case .file(let parts) = storage else { return [] }
        return parts.map { part in
            let written = part.write(value)
            return SettingsEdit(part.path, written.spelled == part.write(defaultValue).spelled ? nil : written)
        }
    }

    /// This setting as `table` writes it, its keys taken. One the file got wrong reads as `fallback`, and says so.
    func read(_ table: inout TOMLTable, fallback: Value) -> (Value, [SettingsDiagnostic]) {
        guard case .file(let parts) = storage else { return (fallback, []) }
        var value = defaultValue
        var problems: [SettingsDiagnostic] = []
        for part in parts {
            guard let written = table.take(part.path) else { continue }
            do {
                try part.read(written, &value)
            } catch {
                let message = (error as? SettingProblem)?.message ?? "\(error)"
                problems.append(SettingsDiagnostic(line: written.line, message: "'\(TOMLDocument.spell(part.path))' \(message)"))
            }
        }
        return problems.isEmpty ? (value, []) : (fallback, problems)
    }

    /// A value of this Mac's state as `state.json` keeps it.
    public func machineString(_ value: Value) -> String? {
        guard case .machine(let encode, _) = storage else { return nil }
        return encode(value)
    }

    public func machineValue(_ string: String) -> Value? {
        guard case .machine(_, let decode) = storage else { return nil }
        return decode(string)
    }
}

/// A setting with its type erased, for the walks over all of them.
public struct AnySetting: Sendable {
    public let name: String
    public let isMachine: Bool
    public let defaultValue: any Sendable
    /// The keys it is written under, for the example document.
    public let parts: [Part]
    let readFile: @Sendable (inout TOMLTable, (any Sendable)?) -> (any Sendable, [SettingsDiagnostic])
    let equal: @Sendable (any Sendable, any Sendable) -> Bool

    public struct Part: Sendable {
        public let path: [String]
        public let help: String
        public let legend: String?
        public let defaultValue: TOMLValue
        /// The part of a value of the setting's that this key writes.
        public let spell: @Sendable (any Sendable) -> TOMLValue
    }

    public init<Value>(_ key: SettingKey<Value>) {
        name = key.name
        isMachine = key.isMachine
        defaultValue = key.defaultValue
        if case .file(let parts) = key.storage {
            self.parts = parts.map { part in
                Part(path: part.path, help: part.help, legend: part.legend, defaultValue: part.write(key.defaultValue),
                     spell: { part.write($0 as? Value ?? key.defaultValue) })
            }
        } else {
            self.parts = []
        }
        readFile = { table, fallback in key.read(&table, fallback: fallback as? Value ?? key.defaultValue) }
        equal = { ($0 as? Value) == ($1 as? Value) }
    }

    /// Whether two of its values are the same value.
    public func isEqual(_ a: any Sendable, _ b: any Sendable) -> Bool {
        equal(a, b)
    }
}

/// What a config file says: every setting's value, what it got wrong, and the open table of plugins.
public struct SettingsReading: Sendable {
    public var values: [String: any Sendable]
    public var diagnostics: [SettingsDiagnostic]
    /// `[plugins]`, by plugin id: read against each installed plugin's manifest, so not here.
    public var plugins: TOMLTable

    public subscript<Value>(key: SettingKey<Value>) -> Value {
        values[key.name] as? Value ?? key.defaultValue
    }
}

extension Settings {
    /// Every setting, in the order the file and the window show them.
    public static let all: [AnySetting] = [
        AnySetting(onboarded), AnySetting(openAtLogin), AnySetting(summon),
        AnySetting(dockStyle), AnySetting(tileSize), AnySetting(autohide), AnySetting(revealDelay), AnySetting(hideDelay),
        AnySetting(slideTimeModifier), AnySetting(typeToSearch), AnySetting(numberBadges), AnySetting(bounce),
        AnySetting(showRunning), AnySetting(minimizeToApp), AnySetting(pinned),
        AnySetting(fieldForm), AnySetting(searchSourcesOff), AnySetting(searchFirst), AnySetting(searchExcluded),
        AnySetting(pluginOrder),
        AnySetting(clipboardHistory), AnySetting(clipboardRetentionDays), AnySetting(clipboardIgnored),
        AnySetting(clipboardShortcut), AnySetting(clipboardPastes), AnySetting(askedToPaste), AnySetting(pluginChoicesImported),
        AnySetting(fileAccess), AnySetting(showInFinderTakeover), AnySetting(foldersFirst), AnySetting(showHiddenFiles),
        AnySetting(previewColumn), AnySetting(finderIcon),
    ]

    /// The open table each plugin's choices are written under.
    public static let pluginsTable = ["plugins"]

    /// What `table` says. A value it got wrong reads as `previous` holds it — what dock2 had before a
    /// reload — or its default, and every mistake is a diagnostic rather than a refusal of the whole file.
    public static func read(_ table: TOMLTable, previous: [String: any Sendable] = [:]) -> SettingsReading {
        var rest = table
        var values: [String: any Sendable] = [:]
        var diagnostics: [SettingsDiagnostic] = []
        for setting in all where !setting.isMachine {
            let (value, problems) = setting.readFile(&rest, previous[setting.name])
            values[setting.name] = value
            diagnostics += problems
        }
        for setting in all {
            for part in setting.parts { rest.acceptTable(Array(part.path.dropLast())) }
        }
        let plugins = rest.takeTable(pluginsTable) ?? .empty
        diagnostics += rest.leftovers.map { SettingsDiagnostic(line: $0.line, message: "unknown setting '\($0.key)'") }
        return SettingsReading(values: values, diagnostics: diagnostics.sorted { $0.line < $1.line }, plugins: plugins)
    }
}
