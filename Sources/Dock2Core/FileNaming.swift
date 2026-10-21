import Foundation

/// Finder's order for a folder's items: folders first, then names as Finder sorts them — numbers by value,
/// case and diacritics ignored.
public enum FinderOrder {
    public static func precedes(_ a: (name: String, isFolder: Bool), _ b: (name: String, isFolder: Bool)) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        // Names equal but for case: a stable order all the same.
        case .orderedSame: return a.name < b.name
        }
    }

    public static func sorted<T>(_ items: [T], name: (T) -> String, isFolder: (T) -> Bool) -> [T] {
        items.sorted { precedes((name($0), isFolder($0)), (name($1), isFolder($1))) }
    }
}

/// The names Finder gives copies ([operations](product/files/operations.md)).
public enum CopyNaming {
    /// ⌘D: "name copy.ext", then "name copy 2.ext"; a copy's copy counts on from it.
    public static func duplicate(_ name: String, isFolder: Bool, taken: (String) -> Bool) -> String {
        let (base, ext) = split(name, isFolder: isFolder)
        var stem = base
        var next = 1
        if let match = base.wholeMatch(of: /(.+) copy(?: (\d+))?/) {
            stem = String(match.1)
            next = (match.2.flatMap { Int($0) } ?? 1) + 1
        }
        while true {
            let candidate = join(next == 1 ? "\(stem) copy" : "\(stem) copy \(next)", ext)
            if !taken(candidate) { return candidate }
            next += 1
        }
    }

    /// Keep Both, for a name already taken where it lands: "name 2.ext", "name 3.ext".
    public static func keepBoth(_ name: String, isFolder: Bool, taken: (String) -> Bool) -> String {
        let (base, ext) = split(name, isFolder: isFolder)
        var stem = base
        var next = 2
        if let match = base.wholeMatch(of: /(.+) (\d+)/), let number = Int(match.2) {
            stem = String(match.1)
            next = number + 1
        }
        while true {
            let candidate = join("\(stem) \(next)", ext)
            if !taken(candidate) { return candidate }
            next += 1
        }
    }

    /// A new folder: "untitled folder", then "untitled folder 2".
    public static func newFolder(taken: (String) -> Bool) -> String {
        let name = "untitled folder"
        return taken(name) ? keepBoth(name, isFolder: true, taken: taken) : name
    }

    /// A file's extension is what follows its last dot, unless it has a space in it or nothing before it;
    /// a folder has none.
    static func split(_ name: String, isFolder: Bool) -> (base: String, ext: String?) {
        guard !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, nil) }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, !ext.contains(" ") else { return (name, nil) }
        return (String(name[..<dot]), String(ext))
    }

    private static func join(_ base: String, _ ext: String?) -> String {
        ext.map { "\(base).\($0)" } ?? base
    }
}

/// A path typed into the field: `~` or `/` first ([files](product/files/README.md#layout)).
public enum PathInput {
    public static func isPath(_ text: String) -> Bool {
        text.hasPrefix("~") || text.hasPrefix("/")
    }

    /// The path with `~` expanded; "" and "~" are home.
    public static func expand(_ text: String, home: String) -> String {
        if text == "~" { return home }
        if text.hasPrefix("~/") { return home + text.dropFirst() }
        return text
    }

    /// The folder a typed path is in, and what is typed of the name in it: "~/Dev/do" is ("/Users/x/Dev", "do").
    public static func split(_ text: String, home: String) -> (folder: String, partial: String) {
        let path = expand(text, home: home)
        guard let slash = path.lastIndex(of: "/") else { return (home, path) }
        let folder = String(path[...slash])
        return (folder.count > 1 ? String(folder.dropLast()) : folder, String(path[path.index(after: slash)...]))
    }

    /// Tab: the typed name taken as far as every entry it begins agrees, case ignored, with "/" after a
    /// single folder. Hidden names only when a dot is typed. Unchanged when nothing matches.
    public static func complete(_ text: String, entries: [(name: String, isFolder: Bool)]) -> String {
        let slash = text.lastIndex(of: "/")
        let typed = slash.map { String(text[text.index(after: $0)...]) } ?? (text.hasPrefix("~") ? "" : text)
        guard text != "~" else { return "~/" }
        let matches = entries.filter {
            (typed.hasPrefix(".") || !$0.name.hasPrefix(".")) && $0.name.lowercased().hasPrefix(typed.lowercased())
        }
        guard let first = matches.first else { return text }
        var common = first.name
        for match in matches.dropFirst() {
            common = String(zip(common, match.name).prefix { $0.lowercased() == $1.lowercased() }.map(\.0))
        }
        let head = slash.map { String(text[...$0]) } ?? ""
        let completed = head + common
        return matches.count == 1 && first.isFolder ? completed + "/" : completed
    }
}
