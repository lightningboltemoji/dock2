import Foundation

/// An HTTP/1.1 response read as it arrives, for `local-network`'s client: the head once, then the body as it
/// comes, by its length, in chunks, or to the connection's close. A 1xx is passed over; a HEAD, 204 or 304 has none.
public struct HTTPResponseParser: Sendable {
    public struct Head: Equatable, Sendable {
        public let status: Int
        /// By the name the server wrote; a name repeated has its values joined with ", ".
        public let headers: [String: String]

        public func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    public enum Piece: Equatable, Sendable {
        case head(Head)
        case body(Data)
        case end
    }

    public struct Malformed: Error, Equatable, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private enum State: Sendable {
        case head
        case length(Int)
        case chunkSize
        case chunk(Int)
        case chunkEnd
        case trailer
        case toClose
        case done
    }

    private let method: String
    private var state = State.head
    private var buffer = Data()
    /// A head this long without its end is no response.
    static let headLimit = 64 << 10

    public init(method: String) {
        self.method = method.uppercased()
    }

    public var isDone: Bool {
        if case .done = state { true } else { false }
    }

    public mutating func feed(_ data: Data) throws -> [Piece] {
        buffer.append(data)
        var pieces: [Piece] = []
        while true {
            switch state {
            case .done:
                return pieces
            case .head:
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    guard buffer.count < Self.headLimit else { throw Malformed(message: "a head past 64 KiB") }
                    return pieces
                }
                let head = try Self.head(buffer[buffer.startIndex..<end.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                if (100..<200).contains(head.status) { continue }
                pieces.append(.head(head))
                if method == "HEAD" || head.status == 204 || head.status == 304 {
                    state = .done
                } else if head.header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
                    state = .chunkSize
                } else if let length = head.header("Content-Length").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                    guard length >= 0 else { throw Malformed(message: "a negative length") }
                    state = length == 0 ? .done : .length(length)
                } else {
                    state = .toClose
                }
                if case .done = state { pieces.append(.end) }
            case .length(let remaining):
                guard !buffer.isEmpty else { return pieces }
                let taken = buffer.prefix(remaining)
                buffer.removeFirst(taken.count)
                pieces.append(.body(Data(taken)))
                state = remaining == taken.count ? .done : .length(remaining - taken.count)
                if case .done = state { pieces.append(.end) }
            case .chunkSize:
                guard let line = try takeLine() else { return pieces }
                let hex = line.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(hex, radix: 16), size >= 0 else { throw Malformed(message: "a chunk size of “\(line)”") }
                state = size == 0 ? .trailer : .chunk(size)
            case .chunk(let remaining):
                guard !buffer.isEmpty else { return pieces }
                let taken = buffer.prefix(remaining)
                buffer.removeFirst(taken.count)
                pieces.append(.body(Data(taken)))
                state = remaining == taken.count ? .chunkEnd : .chunk(remaining - taken.count)
            case .chunkEnd:
                guard let line = try takeLine() else { return pieces }
                guard line.isEmpty else { throw Malformed(message: "a chunk running past its size") }
                state = .chunkSize
            case .trailer:
                guard let line = try takeLine() else { return pieces }
                if line.isEmpty {
                    state = .done
                    pieces.append(.end)
                }
            case .toClose:
                guard !buffer.isEmpty else { return pieces }
                pieces.append(.body(buffer))
                buffer.removeAll()
                return pieces
            }
        }
    }

    /// The connection closed: the end of a body read to it, or of a response cut short.
    public mutating func finish() throws -> [Piece] {
        switch state {
        case .done: return []
        case .toClose:
            state = .done
            return [.end]
        default:
            throw Malformed(message: "the connection closed before the response ended")
        }
    }

    /// A line of a chunked body — a size, an end, a trailer — the length of a head at most.
    private mutating func takeLine() throws -> String? {
        guard let end = buffer.range(of: Data("\r\n".utf8)) else {
            guard buffer.count < Self.headLimit else { throw Malformed(message: "a line past 64 KiB") }
            return nil
        }
        let line = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        return line
    }

    private static func head(_ bytes: Data) throws -> Head {
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard status.count >= 2, status[0].hasPrefix("HTTP/1."), let code = Int(status[1]) else {
            throw Malformed(message: "no status line: “\(lines.first ?? "")”")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let existing = headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) {
                headers[existing.key] = existing.value + ", " + value
            } else {
                headers[name] = value
            }
        }
        return Head(status: code, headers: headers)
    }
}

/// What a request may hold where HTTP's grammar is strict: a method or a header's name is a token, and a value
/// never breaks a line.
public enum HTTPSyntax {
    public static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "!#$%&'*+-.^_`|~".unicodeScalars.contains($0)) }
    }

    /// By scalar: `"\r\n"` is one `Character`, equal to neither of its halves.
    public static func isFieldValue(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" }
    }
}
