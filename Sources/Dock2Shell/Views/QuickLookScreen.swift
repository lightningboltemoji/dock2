import AppKit
import Dock2Core
import Quartz

/// Quick Look on the panel's stack ([search](product/search/files.md#actions)): the file at Files' size, the
/// field dimmed beneath it; Esc goes back.
@MainActor
final class QuickLookScreen: Screen {
    let view = NSView()
    private let preview: QLPreviewView
    let title: String?
    var size: CGSize? { PanelMetrics.filesSize }
    let usesField = false
    let isLoading = false
    var onChange: (() -> Void)?

    init(_ url: URL) {
        title = FileManager.default.displayName(atPath: url.path)
        preview = QLPreviewView(frame: CGRect(origin: .zero, size: PanelMetrics.filesSize).insetBy(dx: 10, dy: 10), style: .normal)!
        preview.autoresizingMask = [.width, .height]
        preview.wantsLayer = true
        // Inset, with corners of its own: the panel's are rounder than a preview's square edge.
        preview.layer?.cornerRadius = 18.5
        preview.layer?.cornerCurve = .continuous
        preview.layer?.masksToBounds = true
        preview.previewItem = url as NSURL
        view.addSubview(preview)
    }

    func filter(_ text: String) {}
    func command(_ selector: Selector) -> Bool { false }
    func keyEquivalent(_ event: NSEvent) -> Bool { false }

    func closed() {
        preview.close()
    }
}
