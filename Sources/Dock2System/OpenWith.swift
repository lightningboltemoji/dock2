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

    // MARK: - Remembering

    /// Which files an app picked goes on opening.
    public enum Scope: Equatable, Sendable {
        /// These files alone: the choice is kept on each, which takes write access.
        case files
        /// Every file of their type, after macOS asks the person.
        case type(extension: String)
    }

    /// The scopes `urls` can remember an app for. A type only when they share it and its extension: a file
    /// without one is typed as broadly as "data", which a choice made from one file should not change.
    public static func scopes(for urls: [URL]) -> [Scope] {
        let values = urls.map { try? $0.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey]) }
        guard !urls.isEmpty, values.allSatisfy({ $0?.isDirectory == false }) else { return [] }
        var scopes: [Scope] = []
        if urls.allSatisfy({ FileManager.default.isWritableFile(atPath: $0.path) }) { scopes.append(.files) }
        let extensions = Set(urls.map { $0.pathExtension.lowercased() })
        let types = Set(values.map { $0?.contentType })
        if extensions.count == 1, let pathExtension = extensions.first, !pathExtension.isEmpty, types.count == 1, types.first! != nil {
            scopes.append(.type(extension: pathExtension))
        }
        return scopes
    }

    /// Makes `app` what `urls` open with from now on, and says whether it took. For a type macOS asks first,
    /// and a refusal arrives as an error like any other, so the answer is read back instead.
    @discardableResult
    public static func remember(_ app: URL, for urls: [URL], _ scope: Scope) async -> Bool {
        let workspace = NSWorkspace.shared
        switch scope {
        case .files:
            for url in urls {
                do { try await workspace.setDefaultApplication(at: app, toOpenFileAt: url) } catch { return false }
            }
            return true
        case .type:
            guard let first = urls.first, let type = try? first.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
            if workspace.urlForApplication(toOpen: type).map(identity) != identity(app) {
                try? await workspace.setDefaultApplication(at: app, toOpenContentTypeOfFileAt: first)
                guard workspace.urlForApplication(toOpen: type).map(identity) == identity(app) else { return false }
            }
            // A file's own app outranks its type's, and these are to follow the type.
            for url in urls where hasOwnApp(url) { forgetOwnApp(url) }
            return true
        }
    }

    /// Whether `url` names an app of its own, which LaunchServices prefers to its type's.
    public static func hasOwnApp(_ url: URL) -> Bool {
        getxattr(url.path, ownAppKey, nil, 0, 0, 0) > 0
    }

    /// Where LaunchServices keeps a file's own app. No API clears it.
    private static let ownAppKey = "com.apple.LaunchServices.OpenWith"

    private static func forgetOwnApp(_ url: URL) {
        removexattr(url.path, ownAppKey, 0)
        // LaunchServices answers from the URL's cached values until they are dropped.
        var url = url
        url.removeAllCachedResourceValues()
    }
}
