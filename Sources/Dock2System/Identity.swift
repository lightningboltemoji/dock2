import Foundation

public enum Dock2Identity {
    /// Also the name of dock2's defaults domain.
    public static let bundleIdentifier = "zip.tanner.dock2"

    /// The version `make app` stamped into the enclosing bundle, from the git tag; `dev` out of `.build`.
    public static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    /// The executable `path` links to, when that is dock2's own inside its bundle; nil for anything else.
    /// `Bundle.main` does not follow a link, so run through one dock2 would not know it is the app.
    public static func bundledExecutable(linkedAt path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let real = URL(fileURLWithPath: String(cString: resolved))
        let bundle = real.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard real.path != path, Bundle(url: bundle)?.bundleIdentifier == bundleIdentifier else { return nil }
        return real.path
    }
}
