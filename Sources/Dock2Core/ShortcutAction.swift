/// What a global shortcut does ([keyboard](product/keyboard.md#global)): one of dock2's own actions, or any
/// command a plugin declares.
public enum ShortcutAction: Hashable, Sendable {
    case summon
    case clipboardHistory
    case files
    case command(plugin: String, id: String)

    /// Each chord to the first action in `bindings` asking for it; every later one asking for the same chord,
    /// to the action holding it. Carbon refuses a process's second registration of a chord.
    public static func resolve(_ bindings: [(action: ShortcutAction, chord: KeyChord)])
        -> (held: [(action: ShortcutAction, chord: KeyChord)], taken: [ShortcutAction: ShortcutAction]) {
        var holder: [KeyChord: ShortcutAction] = [:]
        var held: [(action: ShortcutAction, chord: KeyChord)] = []
        var taken: [ShortcutAction: ShortcutAction] = [:]
        for binding in bindings {
            if let first = holder[binding.chord] {
                taken[binding.action] = first
            } else {
                holder[binding.chord] = binding.action
                held.append(binding)
            }
        }
        return (held, taken)
    }
}
