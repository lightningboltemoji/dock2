import AppKit
import Dock2Core

/// What draws a list's items: rows, or pills in a flow.
@MainActor
protocol ItemsView: NSView {
    var onClick: ((String) -> Void)? { get set }
    var onDoubleClick: ((String) -> Void)? { get set }
    var metrics: PanelMetrics.Row { get set }
    /// `centred` brings the selection to the middle when it is out of sight.
    func show(_ rows: [RowModel], selection: String?, centred: Bool)
    func select(_ id: String?)
}

extension RowsView: ItemsView {}

/// A list's items as pills under their sections' titles ([views](product/plugins/views.md#flow)), placed by
/// `FlowLayout` on the margins rows keep: each a quiet capsule, the selected one let down to the ground as a row's band
/// is. One canvas draws what is in sight, so a flow of thousands costs what shows.
@MainActor
final class FlowView: NSView, ItemsView {
    var onClick: ((String) -> Void)?
    var onDoubleClick: ((String) -> Void)?
    var metrics = PanelMetrics.Row.regular {
        didSet { if metrics != oldValue { needsLayout = true } }
    }

    private let scroll = OverlayScrollView()
    private let document = FlowDocument()
    /// Under the canvas, behind the selected pill.
    private let well = GroundInset()
    private let canvas = FlowCanvas()
    private(set) var rows: [RowModel] = []
    private(set) var selection: String?
    /// A selection the owner chose, to bring to the middle once laid out, as `RowsView`'s.
    private var centring: String?
    private var announced: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = document
        scroll.contentView.drawsBackground = false
        addSubview(scroll)
        well.cornerRadius = FlowLayout.pillHeight / 2
        well.isHidden = true
        document.addSubview(well)
        document.addSubview(canvas)
        canvas.onClick = { [weak self] index, count in
            guard let self, self.rows.indices.contains(index) else { return }
            let id = self.rows[index].id
            count > 1 ? self.onDoubleClick?(id) : self.onClick?(id)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ rows: [RowModel], selection: String?, centred: Bool) {
        self.rows = rows
        self.selection = selection
        centring = centred ? selection : nil
        canvas.icons = [:]
        needsLayout = true
        layoutSubtreeIfNeeded()
        announce()
    }

    func select(_ id: String?) {
        selection = id
        centring = nil
        placeWell()
        reveal()
        announce()
    }

    /// The item on the line above or below the selection nearest it across, if there is a line there.
    func neighbour(down: Bool) -> String? {
        guard let index = rows.firstIndex(where: { $0.id == selection }) else { return nil }
        let pills = rows.map { $0.kind == .item }
        return FlowLayout.vertical(from: index, in: canvas.frames, pills: pills, down: down).map { rows[$0].id }
    }

