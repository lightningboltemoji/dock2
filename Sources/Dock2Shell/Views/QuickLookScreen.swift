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
        // The whole sheet, whose corners round it: both start empty and grow together.
        preview = QLPreviewView(frame: .zero, style: .normal)!
        preview.autoresizingMask = [.width, .height]
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
