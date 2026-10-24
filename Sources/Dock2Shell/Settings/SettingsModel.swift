import Dock2Core
import Dock2System
import Observation
import SwiftUI

/// The settings store as SwiftUI sees it: a binding per key. The store is observable, so a view redraws on
/// any change — from the window itself, the dock's menu, or the config file edited by hand.
@MainActor
final class SettingsModel {
    let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
    }

    func binding<Value>(_ key: SettingKey<Value>) -> Binding<Value> {
        Binding(get: { [store] in store[key] }, set: { [store] value in store[key] = value })
    }

    subscript<Value>(key: SettingKey<Value>) -> Value {
        store[key]
    }
}
