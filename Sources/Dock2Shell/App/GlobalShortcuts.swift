import Dock2Core
import Dock2Plugins
import Dock2System
import Observation

/// Every global shortcut dock2 registers ([keyboard](product/keyboard.md#global)): the summon shortcut, with
/// Spotlight's ⌘space taken over for it; Clipboard History's; Files'; and one for any plugin command the user bound.
/// A chord asked for twice goes to dock2's own action first, then to plugins in the order they are installed.
@MainActor
final class GlobalShortcuts {
    private let settings: SettingsStore
    private let takeovers: Takeovers
    private let plugins: PluginStore
    private let perform: (ShortcutAction) -> Void
    let status = ShortcutStatus()
    private var registered: [ShortcutAction: (chord: KeyChord, registration: HotKeys.Registration?)] = [:]
    private var observations: [SettingsObservation] = []

    init(settings: SettingsStore, takeovers: Takeovers, plugins: PluginStore, perform: @escaping (ShortcutAction) -> Void) {
        self.settings = settings
        self.takeovers = takeovers
        self.plugins = plugins
        self.perform = perform
    }

    /// Registers what the settings ask for, and again as they change. The plugin store's changes come
    /// through `apply`, which `AppController` calls from its `onChange`.
    func start() {
        applySpotlight()
        apply()
        observations.append(settings.observe(Settings.summon) { [weak self] _ in
            self?.applySpotlight()
            self?.apply()
        })
        observations.append(settings.observe(Settings.clipboardShortcut) { [weak self] _ in self?.apply() })
        observations.append(settings.observe(Settings.filesShortcut) { [weak self] _ in self?.apply() })
        observations.append(settings.observeTables { [weak self] in self?.apply() })
    }

    // MARK: - ⌘space

    private static let commandSpace = KeyChord(keyCode: KeyChord.space, modifiers: KeyChord.command)
    static let spotlight = TakeoverID.hotKey(HotKeyTable.spotlight)

    /// ⌘space is Spotlight's until dock2 takes it over, which it can only where the hot key table exists.
    static func takesSpotlight(_ settings: SettingsStore) -> Bool {
        settings[Settings.summon] == .commandSpace && HotKeyTable.isAvailable
    }

    /// Takes Spotlight's ⌘space over, or gives it back, as the summon shortcut now asks.
    private func applySpotlight() {
        if Self.takesSpotlight(settings) {
            do {
                try takeovers.engage(Self.spotlight)
            } catch {
                warn("could not journal Spotlight's shortcut, so ⌘space is left to it: \(error.localizedDescription)")
            }
        } else if takeovers.holds(Self.spotlight) {
            takeovers.release(Self.spotlight)
        }
    }

    // MARK: - Registering

    /// What each action asks for, dock2's own first.
    private var bindings: [(action: ShortcutAction, chord: KeyChord)] {
        var bindings: [(action: ShortcutAction, chord: KeyChord)] = []
        switch settings[Settings.summon] {
        case .commandSpace where takeovers.holds(Self.spotlight): bindings.append((.summon, Self.commandSpace))
        case .chord(let chord): bindings.append((.summon, chord))
        case .commandSpace, .none: break
        }
        if case .chord(let chord) = settings[Settings.clipboardShortcut] { bindings.append((.clipboardHistory, chord)) }
        if case .chord(let chord) = settings[Settings.filesShortcut] { bindings.append((.files, chord)) }
        for plugin in plugins.plugins where plugins.isEnabled(plugin.id) {
            let chosen = plugins.choices(plugin.id)?.shortcuts ?? [:]
            for command in plugin.manifest.commands ?? [] {
                guard let chord = chosen[command.id] else { continue }
                bindings.append((.command(plugin: plugin.id, id: command.id), chord))
            }
        }
        return bindings
    }

    /// Registers what the settings ask for and drops the rest; a registration whose chord did not change
    /// is kept, and one macOS refused is tried again.
    func apply() {
        let (held, taken) = ShortcutAction.resolve(bindings)
        let wanted = Dictionary(held.map { ($0.action, $0.chord) }, uniquingKeysWith: { first, _ in first })
        // Dropped first, so a chord moving from one action to another is free when the other registers it.
        for (action, entry) in registered where wanted[action] != entry.chord || entry.registration == nil {
            registered[action] = nil
        }
        for (action, chord) in held where registered[action] == nil {
            registered[action] = (chord, HotKeys.register(chord) { [weak self] in self?.perform(action) })
        }
        var problems = taken.mapValues { ShortcutStatus.Problem.taken(by: $0) }
        for (action, entry) in registered where entry.registration == nil { problems[action] = .refused }
        status.problems = problems
    }
}

/// Why a global shortcut is not working, for Settings to say.
@MainActor
@Observable
final class ShortcutStatus {
    enum Problem: Equatable {
        /// `RegisterEventHotKey` failed. It accepts chords the system's own shortcuts use, ⌘⇥ among them.
        case refused
        /// Another of dock2's actions has the chord.
        case taken(by: ShortcutAction)
    }

    fileprivate(set) var problems: [ShortcutAction: Problem] = [:]
}
