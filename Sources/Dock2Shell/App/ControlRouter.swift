import AppKit
import Dock2Core
import Dock2System

/// Answers the control socket ([control](../../.agents/product/control.md)) by doing what dock2's own keys
/// and tiles do. `debug` commands — typing, keys, the state of everything shown — only with `debug`, which
/// only `DOCK2_DEBUG=1` at launch sets.
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
            for character in text {
                if case .failed(let why) = press(String(character), code: 0) { return .failed(why) }
            }
            return .ok
        case .key(let key):
            return press(key)
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
                          dock: DebugState.Dock(shown: dock.isShown, platter: dock.platter.map(global)),
                          panel: panel.debugState(global: global),
                          display: global(CGRect(origin: .zero, size: screen.frame.size)), scale: screen.backingScaleFactor)
    }

    private func press(_ key: ControlKey) -> ControlReply {
        let function = { (key: Int) in String(UnicodeScalar(UInt32(key)).map(Character.init)!) }
        return switch key {
        case .escape: press("\u{1b}", code: 53)
        case .return: press("\r", code: 36)
        case .tab: press("\t", code: 48)
        case .delete: press("\u{7f}", code: 51)
        case .up: press(function(NSUpArrowFunctionKey), code: 126, flags: [.function, .numericPad])
        case .down: press(function(NSDownArrowFunctionKey), code: 125, flags: [.function, .numericPad])
        case .left: press(function(NSLeftArrowFunctionKey), code: 123, flags: [.function, .numericPad])
        case .right: press(function(NSRightArrowFunctionKey), code: 124, flags: [.function, .numericPad])
        case .home: press(function(NSHomeFunctionKey), code: 115, flags: .function)
        case .end: press(function(NSEndFunctionKey), code: 119, flags: .function)
        }
    }

    /// A key down and up through the stage window, as the window server delivers one: whatever has the keys
    /// takes it, the field or Files' columns, after the window's own look at it.
    private func press(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> ControlReply {
        let window = stage.window
        guard interaction.hasKeyboard, window.isKeyWindow else { return .failed("dock2 does not have the keyboard; summon it first") }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code) else { continue }
            window.sendEvent(event)
        }
        return .ok
    }

    private func json<T: Encodable>(_ value: T) -> ControlReply {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return .failed("could not encode the answer") }
        return .json(String(decoding: data, as: UTF8.self))
    }
}
