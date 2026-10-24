import Dock2Core
import Dock2System
import Dock2TOML
import Foundation

/// `dock2 config …`: the config file, read and written here rather than by asking a running dock2, which
/// hears the change as it hears an editor's.
@MainActor
struct ConfigCommand {
    let usage: String

    func run(_ arguments: [String]) -> Int32 {
        switch (arguments.first, arguments.count) {
        case ("path", 1):
            print(SettingsFile.standard.url.path)
            return 0
        case ("open", 1):
            SettingsFile.standard.open()
            return 0
        case ("check", 1):
            return check()
        case ("explain", 1):
            return explain()
        case ("get", 2):
            return get(arguments[1])
        case ("set", 3):
            return set(arguments[1], arguments[2])
        default:
            note(usage)
            return 2
        }
    }

    private var store: SettingsStore { .standard(watch: false) }

    /// Every mistake, `path:line: message`, as an editor's error list reads them; non-zero if there are any.
    private func check() -> Int32 {
        let store = store
        let path = store.file.url.path
        if let unreadable = store.unreadable {
            print("\(path):\(unreadable.line): \(unreadable.message)")
            return 1
        }
        for diagnostic in store.diagnostics { print("\(path):\(diagnostic.line): \(diagnostic.message)") }
        return store.diagnostics.isEmpty ? 0 : 1
    }

    /// Every setting: what it is now, what it does, what it may be, and its default.
    private func explain() -> Int32 {
        let store = store
        let reading = Settings.read(store.table(at: []) ?? .empty)
        for setting in Settings.all {
            for part in setting.parts {
                let value = reading.values[setting.name].map(part.spell) ?? part.defaultValue
                print("\(TOMLDocument.spell(part.path)) = \(value.spelled)")
                let notes = [part.help, part.legend, "Default: \(part.defaultValue.spelled)."].compactMap { $0 }
                print("    " + notes.joined(separator: " ") + "\n")
            }
        }
        return 0
    }

    private func part(_ key: String) -> (AnySetting, AnySetting.Part)? {
        for setting in Settings.all {
            if let part = setting.parts.first(where: { TOMLDocument.spell($0.path) == key }) { return (setting, part) }
        }
        warn("no setting \(key); `dock2 config explain` lists them")
        return nil
    }

    private func get(_ key: String) -> Int32 {
        guard let (setting, part) = part(key) else { return 1 }
        let store = store
        let reading = Settings.read(store.table(at: []) ?? .empty)
        print((reading.values[setting.name].map(part.spell) ?? part.defaultValue).spelled)
        return 0
    }

    /// `value` as TOML — `64`, `true`, `["a", "b"]` — or, failing that, a word: `snow-leopard`.
    private func set(_ key: String, _ text: String) -> Int32 {
        guard let (_, part) = part(key) else { return 1 }
        let value = (try? TOMLTable.parse("v = " + text))?.value(at: ["v"]) ?? .string(text)
        let line = "[" + TOMLDocument.spell(Array(part.path.dropLast())) + "]\n" + TOMLTable.spell(key: part.path.last ?? "") + " = " + value.spelled
        if let problem = (try? TOMLTable.parse(line)).map({ Settings.read($0).diagnostics })?.first {
            warn("not set: \(problem.message)")
            return 1
        }
        let store = store
        if let unreadable = store.unreadable {
            warn("not set: \(store.file.url.path):\(unreadable.line): \(unreadable.message)")
            return 1
        }
        store.write([SettingsEdit(part.path, value.spelled == part.defaultValue.spelled ? nil : value)], describing: key)
        store.flush()
        return 0
    }
}
