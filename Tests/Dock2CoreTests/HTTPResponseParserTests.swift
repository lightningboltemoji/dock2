import Dock2Core
import Foundation
import Testing

@Suite struct HTTPResponseParserTests {
    /// The response fed whole and a byte at a time: the same head, body and end either way.
    func parse(_ text: String, method: String = "GET", closes: Bool = false) throws -> (HTTPResponseParser.Head?, String, Bool) {
        func run(_ pieces: [Data]) throws -> (HTTPResponseParser.Head?, String, Bool) {
            var parser = HTTPResponseParser(method: method)
            var head: HTTPResponseParser.Head?, body = Data(), ended = false
            for piece in try pieces.flatMap({ try parser.feed($0) }) + (closes ? try parser.finish() : []) {
                switch piece {
                case .head(let h): head = h
                case .body(let b): body.append(b)
                case .end: ended = true
                }
            }
            return (head, String(decoding: body, as: UTF8.self), ended)
        }
        let bytes = Data(text.utf8)
        let whole = try run([bytes]), dribbled = try run(bytes.map { Data([$0]) })
        #expect(whole.0 == dribbled.0 && whole.1 == dribbled.1 && whole.2 == dribbled.2)
        return whole
    }

    @Test func aBodyByItsLength() throws {
        let (head, body, ended) = try parse("HTTP/1.1 200 OK\r\nContent-Length: 5\r\ncontent-type: text/plain\r\n\r\nhello")
        #expect(head?.status == 200 && head?.header("Content-Type") == "text/plain" && body == "hello" && ended)
    }

    @Test func aBodyInChunks() throws {
        let (head, body, ended) = try parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: t\r\n\r\n")
        #expect(head?.status == 200 && body == "hello world" && ended)
    }

    /// A 100 Continue is passed over; a body with no length runs to the close.
    @Test func informationalThenToTheClose() throws {
        let (head, body, ended) = try parse("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.0 201 Created\r\n\r\nall of it", closes: true)
        #expect(head?.status == 201 && body == "all of it" && ended)
    }

    @Test func noBodyForHeadOr204() throws {
        #expect(try parse("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n", method: "HEAD").2)
        #expect(try parse("HTTP/1.1 204 No Content\r\n\r\n").2)
    }

    /// A line that never ends is not held without end.
    @Test func aChunkSizeWithoutItsEndIsRefused() throws {
        var parser = HTTPResponseParser(method: "GET")
        _ = try parser.feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        #expect(throws: HTTPResponseParser.Malformed.self) { try parser.feed(Data(repeating: 0x41, count: 70 << 10)) }
        #expect(HTTPSyntax.isToken("PATCH") && !HTTPSyntax.isToken("GET / HTTP/1.1\r\nX") && !HTTPSyntax.isToken("Host ") && !HTTPSyntax.isToken(""))
        #expect(!HTTPSyntax.isFieldValue("a\r\nInjected: 1"))
    }

    @Test func whatIsNotAResponseIsSaid() {
        var parser = HTTPResponseParser(method: "GET")
        #expect(throws: HTTPResponseParser.Malformed.self) { try parser.feed(Data("SSH-2.0-OpenSSH\r\n\r\n".utf8)) }
        var cut = HTTPResponseParser(method: "GET")
        _ = try? cut.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nhalf".utf8))
        #expect(throws: HTTPResponseParser.Malformed.self) { try cut.finish() }
    }
}
