import AppKit
import ApplicationServices
import CoreGraphics

/// A permission macOS asks about with a prompt of its own ([permissions](product/system/permissions.md)). Its
/// prompt is what lists dock2 in its pane in System Settings, where an answer is changed.
public enum PromptedPermission: Sendable {
    case accessibility, screenRecording, pasteFromOtherApps

    public enum Answer: Sendable {
        case allowed
        /// Listed in its pane, switched off.
        case off
        /// Listed in its pane, set to ask at each use.
        case asks
        /// Never put: not listed in its pane until a request prompts.
        case unasked
    }

    /// Whether macOS lets dock2 do it now. Asking this asks nobody.
    public var isAllowed: Bool {
        switch self {
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .pasteFromOtherApps: NSPasteboard.general.accessBehavior == .alwaysAllow
        }
    }

    public var answer: Answer {
        switch self {
        case .accessibility: Self.answer(isAllowed, service: "kTCCServiceAccessibility")
        case .screenRecording: Self.answer(isAllowed, service: "kTCCServiceScreenCapture")
        case .pasteFromOtherApps:
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: .allowed
            case .ask: .asks
            case .alwaysDeny: .off
            default: .unasked
            }
        }
    }

    /// Whether `request` brings up macOS's prompt: Accessibility's comes back until it is allowed, the others' once.
    public func prompts(at answer: Answer) -> Bool {
        answer == .unasked || (self == .accessibility && answer != .allowed)
    }

    /// macOS's prompt, which lists dock2 in the pane however it is answered.
    public func request() {
        switch self {
        case .accessibility: _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        case .pasteFromOtherApps:
            // A read of what is there, off the main thread while the alert waits; an empty pasteboard raises nothing.
            DispatchQueue.global(qos: .userInitiated).async {
                guard let item = NSPasteboard.general.pasteboardItems?.first, let type = item.types.first else { return }
                _ = item.data(forType: type)
            }
        }
    }

    /// Its pane in Privacy & Security.
    public var pane: URL {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .pasteFromOtherApps: "Privacy_Pasteboard"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// Only TCC's preflight (private) tells a question never put from one answered; without it, a permission not
    /// allowed reads as unasked.
    private static func answer(_ allowed: Bool, service: String) -> Answer {
        guard !allowed else { return .allowed }
        guard let preflight else { return .unasked }
        return preflight(service as CFString, nil) == 2 ? .unasked : .off
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    nonisolated(unsafe) private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY)
    /// 0 allowed, 1 answered otherwise, 2 never asked.
    private static let preflight = tcc.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: Preflight.self) }
}