    override func layout() {
        super.layout()
        let padding = RowsView.padding
        scroll.frame = CGRect(x: 0, y: padding, width: bounds.width, height: max(0, bounds.height - 2 * padding))
        let pieces: [FlowLayout.Piece] = rows.map { row in
            switch row.kind {
            case .title, .more: .title
            case .message: .message
            case .item: .pill(width: FlowCanvas.width(of: row))
            }
        }
        let (frames, height) = FlowLayout.frames(pieces, left: metrics.plateX, right: bounds.width - metrics.trailingX,
                                                 titleHeight: RowsView.titleHeight, messageHeight: metrics.height)
        document.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(height, scroll.frame.height))
        canvas.frame = document.bounds
        canvas.rows = rows
        canvas.frames = frames
        canvas.metrics = metrics
        canvas.selection = selection
        canvas.needsDisplay = true
        placeWell()
        reveal()
    }

    private func placeWell() {
        let index = rows.firstIndex { $0.id == selection && $0.kind == .item }
        canvas.selection = selection
        canvas.needsDisplay = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        well.isHidden = index == nil
        if let index, canvas.frames.indices.contains(index) { well.frame = canvas.frames[index] }
        CATransaction.commit()
    }

    /// Keeps the selected pill in view, or brings it to the middle while `centring`.
    private func reveal() {
        guard let index = rows.firstIndex(where: { $0.id == selection }), canvas.frames.indices.contains(index) else {
            centring = nil
            return
        }
        let pill = canvas.frames[index], sight = scroll.contentView.bounds
        if centring != nil {
            guard sight.height > 0 else { return }
            centring = nil
            guard sight.contains(pill) else {
                document.scrollToVisible(pill.insetBy(dx: 0, dy: -(sight.height - pill.height) / 2))
                return
            }
        }
        document.scrollToVisible(pill.insetBy(dx: 0, dy: -FlowLayout.gap))
    }

    /// VoiceOver stays in the field while the arrows move the selection: the selected pill is said aloud.
    private func announce() {
        guard let selection, selection != announced, let row = rows.first(where: { $0.id == selection }) else { return }
        announced = selection
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: row.spoken, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    override func isAccessibilityElement() -> Bool { !rows.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Results" }
}

private final class FlowDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Every title and pill in sight, drawn in one pass.
private final class FlowCanvas: NSView {
    var rows: [RowModel] = []
    var frames: [CGRect] = []
    var metrics = PanelMetrics.Row.regular
    var selection: String?
    /// Each pill's icon, asked for as it first comes into sight.
    var icons: [String: NSImage?] = [:]
    var onClick: ((Int, Int) -> Void)?

    private static let font = NSFont.systemFont(ofSize: PanelMetrics.detailFont)
    private static let padding: CGFloat = 12
    private static let iconSize: CGFloat = 16
    private static let iconGap: CGFloat = 6
    private static var widths: [String: CGFloat] = [:]

    override var isFlipped: Bool { true }

    /// What a pill takes across: its title, its icon before it, and its padding.
    static func width(of row: RowModel) -> CGFloat {
        let text = widths[row.title] ?? {
            let width = (row.title as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
            widths[row.title] = width
            return width
        }()
        return 2 * padding + (row.icon == nil ? 0 : iconSize + iconGap) + text
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, frame) in frames.enumerated() where frame.intersects(dirtyRect) && rows.indices.contains(index) {
            let row = rows[index]
            switch row.kind {
            case .title, .more: drawTitle(row, in: frame)
            case .message: drawMessage(row, in: frame)
            case .item: drawPill(row, in: frame, selected: row.id == selection)
            }
        }
    }

    /// As a section's title over rows: 12 pt semibold, in the line under the gap that keeps it with what it heads.
    private func drawTitle(_ row: RowModel, in frame: CGRect) {
        let text = NSAttributedString(string: row.title, attributes: [
            .font: NSFont.systemFont(ofSize: PanelMetrics.headingFont, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let line = RowsView.titleLine, height = text.size().height
        text.draw(at: CGPoint(x: frame.minX, y: frame.maxY - line + (line - height) / 2))
    }

    private func drawMessage(_ row: RowModel, in frame: CGRect) {
        let title = NSAttributedString(string: row.title, attributes: [.font: NSFont.systemFont(ofSize: metrics.title), .foregroundColor: NSColor.labelColor])
        let subtitle = row.subtitle.map {
            NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: metrics.subtitle), .foregroundColor: NSColor.secondaryLabelColor])
        }
        let total = title.size().height + (subtitle?.size().height ?? 0)
        var y = frame.midY - total / 2
        title.draw(at: CGPoint(x: metrics.plateX, y: y))
        y += title.size().height
        subtitle?.draw(at: CGPoint(x: metrics.plateX, y: y))
    }

    private func drawPill(_ row: RowModel, in frame: CGRect, selected: Bool) {
        // Bare but for its edge, as a row is but for its band: the selection's well is the only ground showing.
        if !selected {
            let edge = frame.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: edge, xRadius: edge.height / 2, yRadius: edge.height / 2)
            path.lineWidth = 1
            NSColor.separatorColor.setStroke()
            path.stroke()
        }
        var x = frame.minX + Self.padding
        // An icon that draws nothing keeps its room, as a row's does.
        if row.icon != nil {
            icon(for: row)?.draw(in: CGRect(x: x, y: frame.midY - Self.iconSize / 2, width: Self.iconSize, height: Self.iconSize))
            x += Self.iconSize + Self.iconGap
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: row.title, attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        let height = text.size().height
        text.draw(with: CGRect(x: x, y: frame.midY - height / 2, width: max(0, frame.maxX - Self.padding - x), height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Its icon fitted to the pill's square, a template in the secondary label colour, as a row's marks are.
    private func icon(for row: RowModel) -> NSImage? {
        if let icon = icons[row.id] { return icon }
        let image = row.icon?().map { image in
            let fitted = IconImages.fitted(image, to: Self.iconSize, in: Self.iconSize)
            return image.isTemplate ? fitted.tinted(.secondaryLabelColor) : fitted
        }
        icons[row.id] = image
        return image
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = frames.indices.first(where: { rows.indices.contains($0) && rows[$0].kind == .item && frames[$0].contains(point) }) else { return }
        onClick?(index, event.clickCount)
    }
}
