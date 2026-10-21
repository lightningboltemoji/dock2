import Foundation

/// A `Codable` value kept as JSON in dock2's folder, written atomically.
public struct JSONFile<Value: Codable> {
    public let url: URL

    public init(_ name: String, in directory: URL = Paths.directory) {
        url = directory.appendingPathComponent(name)
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder.iso8601.decode(Value.self, from: data)
        } catch {
            warn("\(url.lastPathComponent) is unreadable, starting afresh: \(error.localizedDescription)")
            return nil
        }
    }

    public func save(_ value: Value) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.iso8601.encode(value).write(to: url, options: .atomic)
        } catch {
            warn("could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

extension JSONDecoder {
    /// dock2's JSON: dates as ISO 8601.
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    /// dock2's JSON: dates as ISO 8601, keys sorted so a file diffs cleanly.
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
