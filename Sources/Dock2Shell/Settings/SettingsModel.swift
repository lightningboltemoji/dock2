import Dock2Core
import Dock2System
import Observation
import SwiftUI

/// The settings store as SwiftUI sees it: a binding per key, and a redraw whenever any key changes — from
/// the window itself, the dock's menu, or `defaults write`.
@MainActor
@Observable
final class SettingsModel {
    @ObservationIgnored let store: SettingsStore
    /// Bumped on every change; reading it in a binding is what ties a view to the store.
    private var generation = 0
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(store: SettingsStore) {
        self.store = store
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: store.defaults,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.generation += 1 }
        }
    }

    func binding<Value>(_ key: SettingKey<Value>) -> Binding<Value> {
        Binding(get: { [self] in
            _ = generation
            return store[key]
        }, set: { [self] value in
            store[key] = value
        })
    }

    subscript<Value>(key: SettingKey<Value>) -> Value {
        _ = generation
        return store[key]
    }

    /// Re-reads everything: on appearing, for changes made while the window was closed by another process.
    func refresh() {
        generation += 1
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
