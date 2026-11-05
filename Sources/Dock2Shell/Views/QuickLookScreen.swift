import AppKit
import Dock2Core
import Quartz

/// Quick Look on the panel's stack ([search](product/search/files.md#actions)): the file at Files' size, the
/// field dimmed beneath it; Esc goes back.
@MainActor
final class QuickLookScreen: Screen {
    private let card: QuickLookCard
    var view: NSView { card }
    let title: String?
    var size: CGSize? { PanelMetrics.filesSize }
    let usesField = false
    let isLoading = false
    var onChange: (() -> Void)?

    init(_ url: URL) {
        title = FileManager.default.displayName(atPath: url.path)
        card = QuickLookCard(url)
    }

    func filter(_ text: String) {}
    func command(_ selector: Selector) -> Bool { false }
    func keyEquivalent(_ event: NSEvent) -> Bool { false }

    func closed() {
        card.close()
    }
}

/// A file's Quick Look on the pane, as a card: it draws up to its own edges, where the pane's corners would cut it. Fills
/// the view it is given, which may start empty and grow.
@MainActor
final class QuickLookCard: NSView {
    private let card = NSView()
    private let preview: QLPreviewView

    init(_ url: URL) {
        preview = QLPreviewView(frame: .zero, style: .normal)!
        super.init(frame: .zero)
        card.wantsLayer = true
        card.layer!.cornerRadius = PanelMetrics.cardRadius
        card.layer!.cornerCurve = .continuous
        card.layer!.masksToBounds = true
        preview.previewItem = url as NSURL
        card.addSubview(preview)
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let inset = PanelMetrics.cornerInset
        card.frame = CGRect(x: inset, y: inset, width: max(0, bounds.width - 2 * inset), height: max(0, bounds.height - 2 * inset))
        preview.frame = card.bounds
    }

    func close() {
        preview.close()
    }
}
