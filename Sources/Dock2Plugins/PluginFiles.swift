import Darwin
import Dock2Core
import Foundation

/// What `files` does, off the main thread, to a path `PathGuard` has resolved inside a granted folder. The
/// last step is never followed if it has become a link since: opened with `O_NOFOLLOW`, replaced by `rename`.
enum PluginFiles {
    /// The most one read carries, whatever it asks.
    static let readLimit = 8 << 20
    /// The most entries one listing carries.
    static let listLimit = 10_000

    static func read(_ path: String, offset: Int, length: Int?) throws -> (data: Data, size: Int) {
        // Not blocking: a FIFO would wait for a writer, and every plugin's files wait behind it.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw PluginFailure("not a file") }
        let size = Int(info.st_size), start = max(0, offset)
        let count = max(0, min(length ?? readLimit, readLimit, size - start))
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(start)) }
        guard read >= 0 else { throw failure() }
        return (data.prefix(read), size)
    }

    static func list(_ path: String) throws -> (entries: [PluginFileEntry], truncated: Bool) {
        let names = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        let entries = names.prefix(listLimit).compactMap { entry((path as NSString).appendingPathComponent($0)) }
        return (entries, names.count > listLimit)
    }

    /// What is there, without following a link: nil for nothing.
    static func entry(_ path: String) -> PluginFileEntry? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind: PluginFileEntry.Kind = switch info.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .folder
        case S_IFLNK: .link
        default: .other
        }
        let modified = Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1_000_000
        return PluginFileEntry(name: (path as NSString).lastPathComponent, path: path, kind: kind, size: kind == .file ? Int(info.st_size) : nil,
                         modified: modified)
    }

    /// Replaced whole, through a file beside it renamed over it, or appended to; the folders it lacks made.
    static func write(_ data: Data, to path: String, append: Bool) throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        if entry(path)?.kind == .folder { throw PluginFailure("a folder is there") }
        if append {
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o644)
            guard fd >= 0 else { throw failure() }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw PluginFailure("not a file") }
            try writeAll(data, to: fd)
            return
        }
        let temporary = (folder as NSString).appendingPathComponent(".\((path as NSString).lastPathComponent).dock2-\(UUID().uuidString)")
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw failure() }
        do {
            try writeAll(data, to: fd)
        } catch {
            close(fd)
            unlink(temporary)
            throw error
        }
        close(fd)
        guard rename(temporary, path) == 0 else {
            let failed = failure()
            unlink(temporary)
            throw failed
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw failure() }
                offset += written
            }
        }
    }

    private static func failure() -> PluginFailure {
        PluginFailure(String(cString: strerror(errno)).lowercased())
    }
}
