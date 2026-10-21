import CoreGraphics
import Dock2Core
import Dock2System
import Foundation

/// `dock2 <verb>` and `dock2 debug <verb>` ([control](product/control.md)): one request to the running dock2,
/// its answer printed. `capture`, `record` and `type --every` are put together here, from requests a dock2
/// started with `DOCK2_DEBUG=1` answers. Exits 0 done, 1 refused, 2 not a command, 69 no dock2 to ask.
struct ControlCommandLine {
    static let verbs: Set = ["summon", "dismiss", "files", "clipboard", "status", "debug"]

    static let usage = """
           dock2 summon [query]                 take the keyboard, the field risen, the query typed
           dock2 dismiss
           dock2 files [folder]
           dock2 clipboard                      Clipboard History
           dock2 status
           dock2 debug state                    where everything is, and what it shows (JSON)
           dock2 debug type <text> [--every <seconds>]
           dock2 debug key <key>                a key or a chord: escape, return, up, cmd+k, shift+cmd+., cmd+1
           dock2 debug hold <cmd[+shift…]|none> modifiers held alone, or let go
           dock2 debug reveal <on|off>          hold the dock up, or let it go
           dock2 debug move <target> [--glide <seconds>]
           dock2 debug click <target> [--right] [--double] [--cmd] [--option] [--shift] [--control]
           dock2 debug drag <target> <target> [--cmd] [--option]
               targets: tile:<name|n>, row:<n>, field, platter, edge, away, x,y — the real pointer moves
           dock2 debug capture <field|panel|reach|dock|display> [file.png]
           dock2 debug record <field|panel|reach|dock|display> <seconds> [file.mov]
           (debug commands need a dock2 started with DOCK2_DEBUG=1)
    """

    func run(_ words: [String]) -> Int32 {
        do {
            switch (words.first, words.dropFirst().first) {
            case ("debug", "capture"): return try capture(Array(words.dropFirst(2)), recording: false)
            case ("debug", "record"): return try capture(Array(words.dropFirst(2)), recording: true)
            case ("debug", "type") where words.contains("--every"): return try typeSlowly(Array(words.dropFirst(2)))
            case ("debug", let verb?) where ["move", "click", "drag"].contains(verb): return try pointer(verb, Array(words.dropFirst(2)))
            default: return try print(send(ControlCommand.parse(words)))
            }
        } catch let error as ControlError {
            warn("\(error)")
            return 2
        } catch ControlSocketError.unreachable(let path) {
            warn("\(ControlSocketError.unreachable(path))")
            return 69
        } catch {
            warn("\(error)")
            return 1
        }
    }

    private func send(_ command: ControlCommand) throws -> ControlReply {
        try ControlClient.send(command)
    }

    private func print(_ reply: ControlReply) -> Int32 {
        switch reply {
        case .ok: return 0
        case .json(let json):
            Swift.print(json)
            return 0
        case .failed(let why):
            warn(why)
            return 1
        }
    }

    /// A letter a request, `--every` seconds apart, as a person types.
    private func typeSlowly(_ words: [String]) throws -> Int32 {
        guard let flag = words.firstIndex(of: "--every"), flag + 1 < words.count, let every = Double(words[flag + 1]) else {
            throw ControlError("--every takes seconds")
        }
        let text = (words[..<flag] + words[(flag + 2)...]).joined(separator: " ")
        for (index, character) in text.enumerated() {
            if index > 0 { Thread.sleep(forTimeInterval: every) }
            if case .failed(let why) = try send(.debug(.type(String(character)))) {
                warn(why)
                return 1
            }
        }
        return 0
    }

    /// `screencapture` of one region, from where `debug state` says it is, with room for its shadow — or,
    /// for `dock`, its labels above it.
    private func capture(_ words: [String], recording: Bool) throws -> Int32 {
        guard let region = words.first, words.count >= (recording ? 2 : 1) else {
            throw ControlError(recording ? "record takes a region and seconds" : "capture takes a region")
        }
        let seconds = recording ? Double(words[1]) : nil
        if recording, seconds == nil { throw ControlError("record takes seconds, not \(words[1])") }
        let reply = try send(.debug(.state))
        guard case .json(let json) = reply else { return print(reply) }
        let state = try JSONDecoder().decode(DebugState.self, from: Data(json.utf8))
        let rect: DebugState.Rect?
        switch region {
        case "field": rect = state.panel.field.map { grown($0, by: 28) }
        case "panel": rect = state.panel.body.map { grown($0, by: 28) }
        case "reach": rect = state.panel.reach.map { grown($0, by: 28) }
        case "dock": rect = state.dock.platter.map { DebugState.Rect(x: $0.x - 12, y: $0.y - 64, width: $0.width + 24, height: $0.height + 76) }
        case "display": rect = state.display
        default: throw ControlError("no region \(region); one of field, panel, reach, dock, display")
        }
        guard let rect else {
            warn("nothing at \(region) to capture: is it showing?")
            return 1
        }
        let file = words.dropFirst(recording ? 2 : 1).first ?? NSTemporaryDirectory()
            + "dock2-\(region)-\(Int(Date().timeIntervalSince1970 * 1000)).\(recording ? "mov" : "png")"
        let area = [rect.x, rect.y, rect.width, rect.height].map { String(Int($0.rounded())) }.joined(separator: ",")
        var arguments = ["-x", "-R", area]
        if let seconds { arguments += ["-v", "-V", String(seconds)] }
        // A recording will not replace a file; a capture asked for at a path means that path, now.
        try? FileManager.default.removeItem(atPath: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + [file]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            warn("screencapture failed; it needs Screen Recording for this terminal")
            return 1
        }
        Swift.print(file)
        return 0
    }

