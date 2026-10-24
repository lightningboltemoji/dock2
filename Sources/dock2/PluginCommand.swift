import Dock2Core
import Dock2Plugins
import Dock2System
import Foundation

/// `dock2 plugin …` ([packaging](product/plugins/packaging.md#installing)): what Settings → Plugins does, from a
/// terminal, a running dock2 told of each change. Installing shows what the plugin would reach and asks,
/// unless told `--yes`.
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
                print("\(plugin.id)  \(plugin.manifest.name) \(plugin.manifest.version)  \(state)\(plugin.isFirstParty ? ", comes with dock2" : "")")
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

    /// The manifest installed, once the user agreed to what it reaches — or nil, said why.
    private func install(_ folder: URL, asking: Bool, agreed: PluginManifest? = nil) -> PluginManifest? {
        do {
            let manifest = try store.inspect(folder)
            let reaches = manifest.capabilities.map { $0.describe(hosts: manifest.hosts ?? []) }
            let agreedTo = agreed.map { before in before.capabilities.map { $0.describe(hosts: before.hosts ?? []) } }
            // Asked again only for something it did not reach before: reaching less needs no yes.
            let asks = agreedTo.map { !Set(reaches).isSubset(of: Set($0)) } ?? true
            if asks {
                print("\(manifest.name) \(manifest.version) (\(manifest.id)) would be able to:")
                print(reaches.isEmpty ? "  nothing beyond its own storage" : reaches.map { "  • " + $0 }.joined(separator: "\n"))
                if asking {
                    print("Install it? [y/N] ", terminator: "")
                    guard readLine()?.lowercased().hasPrefix("y") == true else { return nil }
                }
            }
            try store.install(folder)
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
        guard var agreed = install(folder, asking: asking) else { return 1 }
        print("watching \(folder.path); ⌃C stops, leaving it installed")
        let logs = Self.streamLogs(of: agreed.id)
        var installed = Self.stamp(folder, agreed), seen = installed
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = Self.stamp(folder, try? store.inspect(folder))
                defer { seen = now }
                guard now == seen, now != installed else { return }
                installed = now
                if let manifest = install(folder, asking: asking, agreed: agreed) { agreed = manifest }
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
        guard !plugin.isFirstParty else {
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
