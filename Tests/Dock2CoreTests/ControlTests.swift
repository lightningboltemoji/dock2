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
        #expect(try ControlCommand.parse(["debug", "key", "escape"]) == .debug(.key(.escape)))
        #expect(try ControlCommand.parse(["debug", "reveal", "off"]) == .debug(.reveal(false)))
        #expect(try ControlCommand.parse(["debug", "state"]).isDebug)
        #expect(try !ControlCommand.parse(["status"]).isDebug)
    }

    @Test func whatIsNotACommandIsSaidSo() {
        #expect(throws: ControlError.self) { try ControlCommand.parse(["dismiss", "now"]) }
        #expect(throws: ControlError.self) { try ControlCommand.parse(["debug", "key", "f13"]) }
        #expect(throws: ControlError.self) { try ControlCommand.parse(["debug", "reveal", "maybe"]) }
        #expect(throws: ControlError.self) { try ControlCommand.parse(["launch"]) }
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
