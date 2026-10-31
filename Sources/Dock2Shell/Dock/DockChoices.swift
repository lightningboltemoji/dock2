import Dock2Core
import Dock2System

extension SettingsStore {
    /// The pinned and sidelined apps, read and written together: an app is in one list at most.
    var dockChoices: DockChoices {
        get { DockChoices(pinned: self[Settings.pinned], sidelined: self[Settings.sidelined]) }
        set {
            self[Settings.pinned] = newValue.pinned
            self[Settings.sidelined] = newValue.sidelined
        }
    }
}
