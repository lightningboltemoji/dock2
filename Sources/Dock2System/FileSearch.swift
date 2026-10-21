import CoreServices
import Dock2Core
import Foundation

/// The Spotlight index, through `MDQuery` ([file search](product/search/files.md)). Queries run on a queue of
/// their own and are capped; a search is cancelled by dropping its token.
public final class FileSearch: Sendable {
    public struct Hit: Sendable, Equatable {
        public let path: String
        public let name: String
        public let lastUsed: Date?
        public let modified: Date?
        public let isFolder: Bool
    }

    /// Where a short query looks, and whether the protected folders may be named: scoping a query to one of
    /// them raises macOS's prompt when dock2 has no access.
    public struct Scope: Sendable {
        public var near: [String]
        public init(near: [String]) { self.near = near }
    }

    public final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        public func cancel() { lock.withLock { cancelled = true } }
    }

    private let queue = DispatchQueue(label: "zip.tanner.dock2.files", qos: .userInitiated, attributes: .concurrent)
    /// The most hits one query gathers before dock2 ranks them.
    private let cap = 2000

    public init() {}

    /// Runs `query` and calls `deliver` once, on the main actor, with every hit gathered — unless cancelled.
    /// One or two characters search the near places and what was opened in the last 90 days; three or more,
    /// the whole index.
    public func search(_ query: Query, scope: Scope, deliver: @escaping @MainActor @Sendable ([Hit]) -> Void) -> Token {
        let token = Token()
        let cap = self.cap
        queue.async {
            let short = query.folded.count < 3
            var hits: [Hit] = []
            if short {
                if !scope.near.isEmpty { hits += Self.run(FileRanking.queryString(query), scopes: scope.near, cap: cap, token: token) }
                hits += Self.run(FileRanking.queryString(query, usedWithin: 90), scopes: [kMDQueryScopeComputer as String], cap: cap, token: token)
            } else {
                hits = Self.run(FileRanking.queryString(query), scopes: [kMDQueryScopeComputer as String], cap: cap, token: token)
            }
            guard !token.isCancelled else { return }
            var seen = Set<String>()
            let unique = hits.filter { seen.insert($0.path).inserted }
            DispatchQueue.main.async { if !token.isCancelled { deliver(unique) } }
        }
        return token
    }

    /// Files' ⌘F: `folder` and the folders inside it, through Spotlight and — for what it has not indexed,
    /// as `/tmp` — a walk of the folder, stopped after `walkLimit` items or a second and a half, passing over
    /// the folders `closed` names, since looking in one would ask. `deliver` hears every hit once, on the main actor.
    public func search(_ query: Query, within folder: String?, showsHidden: Bool, closed: @escaping @Sendable (URL) -> Bool = { _ in false },
                       deliver: @escaping @MainActor @Sendable ([Hit]) -> Void) -> Token {
        let token = Token()
        let cap = self.cap
        queue.async {
            var hits = Self.run(FileRanking.queryString(query), scopes: [folder ?? (kMDQueryScopeComputer as String)], cap: cap, token: token)
            if let folder { hits += Self.walk(folder, matching: query, showsHidden: showsHidden, closed: closed, token: token) }
            guard !token.isCancelled else { return }
            var seen = Set<String>()
            let unique = hits.filter { seen.insert($0.path).inserted }
            DispatchQueue.main.async { if !token.isCancelled { deliver(unique) } }
        }
        return token
    }

    static let walkLimit = 50_000

    private static func walk(_ folder: String, matching query: Query, showsHidden: Bool, closed: (URL) -> Bool, token: Token) -> [Hit] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
                                                          options: showsHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let deadline = Date().addingTimeInterval(1.5)
        // The walker resolves links in the folder's path, /tmp becoming /private/tmp: hits keep the folder's.
        let resolved = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        var hits: [Hit] = []
        var seen = 0
        while let url = walker.nextObject() as? URL {
            seen += 1
            if seen % 500 == 0, token.isCancelled || Date() > deadline { break }
            if seen > walkLimit { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, closed(url) { walker.skipDescendants() }
            let name = url.lastPathComponent
            guard Matcher.match(query, name) != nil else { continue }
            var path = url.path
            if !path.hasPrefix(folder + "/"), path.hasPrefix(resolved + "/") { path = folder + path.dropFirst(resolved.count) }
            hits.append(Hit(path: path, name: name, lastUsed: nil, modified: values?.contentModificationDate, isFolder: values?.isDirectory == true))
        }
        return hits
    }

    private static func run(_ string: String, scopes: [String], cap: Int, token: Token) -> [Hit] {
        guard !token.isCancelled,
              let query = MDQueryCreate(kCFAllocatorDefault, string as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(query, scopes as CFArray, 0)
        MDQuerySetMaxCount(query, cap)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var hits: [Hit] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let name = MDItemCopyAttribute(item, kMDItemDisplayName) as? String ?? (path as NSString).lastPathComponent
            let types = MDItemCopyAttribute(item, kMDItemContentTypeTree) as? [String] ?? []
            hits.append(Hit(path: path, name: name, lastUsed: MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date,
                            modified: MDItemCopyAttribute(item, kMDItemContentModificationDate) as? Date,
                            isFolder: types.contains("public.folder")))
        }
        return hits
    }
}
