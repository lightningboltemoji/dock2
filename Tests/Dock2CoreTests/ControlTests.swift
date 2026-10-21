import Dock2Core
import Foundation
import Testing

@Suite struct ControlTests {
    @Test func theVerbsParse() throws {
        #expect(try ControlCommand.parse(["summon"]) == .summon(query: nil))
        #expect(try ControlCommand.parse(["summon", "system", "settings"]) == .summon(query: "system settings"))
        #expect(try ControlCommand.parse(["files", "~/Desktop"]) == .files(folder: "~/Desktop"))
        #expect(try ControlCommand.parse(["dismiss"]) == .dismiss)
        #expect(try ControlCommand.parse(["debug", "type", "hello", "there"]) == .debug(.type("hello there")))
        #expect(try ControlCommand.parse(["debug", "key", "escape"]) == .debug(.press(ControlPress(key: .named(.escape)))))
        #expect(try ControlCommand.parse(["debug", "hold", "shift+cmd"]) == .debug(.hold([.shift, .cmd])))
        #expect(try ControlCommand.parse(["debug", "hold", "none"]) == .debug(.hold([])))
        #expect(try ControlCommand.parse(["debug", "reveal", "off"]) == .debug(.reveal(false)))
        #expect(try ControlCommand.parse(["debug", "state"]).isDebug)
        #expect(try !ControlCommand.parse(["status"]).isDebug)
    }

    @Test func whatIsNotACommandIsSaidSo() {
        #expect(throws: ControlError.self) { try ControlCommand.parse(["dismiss", "now"]) }
        #expect(throws: ControlError.self) { try ControlCommand.parse(["debug", "key", "f13"]) }
        #expect(throws: ControlError.self) { try ControlCommand.parse(["debug", "key", "hyper+k"]) }
        #expect(throws: ControlError.self) { try ControlCommand.parse(["debug", "hold", "cmd+k"]) }
        #expect(throws: ControlError.self) { try ControlCommand.parse(["debug", "reveal", "maybe"]) }
        #expect(throws: ControlError.self) { try ControlCommand.parse(["launch"]) }
    }

    @Test func chordsReadAsTheyAreWritten() throws {
        #expect(try ControlPress("cmd+k") == ControlPress(key: .character("k"), modifiers: [.cmd]))
        #expect(try ControlPress("shift+cmd+.") == ControlPress(key: .character("."), modifiers: [.cmd, .shift]))
        #expect(try ControlPress("⌘⇧+1".replacingOccurrences(of: "⌘⇧", with: "cmd+shift")) == ControlPress(key: .character("1"), modifiers: [.shift, .cmd]))
        #expect(try ControlPress("cmd++") == ControlPress(key: .character("+"), modifiers: [.cmd]))
        #expect(try ControlPress("Option+Up") == ControlPress(key: .named(.up), modifiers: [.option]))
        #expect(try ControlPress("K") == ControlPress(key: .character("k")))
    }

    private var state: DebugState {
        let tile = { (name: String, x: Double) in
            DebugState.Tile(name: name, kind: "app", running: false, ringed: false, frame: .init(x: x, y: 1300, width: 100, height: 100))
        }
        let panel = DebugState.Panel(shown: true, form: "drop", resting: false, field: .init(x: 960, y: 1184, width: 640, height: 57),
                                     body: nil, reach: nil, screen: nil, text: "sa",
                                     rows: [.init(title: "Safari", subtitle: nil, selected: true, frame: .init(x: 960, y: 1120, width: 640, height: 56)),
                                            .init(title: "far", subtitle: nil, selected: false)])
        return DebugState(pid: 1, version: "dev", phase: "engaged", hasKeyboard: true,
                          dock: .init(shown: true, platter: .init(x: 1000, y: 1290, width: 560, height: 150),
                                      tiles: [tile("Files", 1000), tile("Safari", 1100)]),
                          panel: panel, display: .init(x: 0, y: 0, width: 2560, height: 1440), scale: 2)
    }

    @Test func aTargetIsWhereStateSaysItIs() throws {
        #expect(try PointerTarget("tile:safari").point(in: state)! == (1150, 1350))
        #expect(try PointerTarget("tile:1").point(in: state)! == (1050, 1350))
        #expect(try PointerTarget("row:1").point(in: state)! == (1280, 1148))
        #expect(try PointerTarget("field").point(in: state)! == (1280, 1212.5))
        #expect(try PointerTarget("edge").point(in: state)! == (1280, 1440))
        #expect(try PointerTarget("12,34").point(in: state)! == (12, 34))
    }

    @Test func aTargetNotShowingIsNowhere() throws {
        var hidden = state
        hidden.dock.shown = false
        #expect(try PointerTarget("tile:safari").point(in: hidden) == nil)
        #expect(try PointerTarget("tile:mail").point(in: state) == nil)
        // Scrolled out of the panel: listed, but not there to aim at.
        #expect(try PointerTarget("row:2").point(in: state) == nil)
        #expect(throws: ControlError.self) { try PointerTarget("row:0") }
        #expect(throws: ControlError.self) { try PointerTarget("dock") }
    }

    @Test func aMessageRoundTripsAsOneLine() throws {
        let line = try ControlWire.encode(ControlWire.Request(.summon(query: "a\nb")))
        #expect(line.last == 0x0A && line.dropLast().firstIndex(of: 0x0A) == nil)
        let decoded = try ControlWire.decode(ControlWire.Request.self, from: line.dropLast())
        #expect(decoded.command == .summon(query: "a\nb"))
    }

    @Test func anotherBuildsVersionIsNamed() throws {
        var request = ControlWire.Request(.status)
        request.version = ControlWire.version + 1
        let line = try ControlWire.encode(request).dropLast()
        #expect {
            try ControlWire.decode(ControlWire.Request.self, from: line)
        } throws: { "\($0)".contains("version \(ControlWire.version + 1)") }
    }

    @Test func theSocketIsTheUsersOwn() {
        #expect(ControlWire.socketPath(environment: ["DOCK2_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
        #expect(ControlWire.socketPath(environment: ["TMPDIR": "/var/folders/ab/T/"]) == "/var/folders/ab/T/dock2.sock")
        let long = "/" + String(repeating: "a", count: 120)
        #expect(ControlWire.socketPath(environment: ["TMPDIR": long], user: "me") == "/tmp/dock2-me.sock")
    }
}
