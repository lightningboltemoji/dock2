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
           dock2 debug key <escape|return|tab|delete|up|down|left|right|home|end>
           dock2 debug reveal <on|off>          hold the dock up, or let it go
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

    private func grown(_ rect: DebugState.Rect, by margin: Double) -> DebugState.Rect {
        DebugState.Rect(x: rect.x - margin, y: rect.y - margin, width: rect.width + 2 * margin, height: rect.height + 2 * margin)
    }
}
