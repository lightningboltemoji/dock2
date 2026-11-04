import Dock2Core

/// What the host holds open for each plugin — a timer, an answer it waits on, a subscription, a WebSocket, a
/// watch, a connection, a process — under the capability that allowed it. Revoking a capability ends what it
/// allowed; stopping the plugin ends everything. An answer is delivered only while its resource is held.
@MainActor
final class PluginResources {
    enum Kind: String, Sendable {
        case timer, request, subscription, webSocket, watch, connection, process
    }

    struct Key: Hashable, Sendable {
        let kind: Kind
        let name: String

        init(_ kind: Kind, _ name: String) {
            self.kind = kind
            self.name = name
        }
    }

    private struct Entry {
        let capability: PluginCapability?
        let end: @MainActor () -> Void
    }

    private var held: [String: [Key: Entry]] = [:]

    /// Held until released or ended; one already under `key` is ended first, as a timer set again replaces it.
    func hold(_ key: Key, of plugin: String, under capability: PluginCapability?, end: @escaping @MainActor () -> Void = {}) {
        if let old = held[plugin]?.removeValue(forKey: key) { old.end() }
        held[plugin, default: [:]][key] = Entry(capability: capability, end: end)
    }

    /// It ended on its own — answered, exited, fired. False if it was not held: ended meanwhile, so its news is
    /// not the plugin's any more.
    @discardableResult
    func release(_ key: Key, of plugin: String) -> Bool {
        let released = held[plugin]?.removeValue(forKey: key) != nil
        if held[plugin]?.isEmpty == true { held[plugin] = nil }
        return released
    }

    func holds(_ key: Key, of plugin: String) -> Bool {
        held[plugin]?[key] != nil
    }

    /// The capability `key` is held under.
    func capability(of key: Key, of plugin: String) -> PluginCapability? {
        held[plugin]?[key]?.capability
    }

    /// The plugin let it go, or replaced it.
    func end(_ key: Key, of plugin: String) {
        guard let entry = held[plugin]?.removeValue(forKey: key) else { return }
        if held[plugin]?.isEmpty == true { held[plugin] = nil }
        entry.end()
    }

    /// The capability was revoked: what it allowed ends. Returns what ended.
    @discardableResult
    func end(under capability: PluginCapability, of plugin: String) -> [Key] {
        let keys = (held[plugin] ?? [:]).filter { $0.value.capability == capability }.keys.sorted { $0.name < $1.name }
        for key in keys { end(key, of: plugin) }
        return keys
    }

    /// The plugin stopped.
    func endAll(of plugin: String) {
        guard let entries = held.removeValue(forKey: plugin) else { return }
        for entry in entries.values { entry.end() }
    }

    func keys(_ kind: Kind, of plugin: String) -> [Key] {
        (held[plugin] ?? [:]).keys.filter { $0.kind == kind }
    }

    /// Nothing held open: the instance may unload.
    func isIdle(_ plugin: String) -> Bool {
        held[plugin]?.isEmpty ?? true
    }
}
