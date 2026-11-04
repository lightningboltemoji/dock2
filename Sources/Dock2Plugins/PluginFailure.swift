import Foundation

/// Why something a plugin asked for was not done, in words the plugin hears as its `error`.
struct PluginFailure: Error, Equatable, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
