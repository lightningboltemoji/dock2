import AppKit

/// The system's display settings dock2 follows ([visual](product/visual.md#the-systems-display-settings)).
/// For development, `DOCK2_REDUCE_MOTION`, `DOCK2_REDUCE_TRANSPARENCY` and `DOCK2_INCREASE_CONTRAST` turn each on.
@MainActor
enum DisplayOptions {
    static var reduceMotion: Bool { forced("DOCK2_REDUCE_MOTION") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool {
        forced("DOCK2_REDUCE_TRANSPARENCY") || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    static var increaseContrast: Bool { forced("DOCK2_INCREASE_CONTRAST") || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    /// Told when the user changes any of them.
    static func observe(_ changed: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { _ in MainActor.assumeIsolated { changed() } }
    }

    private static func forced(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment[name] == "1"
    }
}
