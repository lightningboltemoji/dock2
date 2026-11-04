import Dock2Core
import Foundation
import Testing

/// A plugin's JSON to XPC's values and back: tags where JSON cannot say which.
@Suite struct XPCValueTests {
    func value(_ json: String) throws -> XPCValue {
        try XPCValue(json: JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    @Test func plainJSONAndTagsBecomeXPCsValues() throws {
        let uuid = UUID()
        #expect(try value("""
        {"whole": 7, "fraction": 1.5, "int": {"$int": 2}, "uint": {"$uint": "18446744073709551615"}, "double": {"$double": 3},
         "data": {"$data": "AAEC"}, "date": {"$date": 1700000000000}, "uuid": {"$uuid": "\(uuid.uuidString)"},
         "list": [true, null, "text"], "$odd": {"$unknown": 1}}
        """) == .dictionary([
            "whole": .int64(7), "fraction": .double(1.5), "int": .int64(2), "uint": .uint64(.max), "double": .double(3),
            "data": .data(Data([0, 1, 2])), "date": .date(1_700_000_000_000_000_000), "uuid": .uuid(uuid),
            "list": .array([.bool(true), .null, .string("text")]), "$odd": .dictionary(["$unknown": .int64(1)]),
        ]))
    }

    /// Back to the plugin every number says which it was, so it reads the same thing a service sent.
    @Test func whatComesBackIsTagged() throws {
        let sent: XPCValue = .dictionary(["n": .int64(7), "u": .uint64(.max), "d": .double(1), "when": .date(1_500_000), "on": .bool(true)])
        let json = try JSONEncoder().encode(sent.json)
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains(#""n":{"$int":7}"#) && text.contains(#""u":{"$uint":"18446744073709551615"}"#) && text.contains(#""when":{"$date":1.5}"#))
        #expect(try XPCValue(json: JSONDecoder().decode(JSONValue.self, from: json)) == sent)
    }

    @Test func aTagHoldingTheWrongThingIsRefused() {
        // A date past what XPC holds, and a key a C string would cut short into another.
        for json in [#"{"$int": 1.5}"#, #"{"$uint": -1}"#, #"{"$data": "not base64!"}"#, #"{"$uuid": "nope"}"#, #""a\u0000b""#,
                     #"{"$date": 1e300}"#, #"{"dock2.plugin\u0000x": "forged", "n": 1}"#, #"{"$tag\u0000": 1}"#] {
            #expect(throws: XPCValue.Refusal.self, "\(json)") { try value(json) }
        }
    }
}
