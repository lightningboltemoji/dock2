import AppKit
import Dock2Core
import Dock2System

extension NSEvent.ModifierFlags {
    init(_ modifiers: [ControlModifier]) {
        self = modifiers.reduce(into: []) { flags, modifier in
            switch modifier {
            case .cmd: flags.insert(.command)
            case .shift: flags.insert(.shift)
            case .option: flags.insert(.option)
            case .control: flags.insert(.control)
            }
        }
    }
}

/// Answers the control socket ([control](../../.agents/product/control.md)) by doing what dock2's own keys
/// and tiles do. `debug` commands — typing, keys, the state of everything shown — only with `debug`, which
/// only `DOCK2_DEBUG=1` at launch sets. The pointer's are the CLI's, which moves the real one.
@MainActor
final class ControlRouter {
    static let debugEnvironmentKey = "DOCK2_DEBUG"

    let debug: Bool
    private let stage: Stage
    private let interaction: InteractionController
    private let panel: PanelController
    private let dock: DockController

    init(debug: Bool, stage: Stage, interaction: InteractionController, panel: PanelController, dock: DockController) {
        self.debug = debug
        self.stage = stage
        self.interaction = interaction
        self.panel = panel
        self.dock = dock
    }

    func reply(to command: ControlCommand) -> ControlReply {
        switch command {
        case .summon(let query):
            interaction.request()
            if let query {
                panel.field.string = query
                panel.focus()
            }
            return .ok
        case .dismiss:
            interaction.dismiss()
            return .ok
        case .files(let folder):
            let url = folder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            var isFolder: ObjCBool = false
            if let url, !FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) || !isFolder.boolValue {
                return .failed("\(url.path) is not a folder")
            }
            interaction.showFiles(at: url)
            return .ok
        case .clipboard:
            interaction.showClipboardHistory()
            return .ok
        case .status:
            return json(Status(version: Dock2Identity.version, pid: getpid(), hasKeyboard: interaction.hasKeyboard, debug: debug))
        case .debug where !debug:
            return .failed("debug commands need a dock2 started with \(Self.debugEnvironmentKey)=1")
        case .debug(let command):
            return reply(to: command)
        }
    }

    private struct Status: Encodable {
        let version: String
        let pid: Int32
        let hasKeyboard: Bool
        let debug: Bool
    }

    private func reply(to command: DebugCommand) -> ControlReply {
        switch command {
        case .state:
            return json(state)
        case .type(let text):
            guard interaction.hasKeyboard else { return .failed("dock2 does not have the keyboard; summon it first") }
            for character in text { post(ControlPress(key: .character(String(character)))) }
            return .ok
        case .press(let press):
            post(press)
            return .ok
        case .hold(let modifiers):
            hold(modifiers)
            return .ok
        case .reveal(let on):
            dock.hold(.control, on)
            return .ok
        }
    }

    private var state: DebugState {
        let screen = stage.screen
        let primary = NSScreen.screens.first?.frame.height ?? screen.frame.height
        // From the stage's coordinates to the screen's, top left first.
        let global = { (rect: CGRect) -> DebugState.Rect in
            DebugState.Rect(x: rect.minX + screen.frame.minX, y: primary - (rect.maxY + screen.frame.minY),
                            width: rect.width, height: rect.height)
        }
        let phase = switch interaction.phase {
        case .resting: "resting"
        case .revealed: "revealed"
        case .engaged: "engaged"
        }
        return DebugState(pid: getpid(), version: Dock2Identity.version, phase: phase, hasKeyboard: interaction.hasKeyboard,
                          dock: DebugState.Dock(shown: dock.isShown, platter: dock.platter.map(global),
                                                tiles: dock.debugTiles(global: global)),
                          panel: panel.debugState(global: global),
                          display: global(CGRect(origin: .zero, size: screen.frame.size)), scale: screen.backingScaleFactor)
    }

    /// A key down and up into dock2's own event queue, as the window server delivers one: a key equivalent,
    /// an open menu, the field or Files' columns take it as they take a person's, and no other app can.
    private func post(_ press: ControlPress) {
        let (base, code, function) = Self.key(press.key)
        var flags = NSEvent.ModifierFlags(press.modifiers)
        if function { flags.formUnion([.function, .numericPad]) }
        // As a keyboard says it: ⇧ is in both, so ⇧⌘Z reaches Redo's "Z".
        let characters = press.modifiers.contains(.shift) ? base.uppercased() : base
        let window = stage.window.windowNumber
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                                               keyCode: code) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// The modifiers as a flags-changed event says them, alone.
    private func hold(_ modifiers: [ControlModifier]) {
        let codes: [ControlModifier: CGKeyCode] = [.cmd: 55, .shift: 56, .option: 58, .control: 59]
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: modifiers.last.flatMap { codes[$0] } ?? 55, keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: UInt64(NSEvent.ModifierFlags(modifiers).rawValue))
        if let posted = NSEvent(cgEvent: event) { NSApp.postEvent(posted, atStart: false) }
    }

    /// What the key types unshifted, its virtual key code on a US layout, and whether it is a function key.
    private static func key(_ key: ControlPress.Key) -> (String, UInt16, Bool) {
        let function = { (key: Int) in String(Character(UnicodeScalar(UInt32(key))!)) }
        switch key {
        case .named(let named):
            return switch named {
            case .escape: ("\u{1b}", 53, false)
            case .return: ("\r", 36, false)
            case .tab: ("\t", 48, false)
            case .delete: ("\u{7f}", 51, false)
            case .space: (" ", 49, false)
            case .up: (function(NSUpArrowFunctionKey), 126, true)
            case .down: (function(NSDownArrowFunctionKey), 125, true)
            case .left: (function(NSLeftArrowFunctionKey), 123, true)
            case .right: (function(NSRightArrowFunctionKey), 124, true)
            case .home: (function(NSHomeFunctionKey), 115, true)
            case .end: (function(NSEndFunctionKey), 119, true)
            case .pageup: (function(NSPageUpFunctionKey), 116, true)
            case .pagedown: (function(NSPageDownFunctionKey), 121, true)
            }
        case .character(let character):
            return (character, ansi[character.lowercased()] ?? 0, false)
        }
    }

    /// The US layout's key for each character it types unshifted.
    private static let ansi: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]

    private func json<T: Encodable>(_ value: T) -> ControlReply {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return .failed("could not encode the answer") }
        return .json(String(decoding: data, as: UTF8.self))
    }
}