    private func debugState() throws -> DebugState {
        let reply = try send(.debug(.state))
        switch reply {
        case .json(let json): return try JSONDecoder().decode(DebugState.self, from: Data(json.utf8))
        case .failed(let why): throw ControlError(why)
        case .ok: throw ControlError("dock2 sent no state")
        }
    }

    /// The real pointer, posted where the hardware's goes, so dock2 hears it as it hears a person's — and so
    /// does whatever is under it, which is why a target `debug state` says is not showing is refused.
    private func pointer(_ verb: String, _ words: [String]) throws -> Int32 {
        var words = words
        func flag(_ name: String) -> Bool {
            guard let index = words.firstIndex(of: name) else { return false }
            words.remove(at: index)
            return true
        }
        var glide = 0.25
        if let index = words.firstIndex(of: "--glide") {
            guard index + 1 < words.count, let seconds = Double(words[index + 1]) else { throw ControlError("--glide takes seconds") }
            glide = seconds
            words.removeSubrange(index...index + 1)
        }
        var flags: CGEventFlags = []
        if flag("--cmd") { flags.insert(.maskCommand) }
        if flag("--option") { flags.insert(.maskAlternate) }
        if flag("--shift") { flags.insert(.maskShift) }
        if flag("--control") { flags.insert(.maskControl) }
        let right = flag("--right"), double = flag("--double")
        guard words.count == (verb == "drag" ? 2 : 1) else {
            throw ControlError(verb == "drag" ? "drag takes a target to start at and one to end at" : "\(verb) takes a target")
        }
        let state = try debugState()
        let points = try words.map { word -> CGPoint in
            guard let point = try PointerTarget(word).point(in: state) else {
                throw ControlError("\(word) is not showing; `dock2 debug move edge` or `dock2 debug reveal on` shows the dock")
            }
            return CGPoint(x: point.x, y: point.y)
        }
        Pointer.glide(to: points[0], over: glide, flags: flags)
        switch verb {
        case "click":
            usleep(60_000)
            Pointer.click(at: points[0], button: right ? .right : .left, count: double ? 2 : 1, flags: flags)
        case "drag":
            // Held a moment before moving, as AppKit waits to tell a drag from a click; held over the end to let
            // whatever springs open do so.
            Pointer.button(.left, down: true, at: points[0], flags: flags)
            usleep(200_000)
            Pointer.glide(to: points[1], over: max(glide, 0.6), dragging: .left, flags: flags)
            usleep(400_000)
            Pointer.button(.left, down: false, at: points[1], flags: flags)
        default:
            break
        }
        return 0
    }

    private func grown(_ rect: DebugState.Rect, by margin: Double) -> DebugState.Rect {
        DebugState.Rect(x: rect.x - margin, y: rect.y - margin, width: rect.width + 2 * margin, height: rect.height + 2 * margin)
    }
}

/// Pointer events posted to the HID stream, a move every 8 ms as a mouse sends them.
private enum Pointer {
    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func glide(to end: CGPoint, over seconds: Double, dragging button: CGMouseButton? = nil, flags: CGEventFlags) {
        let start = location
        let steps = max(1, Int(seconds / 0.008))
        let type: CGEventType = switch button {
        case .left?: .leftMouseDragged
        case .right?: .rightMouseDragged
        default: .mouseMoved
        }
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            post(type, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), button: button ?? .left,
                 flags: flags)
            usleep(8000)
        }
    }

    static func click(at point: CGPoint, button: CGMouseButton, count: Int, flags: CGEventFlags) {
        for click in 1...count {
            Self.button(button, down: true, at: point, clickState: click, flags: flags)
            usleep(50_000)
            Self.button(button, down: false, at: point, clickState: click, flags: flags)
            usleep(80_000)
        }
    }

    static func button(_ button: CGMouseButton, down: Bool, at point: CGPoint, clickState: Int = 1, flags: CGEventFlags) {
        let type: CGEventType = switch (button, down) {
        case (.right, true): .rightMouseDown
        case (.right, false): .rightMouseUp
        case (_, true): .leftMouseDown
        case (_, false): .leftMouseUp
        }
        post(type, at: point, button: button, clickState: clickState, flags: flags)
    }

    private static func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int = 1, flags: CGEventFlags) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
    }
}
