import Dock2Core
import Dock2Plugins
import Dock2System
import Foundation

/// `dock2 plugin …` ([packaging](product/plugins/packaging.md#installing)): what Settings → Plugins does, from a
/// terminal, a running dock2 told of each change. Installing prints the sheet's rows and asks once, unless told
/// `--yes`; what starts off stays off, for Settings to switch on.
@MainActor
struct PluginCommand {
    let usage: String
    /// The config file without a watcher: this process writes it and is gone.
    let store = PluginStore(settings: .standard(watch: false))

    func run(_ arguments: [String]) -> Int32 {
        defer { store.settings.flush() }
        let asking = !arguments.contains("--yes")
        let arguments = arguments.filter { $0 != "--yes" }
        switch (arguments.first, arguments.count) {
        case ("list", 1):
            for plugin in store.plugins {
                let state = store.isEnabled(plugin.id) ? "on" : "off"
                print("\(plugin.id)  \(plugin.manifest.name) \(plugin.manifest.version)  \(state)\(plugin.origin == .firstParty ? ", comes with dock2" : "")")
            }
            return 0
        case ("install", 2):
            return install(URL(fileURLWithPath: arguments[1]), asking: asking) == nil ? 1 : 0
        case ("dev", 2):
            return develop(URL(fileURLWithPath: arguments[1]), asking: asking)
        case ("remove", 2):
            return remove(arguments[1])
        default:
            note(usage)
            return 2
        }
    }

    /// The manifest installed, once the user agreed to what it reaches — or nil, said why. An update asks only
    /// about what it reaches beyond what was agreed to: reaching less needs no yes.
    private func install(_ folder: URL, asking: Bool) -> PluginManifest? {
        do {
            let manifest = try store.inspect(folder)
            let ask = store.ask(manifest, origin: .installed, purpose: .install(folder))
            if ask.asksAnything || store.agreed(manifest.id) == nil {
                let named = "\(manifest.name) \(manifest.version) (\(manifest.id))"
                print(ask.isUpdate ? "\(named) asks for more:" : "\(named), from \(folder.path), not from Dock2, asks to:")
                print(ask.rows.isEmpty ? "  nothing beyond its own storage" : ask.text(name: manifest.name))
                if asking {
                    print("Install it? [y/N] ", terminator: "")
                    guard readLine()?.lowercased().hasPrefix("y") == true else { return nil }
                }
            }
            try store.install(folder, decisions: ask.decisions)
            PluginStore.announceChange(manifest.id)
            print("installed \(manifest.id) \(manifest.version)")
            return manifest
        } catch {
            warn("not installed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Installed, then installed again whenever its manifest or module changes and has settled — a build
    /// is not caught half-written. Asks again only if what it reaches changed. What the running dock2 logs
    /// of it streams here meanwhile.
    private func develop(_ folder: URL, asking: Bool) -> Int32 {
        // Each line as it happens, though the output is a file or a pipe.
        setlinebuf(stdout)
        guard let first = install(folder, asking: asking) else { return 1 }
        print("watching \(folder.path); ⌃C stops, leaving it installed")
        let logs = Self.streamLogs(of: first.id)
        var installed = Self.stamp(folder, first), seen = installed
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = Self.stamp(folder, try? store.inspect(folder))
                defer { seen = now }
                guard now == seen, now != installed else { return }
                installed = now
                _ = install(folder, asking: asking)
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.run()
        logs?.terminate()
        return 0
    }

    /// The plugin's lines in the unified log — its own `log`, and dock2's about it — as they come.
    private static func streamLogs(of id: String) -> Process? {
        let stream = Process()
        stream.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        stream.arguments = ["stream", "--style", "compact", "--predicate",
                            "subsystem == \"\(Dock2Identity.bundleIdentifier)\" AND eventMessage BEGINSWITH \"plugin \(id)\""]
        do {
            try stream.run()
            return stream
        } catch {
            warn("its logs will not stream: \(error.localizedDescription)")
            return nil
        }
    }

    /// When the manifest and the module were last written.
    private static func stamp(_ folder: URL, _ manifest: PluginManifest?) -> [Date?] {
        ["manifest.json", manifest?.module ?? "plugin.wasm"].map {
            (try? folder.appendingPathComponent($0).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    private func remove(_ id: String) -> Int32 {
        guard let plugin = store.plugin(id) else {
            warn("no plugin \(id)")
            return 1
        }
        guard plugin.origin == .installed else {
            warn("\(plugin.manifest.name) comes with dock2: switch it off in Settings → Plugins instead")
            return 1
        }
        do {
            try store.remove(plugin.id)
            PluginStore.announceChange(plugin.id)
            print("removed \(plugin.id)")
            return 0
        } catch {
            warn("not removed: \(error.localizedDescription)")
            return 1
        }
    }
}
