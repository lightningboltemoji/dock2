import Foundation

public enum Dock2Identity {
    /// Also the name of dock2's defaults domain.
    public static let bundleIdentifier = "zip.tanner.dock2"

    /// The version `make app` stamped into the enclosing bundle, from the git tag; `dev` out of `.build`.
    public static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}
