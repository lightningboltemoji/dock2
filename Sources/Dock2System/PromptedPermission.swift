import ApplicationServices
import CoreGraphics
import Foundation

/// A permission macOS asks about with a prompt of its own ([permissions](product/system/permissions.md)): the
/// prompt is the way to it while the question is open, and its pane in System Settings once it is answered.
public enum PromptedPermission: Sendable {
    case accessibility, screenRecording

    public enum Answer: Sendable {
        case allowed
        /// Listed in its pane, switched off: a request may not prompt again.
        case off
        /// Never put: the request prompts.
        case unasked
    }

    /// Whether macOS lets dock2 do it now. Asking this asks nobody.
    public var isAllowed: Bool {
        switch self {
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }

    /// Only TCC's preflight (private) tells a question never put from one answered; without it, a permission not
    /// allowed reads as unasked.
    public var answer: Answer {
        guard !isAllowed else { return .allowed }
        guard let preflight = Self.preflight else { return .unasked }
        return preflight(service as CFString, nil) == 2 ? .unasked : .off
    }

    /// macOS's prompt, which lists dock2 in the pane, off, however it is answered.
    public func request() {
        switch self {
        case .accessibility: _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        }
    }

    /// Its pane in Privacy & Security.
    public var pane: URL {
        switch self {
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }

    private var service: String {
        switch self {
        case .accessibility: "kTCCServiceAccessibility"
        case .screenRecording: "kTCCServiceScreenCapture"
        }
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    nonisolated(unsafe) private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY)
    /// 0 allowed, 1 answered otherwise, 2 never asked.
    private static let preflight = tcc.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: Preflight.self) }
}
