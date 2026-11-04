import Foundation

/// A path a plugin names, held to the folders it was granted: absolute, never through `..`, and inside a
/// granted folder once every symbolic link along it is followed. The answer is the path as the file system
/// reaches it, which is the one to use.
public struct PathGuard: Sendable {
    public enum Refusal: Error, Equatable, LocalizedError {
        case notAbsolute(String), climbs(String), outside(String), noFolders

        public var errorDescription: String? {
            switch self {
            case .notAbsolute(let path): "\(path) is not an absolute path"
            case .climbs(let path): "\(path) climbs out with .."
            case .outside(let path): "\(path) is not inside a folder it was granted"
            case .noFolders: "no folder is chosen for it in Settings → Plugins"
            }
        }
    }

    /// The granted folders, as the file system reaches them; one that is not there grants nothing.
    public let roots: [String]

    public init(folders: [String]) {
        roots = folders.compactMap { folder in
            guard folder.hasPrefix("/"), !folder.split(separator: "/").contains("..") else { return nil }
            return Self.real(folder)
        }
    }

    /// `path` as the file system reaches it, if that is inside a granted folder. A path not there yet — a file
    /// about to be written — is its deepest existing folder's, resolved, and the rest; a link at the first
    /// missing step, dangling, is refused, since writing there would follow it out.
    public func reach(_ path: String) throws -> String {
        guard !roots.isEmpty else { throw Refusal.noFolders }
        guard path.hasPrefix("/"), !path.contains("\0") else { throw Refusal.notAbsolute(path) }
        var parts = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !parts.contains("..") else { throw Refusal.climbs(path) }
        var rest: [String] = []
        while true {
            let candidate = "/" + parts.joined(separator: "/")
            if let real = Self.real(candidate) {
                let reached = ([real == "/" ? "" : real] + rest).joined(separator: "/")
                let full = reached.isEmpty ? "/" : reached
                guard roots.contains(where: { Self.isInside(full, $0) }) else { throw Refusal.outside(path) }
                return full
            }
            var info = stat()
            guard lstat(candidate, &info) != 0, let last = parts.popLast() else { throw Refusal.outside(path) }
            rest.insert(last, at: 0)
        }
    }

    public func admits(_ path: String) -> Bool {
        (try? reach(path)) != nil
    }

    static func isInside(_ path: String, _ root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }

    /// realpath(3): every link followed, nil where the path does not lead anywhere.
    static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// A declared command, its slots filled with the values the plugin names, to the argv dock2 runs — or why not.
/// A slot is one argument and never starts with `-`; a path or a folder lies inside a folder the plugin's folder
/// settings hold. A command that takes any arguments takes the plugin's as they are.
public enum CommandGuard {
    public enum Refusal: Error, Equatable, LocalizedError {
        case missing(RunCommand.Slot), dash(RunCommand.Slot), nul, arguments, noArguments, path(RunCommand.Slot, PathGuard.Refusal)

        public var errorDescription: String? {
            switch self {
            case .missing(let slot): "its {\(slot.rawValue)} has no value"
            case .dash(let slot): "its {\(slot.rawValue)} starts with -, which a program would read as an option"
            case .nul: "an argument holds a NUL"
            case .arguments: "it takes no arguments but its own: name its slots' values"
            case .noArguments: "it takes any arguments: give them"
            case .path(let slot, let refusal): "its {\(slot.rawValue)}: \(refusal.localizedDescription)"
            }
        }
    }

    public struct Invocation: Equatable, Sendable {
        public let program: String
        /// After the program's own name.
        public let arguments: [String]
        /// Its `{folder}`, else nil: the home folder.
        public let directory: String?

        public init(program: String, arguments: [String], directory: String?) {
            self.program = program
            self.arguments = arguments
            self.directory = directory
        }
    }

    public static func invocation(of command: RunCommand, values: [String: String], arguments given: [String]?, folders: PathGuard) throws -> Invocation {
        guard let declared = command.arguments else {
            guard let given else { throw Refusal.noArguments }
            guard !given.contains(where: { $0.contains("\0") }) else { throw Refusal.nul }
            return Invocation(program: command.program, arguments: given, directory: nil)
        }
        guard given == nil else { throw Refusal.arguments }
        var directory: String?
        let arguments = try declared.map { argument -> String in
            guard case .slot(let slot) = argument else { return argument.spelling }
            guard let value = values[slot.rawValue] else { throw Refusal.missing(slot) }
            guard !value.contains("\0") else { throw Refusal.nul }
            guard !value.hasPrefix("-") else { throw Refusal.dash(slot) }
            guard slot != .text else { return value }
            let reached: String
            do { reached = try folders.reach(value) } catch let refusal as PathGuard.Refusal { throw Refusal.path(slot, refusal) }
            if slot == .folder { directory = reached }
            return reached
        }
        return Invocation(program: command.program, arguments: arguments, directory: directory)
    }
}

/// `host:port`, as `local-network` names them.
public struct HostPort: Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host.lowercased()
        self.port = port
    }

    /// `localhost:11434`, `[::1]:8080`.
    public init?(_ spelling: String) {
        let spelling = spelling.lowercased()
        let host: Substring, port: Substring
        if spelling.hasPrefix("[") {
            guard let close = spelling.firstIndex(of: "]"), spelling[spelling.index(after: close)...].hasPrefix(":") else { return nil }
            host = spelling[spelling.index(after: spelling.startIndex)..<close]
            port = spelling[spelling.index(close, offsetBy: 2)...]
        } else {
            guard let colon = spelling.lastIndex(of: ":") else { return nil }
            host = spelling[..<colon]
            port = spelling[spelling.index(after: colon)...]
        }
        guard !host.isEmpty, let number = UInt16(port), number > 0 else { return nil }
        self.init(host: String(host), port: number)
    }

    /// A setting's value: `http://nas.local:5000/`, or `nas.local:5000`; HTTP's port when it names none.
    public init?(setting value: String) {
        if let url = URL(string: value), let host = url.host, url.scheme != nil {
            guard let port = UInt16(exactly: url.port ?? 80), port > 0 else { return nil }
            self.init(host: host, port: port)
        } else {
            self.init(value)
        }
    }

    public var spelled: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    /// On this Mac or the local network, by its spelling: localhost, a `.local` name, a name without a domain,
    /// or an address that is loopback, private or link-local.
    public var isLocal: Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if let local = Self.isLocalAddress(host) { return local }
        return !host.contains(".")
    }

    /// Whether an address literal is loopback, private or link-local; nil for a name.
    public static func isLocalAddress(_ literal: String) -> Bool? {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            switch (bytes[0], bytes[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        if inet_pton(AF_INET6, literal, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }
            if bytes[0] & 0xfe == 0xfc { return true }
            // An IPv4 address mapped into IPv6.
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return isLocalAddress(bytes[12...].map(String.init).joined(separator: "."))
            }
            return false
        }
        return nil
    }
}
