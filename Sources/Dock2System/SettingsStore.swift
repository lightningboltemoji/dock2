import Dock2Core
import Foundation

/// dock2's settings, in its own defaults domain. Reads fall back to each key's default; a change — from
/// dock2 or from `defaults write` — reaches every observer of its key on the main actor.
@MainActor
public final class SettingsStore {
    public let defaults: UserDefaults
    private var watchers: [String: KeyWatcher] = [:]

    public init(defaults: UserDefaults = SettingsStore.domain) {
        self.defaults = defaults
    }

    /// dock2's domain: the standard defaults inside the bundle, which `UserDefaults(suiteName:)` refuses to
    /// name for the app itself; named outright for a run from `.build`, which has no bundle.
    public static var domain: UserDefaults {
        Bundle.main.bundleIdentifier == Dock2Identity.bundleIdentifier
            ? .standard : UserDefaults(suiteName: Dock2Identity.bundleIdentifier)!
    }

    public subscript<Value>(key: SettingKey<Value>) -> Value {
        get {
            guard let object = defaults.object(forKey: key.name) else { return key.defaultValue }
            guard let value = Value(propertyList: object) else {
                warn("setting \(key.name) holds \(object), not a \(Value.self); using its default")
                return key.defaultValue
            }
            return value
        }
        set {
            defaults.set(newValue.propertyList, forKey: key.name)
        }
    }

    /// Whether the key has ever been written, as opposed to reading as its default.
    public func isSet<Value>(_ key: SettingKey<Value>) -> Bool {
        defaults.object(forKey: key.name) != nil
    }

    public func reset<Value>(_ key: SettingKey<Value>) {
        defaults.removeObject(forKey: key.name)
    }

    /// Calls `handler` with the new value whenever the key's value changes, until the returned token is
    /// released.
    public func observe<Value>(_ key: SettingKey<Value>, _ handler: @escaping @MainActor (Value) -> Void) -> SettingsObservation {
        let watcher = watchers[key.name] ?? KeyWatcher(defaults: defaults, name: key.name)
        watchers[key.name] = watcher
        var last = self[key]
        let id = watcher.add { [weak self] in
            guard let self else { return }
            let value = self[key]
            guard value != last else { return }
            last = value
            handler(value)
        }
        return SettingsObservation { [weak watcher] in watcher?.remove(id) }
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

/// Key-Value Observing on one defaults key, which cfprefsd also drives for writes by other processes.
@MainActor
private final class KeyWatcher: NSObject {
    private let defaults: UserDefaults
    private let name: String
    private var handlers: [Int: @MainActor () -> Void] = [:]
    private var nextID = 0

    init(defaults: UserDefaults, name: String) {
        self.defaults = defaults
        self.name = name
        super.init()
        defaults.addObserver(self, forKeyPath: name, options: [], context: nil)
    }

    isolated deinit {
        defaults.removeObserver(self, forKeyPath: name)
    }

    func add(_ handler: @escaping @MainActor () -> Void) -> Int {
        nextID += 1
        handlers[nextID] = handler
        return nextID
    }

    func remove(_ id: Int) {
        handlers[id] = nil
    }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                                           context: UnsafeMutableRawPointer?) {
        // A write by another process is reported on whichever thread cfprefsd's reply lands.
        DispatchQueue.main.async { MainActor.assumeIsolated { for handler in self.handlers.values { handler() } } }
    }
}
