import Dock2Core
import Foundation

/// What could not be done to an item, in words, and what would let it ([operations](product/files/operations.md#errors)).
public struct FileProblem: Sendable, Equatable {
    public enum Remedy: Sendable, Equatable {
        /// macOS's privacy rules kept dock2 out, and Full Disk Access would let it in.
        case allowAccess
        /// Finder may manage what dock2 cannot: a file's permissions, a password, a locked item.
        case openInFinder
        case none
    }

    /// The row it belongs on, when there is one.
    public let item: URL?
    public let message: String
    public let remedy: Remedy

    public init(_ error: Error, item: URL? = nil, hasFullDiskAccess: Bool = FileAccess.hasFullDiskAccess) {
        let about = error as? ItemError
        let cause = about?.error ?? error
        self.item = (item ?? about?.item)?.canonical
        let codes = Self.codes(cause)
        let locked = self.item.map(Self.isLocked) == true
        // Said plainly: Cocoa's sentence for a locked file is about permissions.
        message = locked && codes.contains(where: { $0 == (NSPOSIXErrorDomain, Int(EPERM)) })
            ? "“\(self.item!.lastPathComponent)” is locked." : cause.localizedDescription
        // A privacy denial is EPERM; a file's own permissions, EACCES — and a locked file's flag, EPERM too.
        if codes.contains(where: { $0 == (NSPOSIXErrorDomain, Int(EPERM)) }) {
            remedy = hasFullDiskAccess || locked ? .openInFinder : .allowAccess
        } else if codes.contains(where: { $0 == (NSPOSIXErrorDomain, Int(ENOENT)) || $0 == (NSCocoaErrorDomain, CocoaError.fileNoSuchFile.rawValue)
                                          || $0 == (NSCocoaErrorDomain, CocoaError.fileReadNoSuchFile.rawValue) }) {
            remedy = .none
        } else {
            remedy = .openInFinder
        }
    }

    /// Locked in Finder's Get Info (`uchg`), or by the system (`schg`).
    static func isLocked(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.immutable] as? Bool) == true
    }

    /// The error's domain and code, then its underlying error's, and so on.
    private static func codes(_ error: Error) -> [(String, Int)] {
        var codes: [(String, Int)] = []
        var next: NSError? = error as NSError
        while let error = next, codes.count < 8 {
            codes.append((error.domain, error.code))
            next = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return codes
    }
}

/// An error about one item of several, so its problem goes on that item's row.
struct ItemError: LocalizedError {
    let item: URL
    let error: Error

    var errorDescription: String? { error.localizedDescription }

    static func about<T>(_ item: URL, _ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch let error as ItemError {
            throw error
        } catch {
            throw ItemError(item: item, error: error)
        }
    }
}
