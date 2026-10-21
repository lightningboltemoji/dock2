import CryptoKit
import Dock2Core
import Dock2System
import Foundation

/// One plugin running ([runtime](product/plugins/runtime.md)): one event at a time on its own queue, each
/// within its budget. A failed call discards the instance for a fresh one at the next event; five in a
/// minute switch the plugin off. Stopped — off, or idle as the host judges it — it hears `stopped` and goes.
public final class PluginInstance: @unchecked Sendable {
    public let plugin: InstalledPlugin
    private let engine: PluginEngine
    private let cache: URL
    private let queue: DispatchQueue
    // Touched only on `queue`.
    private var module: PluginEngine.Module?
    private var instance: PluginEngine.Instance?
    private var failures: [Date] = []
    private var disabled = false

    /// Effects, on the main actor, in the order the plugin gave them, with the event they answer.
    public var onEffects: (@MainActor @Sendable ([PluginEffect], PluginEvent) -> Void)?
    /// Switched off, and why: on the main actor.
    public var onDisabled: (@MainActor @Sendable (String) -> Void)?

    public static let interactiveBudget: UInt32 = 50
    public static let backgroundBudget: UInt32 = 1000
    public static let memoryCap: UInt64 = 64 << 20
    static let failureLimit = 5
    static let failureWindow: TimeInterval = 60

    public init(plugin: InstalledPlugin, engine: PluginEngine, cache: URL) {
        self.plugin = plugin
        self.engine = engine
        self.cache = cache
        queue = DispatchQueue(label: "zip.tanner.dock2.plugin.\(plugin.id)", qos: .userInitiated)
    }

    /// Queues `event`; `settings` are what `started` carries if this event starts an instance.
    public func deliver(_ event: PluginEvent, settings: [String: String]) {
        queue.async { self.run(event, settings: settings) }
    }

    /// Waits for every event delivered so far: for tests.
    public func drain() {
        queue.sync {}
    }

    private func run(_ event: PluginEvent, settings: [String: String]) {
        guard !disabled else { return }
        do {
            if instance == nil {
                let module = try loadModule()
                instance = try engine.instantiate(module, memoryCap: Self.memoryCap) { [id = plugin.id] level, message in
                    let line = "plugin \(id): \(message)"
                    level >= 2 ? warn(line) : note(line)
                }
                call(.started(settings: settings), budget: Self.backgroundBudget)
                guard instance != nil else { return }
            }
        } catch {
            fail("could not start: \(error)")
            return
        }
        call(event, budget: event.isInteractive ? Self.interactiveBudget : Self.backgroundBudget)
    }

    private func call(_ event: PluginEvent, budget: UInt32) {
        guard let instance, let bytes = try? JSONEncoder().encode(event) else { return }
        switch instance.call(bytes, budget: budget) {
        case .effects(let data):
            let effects = Self.decode(data, plugin: plugin.id)
            guard !effects.isEmpty, let onEffects else { return }
            DispatchQueue.main.async { onEffects(effects, event) }
        case .deadline:
            fail("took longer than \(budget) ms over \(Self.name(event))")
        case .memory(let detail):
            fail("ran out of memory over \(Self.name(event)): \(Self.firstLine(detail))")
        case .trap(let detail):
            fail("trapped over \(Self.name(event)): \(Self.firstLine(detail))")
        case .error(let detail):
            fail("failed over \(Self.name(event)): \(Self.firstLine(detail))")
        }
    }

    /// Effects one by one: one this dock2 cannot read is logged and skipped, not the whole answer.
    static func decode(_ data: Data, plugin: String) -> [PluginEffect] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            warn("plugin \(plugin): effects that are not a JSON list")
            return []
        }
        return list.compactMap { item in
            guard let json = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            do {
                return try JSONDecoder().decode(PluginEffect.self, from: json)
            } catch {
                warn("plugin \(plugin): an effect dock2 cannot read: \(String(decoding: json.prefix(200), as: UTF8.self))")
                return nil
            }
        }
    }

    /// A trap's description goes on into a backtrace: its first line says what happened.
    private static func firstLine(_ detail: String) -> String {
        String(detail.split(separator: "\n").first ?? "").prefix(200).description
    }

    private static func name(_ event: PluginEvent) -> String {
        String(describing: event).prefix { $0 != "(" }.description
    }

    /// The instance goes; enough of these in a minute and the plugin goes too.
    private func fail(_ reason: String) {
        instance = nil
        warn("plugin \(plugin.id) \(reason)")
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < Self.failureWindow } + [now]
        guard failures.count >= Self.failureLimit else { return }
        disabled = true
        let because = "It failed \(failures.count) times in a minute: it \(reason)."
        if let onDisabled { DispatchQueue.main.async { onDisabled(because) } }
    }

    /// Stops now: switched off, or dock2 quitting.
    public func stop() {
        queue.async {
            if self.instance != nil { self.call(.stopped, budget: Self.backgroundBudget) }
            self.instance = nil
        }
    }

    /// Compiled once per build of the plugin and of the engine, then read back in a fraction of the time.
    private func loadModule() throws -> PluginEngine.Module {
        if let module { return module }
        let wasm = try Data(contentsOf: plugin.module)
        let key = SHA256.hash(data: wasm + Data(PluginEngine.version.utf8)).map { String(format: "%02x", $0) }.joined()
        let cached = cache.appendingPathComponent("\(plugin.id)-\(key.prefix(Self.hashLength)).cwasm")
        if let bytes = try? Data(contentsOf: cached), let module = try? engine.deserialize(bytes) {
            self.module = module
            return module
        }
        let module = try engine.compile(wasm)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? module.serialized().write(to: cached, options: .atomic)
        PluginStore.removeCompiled(of: plugin.id, in: cache, keeping: cached)
        self.module = module
        return module
    }

    /// Hex digits of the module's hash in its compiled file's name.
    static let hashLength = 24
}
