import AppKit
import UniformTypeIdentifiers

/// Copy Contents ([operations](product/files/operations.md#the-clipboard)): a file's text, or its picture,
/// for any app to paste.
public enum FileContents {
    public enum Kind: Sendable, Equatable { case text, image }

    public enum Contents: Sendable, Equatable {
        case text(String)
        /// The file's own bytes under its type, then a PNG of it for apps that take no other kind.
        case image([Representation])
    }

    public struct Representation: Sendable, Equatable {
        public let type: String
        public let data: Data
    }

    /// Past this Files asks first: a file this big on the clipboard is likely a mistake.
    public static let askAbove: Int64 = 10_000_000

    /// What judging a file by its first bytes reads of it.
    static let sniffLength = 8192
    static let imageTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])

    /// An image macOS can read, or text: by its type, else by its first bytes, since `.gitignore`, `.env`
    /// and TypeScript's `.ts` have no text type. Rich text is not offered: its markup is not its contents.
    /// A file not on this Mac (`local` false) is judged by its type alone: reading it would download it.
    public static func kind(of url: URL, local: Bool = true) -> Kind? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if let type {
            if imageTypes.contains(type.identifier) { return .image }
            if type.conforms(to: .rtf) { return nil }
            if type.conforms(to: .text) { return .text }
        }
        guard local, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: sniffLength)) ?? Data()
        return isText(head, whole: head.count < sniffLength) ? .text : nil
    }

    /// UTF-8 without a NUL; cut short, a character may be cut off at the end.
    static func isText(_ data: Data, whole: Bool) -> Bool {
        guard !data.contains(0) else { return false }
        return (0...(whole ? 0 : min(3, data.count))).contains { String(data: data.dropLast($0), encoding: .utf8) != nil }
    }

    /// Reads the whole file: slow for a large one, so off the main thread.
    public static func read(_ url: URL, as kind: Kind) throws -> Contents {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        switch kind {
        case .text:
            guard let text = decode(data) else {
                throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSURLErrorKey: url, NSFilePathErrorKey: url.path])
            }
            return .text(text)
        case .image:
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier ?? UTType.data.identifier
            var representations = [Representation(type: type, data: data)]
            if type != UTType.png.identifier, let png = png(data) { representations.append(Representation(type: UTType.png.identifier, data: png)) }
            return .image(representations)
        }
    }

    /// UTF-16 by its byte order mark; otherwise UTF-8, its mark dropped.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        return String(data: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data, encoding: .utf8)
    }

    /// Its first image, oriented as its metadata says.
    static func png(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// Onto a pasteboard already cleared: Files writes through `OwnWrite`.
    @MainActor
    public static func write(_ contents: Contents, to pasteboard: NSPasteboard) {
        switch contents {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .image(let representations):
            let item = NSPasteboardItem()
            for representation in representations { item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type)) }
            pasteboard.writeObjects([item])
        }
    }
}
