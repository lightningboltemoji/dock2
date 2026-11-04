import Foundation

/// Any JSON a plugin hands dock2 as a value: a whole number is told from one with a fraction.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let bool = try? c.decode(Bool.self) { self = .bool(bool) }
        else if let int = try? c.decode(Int64.self) { self = .int(int) }
        else if let double = try? c.decode(Double.self) { self = .double(double) }
        else if let string = try? c.decode(String.self) { self = .string(string) }
        else if let array = try? c.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let bool): try c.encode(bool)
        case .int(let int): try c.encode(int)
        case .double(let double): try c.encode(double)
        case .string(let string): try c.encode(string)
        case .array(let array): try c.encode(array)
        case .object(let object): try c.encode(object)
        }
    }
}

/// What an XPC message holds ([services](product/plugins/permissions.md#services)): JSON's own values, a whole
/// number an int64, and `$int`, `$uint`, `$double`, `$data`, `$date` (ms since 1970) and `$uuid` tags where JSON
/// cannot say which. Back to the plugin, every number is tagged.
public indirect enum XPCValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case data(Data)
    /// Nanoseconds since 1970, as XPC keeps a date.
    case date(Int64)
    case uuid(UUID)
    case array([XPCValue])
    case dictionary([String: XPCValue])

    public struct Refusal: Error, Equatable, LocalizedError {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public init(json: JSONValue) throws {
        switch json {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .int(let int): self = .int64(int)
        case .double(let double): self = .double(double)
        case .string(let string):
            guard !string.contains("\0") else { throw Refusal(message: "a string holds a NUL") }
            self = .string(string)
        case .array(let items): self = .array(try items.map(XPCValue.init(json:)))
        case .object(let object):
            if object.count == 1, let (tag, value) = object.first, tag.hasPrefix("$") {
                self = try Self.tagged(tag, value)
            } else {
                // XPC reads a key as a C string: one holding a NUL would end early, as another key.
                guard !object.keys.contains(where: { $0.contains("\0") }) else { throw Refusal(message: "a key holds a NUL") }
                self = .dictionary(try object.mapValues(XPCValue.init(json:)))
            }
        }
    }

    private static func tagged(_ tag: String, _ value: JSONValue) throws -> XPCValue {
        func refuse() -> Refusal { Refusal(message: "\(tag) does not hold what it names") }
        switch (tag, value) {
        case ("$int", .int(let int)): return .int64(int)
        case ("$int", .string(let text)): guard let int = Int64(text) else { throw refuse() }; return .int64(int)
        case ("$uint", .int(let int)): guard int >= 0 else { throw refuse() }; return .uint64(UInt64(int))
        case ("$uint", .string(let text)): guard let uint = UInt64(text) else { throw refuse() }; return .uint64(uint)
        case ("$double", .int(let int)): return .double(Double(int))
        case ("$double", .double(let double)): return .double(double)
        case ("$data", .string(let base64)): guard let data = Data(base64Encoded: base64) else { throw refuse() }; return .data(data)
        case ("$date", .int(let ms)):
            let (ns, overflow) = ms.multipliedReportingOverflow(by: 1_000_000)
            guard !overflow else { throw refuse() }
            return .date(ns)
        case ("$date", .double(let ms)):
            let ns = (ms * 1_000_000).rounded()
            guard ns.isFinite, abs(ns) < 9e18 else { throw refuse() }
            return .date(Int64(ns))
        case ("$uuid", .string(let text)): guard let uuid = UUID(uuidString: text) else { throw refuse() }; return .uuid(uuid)
        case ("$int", _), ("$uint", _), ("$double", _), ("$data", _), ("$date", _), ("$uuid", _): throw refuse()
        // Not a tag: a dictionary with one key that starts with `$`.
        default:
            guard !tag.contains("\0") else { throw Refusal(message: "a key holds a NUL") }
            return .dictionary([tag: try XPCValue(json: value)])
        }
    }

    /// As the plugin reads it: every number tagged, so it knows which it was.
    public var json: JSONValue {
        switch self {
        case .null: .null
        case .bool(let bool): .bool(bool)
        case .int64(let int): .object(["$int": .int(int)])
        case .uint64(let uint): .object(["$uint": uint <= UInt64(Int64.max) ? .int(Int64(uint)) : .string(String(uint))])
        case .double(let double): .object(["$double": .double(double)])
        case .string(let string): .string(string)
        case .data(let data): .object(["$data": .string(data.base64EncodedString())])
        case .date(let ns): .object(["$date": .double(Double(ns) / 1_000_000)])
        case .uuid(let uuid): .object(["$uuid": .string(uuid.uuidString)])
        case .array(let items): .array(items.map(\.json))
        case .dictionary(let entries): .object(entries.mapValues(\.json))
        }
    }
}
