import Foundation

/// The Files source's own signal, after how a name matched ([file search](../../.agents/product/search/files.md#ranking)):
/// recency, place, depth, and noise sinking below everything.
public enum FileRanking {
    /// Path components that mark dependency, build and cache trees.
    public static let noise: Set<String> = ["node_modules", ".build", "DerivedData", "Caches", ".git", "Pods", "build", "dist", "target",
                                            "out", "obj"]

    /// Higher first. `near` are the places that rank first: the home folders and any the user names.
    public static func signal(path: String, lastUsed: Date?, modified: Date?, home: String, near: [String], now: Date) -> Double {
        let components = path.split(separator: "/").map(String.init)
        // Hidden folders and the noise trees sink below everything else; the file's own name does not count.
        if components.dropLast().contains(where: { $0.hasPrefix(".") || noise.contains($0) }) { return -100 + recency(lastUsed, modified, now) }
        var place = 0.0
        if near.contains(where: { path.hasPrefix($0 + "/") }) {
            place = 2
        } else if path.hasPrefix("/System/") || path.hasPrefix("/Library/") || path.hasPrefix(home + "/Library/") {
            place = -2
        } else if path.hasPrefix(home + "/") {
            place = 1
        }
        let depth = Double(components.count)
        return place + recency(lastUsed, modified, now) - depth * 0.02
    }

    /// 1 for now, falling off over a month. A file opened from a terminal has no last-used date, so
    /// modification counts as much.
    private static func recency(_ lastUsed: Date?, _ modified: Date?, _ now: Date) -> Double {
        guard let latest = [lastUsed, modified].compactMap({ $0 }).max() else { return 0 }
        let days = max(0, now.timeIntervalSince(latest) / 86_400)
        return 1 / (1 + days / 30)
    }

    /// The query string for `MDQuery`: each word must begin a word of the display name, apps excluded.
    public static func queryString(_ query: Query, usedWithin days: Int? = nil) -> String {
        var clauses = query.words.map { "kMDItemDisplayName == \"\(escape($0))*\"cdw" }
        clauses.append("kMDItemContentTypeTree != \"com.apple.application\"")
        if let days { clauses.append("kMDItemLastUsedDate >= $time.today(-\(days))") }
        return clauses.joined(separator: " && ")
    }

    private static func escape(_ word: String) -> String {
        var escaped = ""
        for character in word {
            if "\\\"*?".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// `~/` for the home folder, for a subtitle.
    public static func abbreviate(_ path: String, home: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
