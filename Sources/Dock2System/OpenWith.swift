import AppKit

/// Open With's apps, from LaunchServices as Finder's are: the default first, then the rest by name, each
/// app once however many copies of it are installed.
@MainActor
public enum OpenWith {
    /// The apps that open every one of `urls`; `preferred` is the first one's default, if it opens them all.
    public static func apps(for urls: [URL]) -> (preferred: URL?, others: [URL]) {
        guard let first = urls.first else { return (nil, []) }
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
        for url in urls.dropFirst() {
            let opening = Set(NSWorkspace.shared.urlsForApplications(toOpen: url).map(\.standardizedFileURL))
            apps.removeAll { !opening.contains($0.standardizedFileURL) }
        }
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: first).flatMap { app in
            apps.first { $0.standardizedFileURL == app.standardizedFileURL }
        }
        // LaunchServices lists the copy to prefer first.
        var seen = Set(preferred.map { [identity($0)] } ?? [])
        let others = apps.filter { seen.insert(identity($0)).inserted }
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        return (preferred, others)
    }

    /// "Xcode", as a menu names it.
    public static func name(_ app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private static func identity(_ app: URL) -> String {
        Bundle(url: app)?.bundleIdentifier ?? app.standardizedFileURL.path
    }
}
