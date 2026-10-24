import Dock2Core
import Dock2TOML
import Foundation

/// The settings dock2 kept in its defaults domain, `zip.tanner.dock2`, carried once into the config file and
/// this Mac's state — each only while it doesn't exist yet, so a file another Mac wrote always wins. The
/// domain is left as it was, for a build from before the file to find.
public enum SettingsImport {
    /// The domain: the standard defaults inside the bundle, named outright for a run from `.build`.
    public static var domain: UserDefaults {
        Bundle.main.bundleIdentifier == Dock2Identity.bundleIdentifier
            ? .standard : UserDefaults(suiteName: Dock2Identity.bundleIdentifier)!
    }

    /// Carries what `defaults` holds into `file`. `openAtLogin` is the login item's state, which the file
    /// now decides, so the first launch of a build that reads the file doesn't turn it off. Returns what it
    /// carried, by old name.
    @discardableResult
    public static func run(into file: SettingsFile, from defaults: UserDefaults = domain, openAtLogin: Bool? = nil) -> [String] {
        var carried: [String] = []
        if (try? file.read()) == .some(nil) {
            var document = try! TOMLDocument(Settings.starter)
            for entry in entries where !entry.isMachine {
                guard let object = defaults.object(forKey: entry.name), let edits = entry.edits(object) else { continue }
                for edit in edits { try? document.apply(edit) }
                carried.append(entry.name)
            }
            if openAtLogin == true {
                for edit in Settings.openAtLogin.edits(for: true) { try? document.apply(edit) }
                carried.append("open at login")
            }
            if document.rendered != Settings.starter {
                do {
                    try file.withLock { try file.write(document.rendered) }
                } catch {
                    warn("could not write \(file.url.path): \(error.localizedDescription)")
                    return []
                }
            }
        }
        if file.machine.load() == nil {
            var state: [String: String] = [:]
            for entry in entries where entry.isMachine {
                guard let object = defaults.object(forKey: entry.name), let value = entry.machine(object) else { continue }
                state[entry.name] = value
                carried.append(entry.name)
            }
            if !state.isEmpty { file.machine.save(state) }
        }
        if !carried.isEmpty { note("carried settings from the defaults domain into \(file.url.path): \(carried.joined(separator: ", "))") }
        return carried
    }

    /// Each old name, and the setting it became.
    private struct Entry {
        let name: String
        let isMachine: Bool
        let edits: (Any) -> [SettingsEdit]?
        let machine: (Any) -> String?

        init<Value: LegacyValue>(_ name: String, _ key: SettingKey<Value>) {
            self.name = name
            isMachine = key.isMachine
            edits = { object in
                guard let value = Value(propertyList: object) else {
                    warn("setting \(name) holds \(object), not a \(Value.self); not carried")
                    return nil
                }
                return key.edits(for: value)
            }
            machine = { object in Value(propertyList: object).flatMap(key.machineString) }
        }
    }

    private static var entries: [Entry] { [
        Entry("onboarded", Settings.onboarded), Entry("summonShortcut", Settings.summon),
        Entry("pinnedApps", Settings.pinned), Entry("tileSize", Settings.tileSize), Entry("dockStyle", Settings.dockStyle),
        Entry("autohide", Settings.autohide), Entry("revealDelay", Settings.revealDelay), Entry("hideDelay", Settings.hideDelay),
        Entry("slideTimeModifier", Settings.slideTimeModifier), Entry("typeToSearch", Settings.typeToSearch),
        Entry("numberBadges", Settings.numberBadges), Entry("bounceOnLaunch", Settings.bounce),
        Entry("showRunningApps", Settings.showRunning), Entry("minimizeIntoAppIcon", Settings.minimizeToApp),
        Entry("fieldForm", Settings.fieldForm), Entry("searchSourcesOff", Settings.searchSourcesOff),
        Entry("searchFirstFolders", Settings.searchFirst), Entry("searchExcludedFolders", Settings.searchExcluded),
        Entry("pluginResultsOrder", Settings.pluginOrder),
        Entry("clipboardHistory", Settings.clipboardHistory), Entry("clipboardRetentionDays", Settings.clipboardRetentionDays),
        Entry("clipboardIgnoredApps", Settings.clipboardIgnored), Entry("clipboardShortcut", Settings.clipboardShortcut),
        Entry("clipboardPastes", Settings.clipboardPastes), Entry("askedToPaste", Settings.askedToPaste),
        Entry("fileAccess", Settings.fileAccess), Entry("showInFinderOpensFiles", Settings.showInFinderTakeover),
        Entry("foldersFirst", Settings.foldersFirst), Entry("showHiddenFiles", Settings.showHiddenFiles),
        Entry("previewColumn", Settings.previewColumn), Entry("finderIcon", Settings.finderIcon),
    ] }
}

/// A value as the defaults domain held it: the property-list object, `Codable` ones as what they encode to.
protocol LegacyValue: Sendable, Equatable {
    init?(propertyList: Any)
}

extension Bool: LegacyValue {
    init?(propertyList: Any) {
        guard let number = propertyList as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        self = number.boolValue
    }
}

extension Int: LegacyValue {
    init?(propertyList: Any) {
        guard let number = propertyList as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        self = number.intValue
    }
}

extension Double: LegacyValue {
    init?(propertyList: Any) {
        guard let number = propertyList as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        self = number.doubleValue
    }
}

extension String: LegacyValue {
    init?(propertyList: Any) {
        guard let string = propertyList as? String else { return nil }
        self = string
    }
}

extension Array: LegacyValue where Element: LegacyValue {
    init?(propertyList: Any) {
        guard let array = propertyList as? [Any] else { return nil }
        let values = array.compactMap(Element.init(propertyList:))
        guard values.count == array.count else { return nil }
        self = values
    }
}

/// Stored as the property list its `Codable` form encodes to.
protocol LegacyCodable: LegacyValue, Codable {}

extension LegacyCodable {
    init?(propertyList: Any) {
        // A top-level scalar is not a property-list document; wrapping keeps every value decodable.
        guard let data = try? PropertyListSerialization.data(fromPropertyList: ["value": propertyList], format: .binary, options: 0),
              let wrapped = try? PropertyListDecoder().decode([String: Self].self, from: data),
              let value = wrapped["value"] else { return nil }
        self = value
    }
}

extension FileAccessChoice: LegacyCodable {}
extension Shortcut: LegacyCodable {}
extension AppRef: LegacyCodable {}
extension FinderIcon: LegacyCodable {}
extension FieldForm: LegacyCodable {}
extension DockStyle: LegacyCodable {}

extension SettingsStore {
    /// The config file at its standard place, the defaults domain carried into it first — once, by whichever
    /// process gets there first: the app, or `dock2 plugin` before the app has run.
    public static func standard(watch: Bool = true) -> SettingsStore {
        let file = SettingsFile.standard
        let bundled = Bundle.main.bundleIdentifier == Dock2Identity.bundleIdentifier
        SettingsImport.run(into: file, openAtLogin: bundled ? LoginItem.isEnabled : nil)
        return SettingsStore(file: file, watch: watch)
    }
}
