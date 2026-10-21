import AppKit
import Dock2Core

/// One row of a list in the panel: a result, a list view's item, a section's title, "Show all…", or a
/// message where there is nothing to show.
struct RowModel {
    enum Kind { case item, title, more, message }
    var id: String
    var kind: Kind
    /// Asked for only while the row is on screen: a list can hold thousands of files.
    var icon: (@MainActor () -> NSImage?)?
    var title: String
    var subtitle: String?
    /// A state shown on the right when the row is not selected: "Running".
    var accessory: String?
    /// Beside it, a mark: a pinned clip's pin, or a tag.
    var accessoryIcon: NSImage?
    /// What ↩ does, said on the selected row.
    var primary: String?
    /// What its × does, shown under the pointer: the item's ⌘⌫ action.
    var removal: String?
    var dimmed = false

    var isSelectable: Bool { kind == .item || kind == .more }
}

/// Rows above the field, nearest it first — search's results and every list's items: Spotlight's rows, 56pt,
/// a 36pt icon 18pt in, the title from 72pt, the selection a rounded band; a list beside a preview has
/// compact ones. Section titles sit above their rows; the far end scrolls, and only the rows in sight have views.
@MainActor
final class RowsView: NSView {
    /// An item's row, by its measures.
    struct Metrics: Equatable {
        var height: CGFloat
        var icon: CGFloat
        var iconX: CGFloat
        var textX: CGFloat
        var title: CGFloat
        var subtitle: CGFloat
        var radius: CGFloat

        static let regular = Metrics(height: 56, icon: 36, iconX: 18, textX: 72, title: 16.5, subtitle: 13, radius: 14)
        static let compact = Metrics(height: 38, icon: 20, iconX: 22, textX: 52, title: 14, subtitle: 11.5, radius: 10)
    }

    static let rowHeight = Metrics.regular.height
    static let titleHeight: CGFloat = 30
    static let showAllHeight: CGFloat = 40
    /// Between the field and the first row, and above the last.
    static let padding: CGFloat = 8
    /// Eight rows, then the far end scrolls.
    static let maximumHeight: CGFloat = 8 * rowHeight
    /// Taller than the rows ever are: a mask this high clips nothing above them.
    static let unbounded: CGFloat = 4000

    var onClick: ((String) -> Void)?
    var onDoubleClick: ((String) -> Void)?
    /// A row's × clicked.
    var onRemove: ((String) -> Void)?
    var metrics = Metrics.regular

    private let scroll = NSScrollView()
    private let document = FlippedUp()
    private(set) var rows: [RowModel] = []
    /// Where each row starts, from the field up, in the document.
    private var offsets: [CGFloat] = []
    private var visible: [Int: RowView] = [:]
    private var spare: [RowView] = []
    private(set) var selection: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = document
        scroll.contentView.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tile(refresh: false) }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func height(of row: RowModel, metrics: Metrics = .regular) -> CGFloat {
        switch row.kind {
        case .item, .message: metrics.height
        case .more: showAllHeight
        case .title: titleHeight
        }
    }

    /// The height the rows ask for, up to the maximum, padding included; 0 for none.
    static func height(of rows: [RowModel]) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        var total: CGFloat = 0
        for row in rows {
            total += height(of: row)
            if total >= maximumHeight { break }
        }
        return min(total, maximumHeight) + 2 * padding
    }

    func show(_ rows: [RowModel], selection: String?) {
        self.rows = rows
        self.selection = selection
        offsets = []
        offsets.reserveCapacity(rows.count)
        var y: CGFloat = 0
        for row in rows {
            offsets.append(y)
            y += Self.height(of: row, metrics: metrics)
        }
        scroll.frame = CGRect(x: 0, y: Self.padding, width: bounds.width, height: max(0, bounds.height - 2 * Self.padding))
        document.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(y, scroll.frame.height))
        revealSelection()
        tile(refresh: true)
        announceSelection()
    }

    func select(_ id: String?) {
        let changed = id != selection
        selection = id
        for (index, view) in visible { view.setSelected(rows[index].id == id) }
        revealSelection()
        if changed { announceSelection() }
    }

    // MARK: - Accessibility

    /// VoiceOver stays in the field while the arrows move the selection: the selected row is said aloud.
    private var announced: String?

    private func announceSelection() {
        guard let selection, selection != announced, let row = rows.first(where: { $0.id == selection }) else { return }
        announced = selection
        let text = [row.title, row.subtitle].compactMap { $0 }.joined(separator: ", ")
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Results" }
    override func accessibilityChildren() -> [Any]? {
        visible.sorted { $0.key < $1.key }.map(\.value)
    }

    private func rowFrame(_ index: Int) -> CGRect {
        CGRect(x: 0, y: offsets[index], width: bounds.width, height: Self.height(of: rows[index], metrics: metrics))
    }

    /// Views for the rows in sight, and a row's height beyond them each way; `refresh` redraws the ones
    /// kept, for rows that changed.
    private func tile(refresh: Bool) {
        let sight = scroll.contentView.bounds.insetBy(dx: 0, dy: -metrics.height)
        var wanted = IndexSet()
        if let first = offsets.lastIndex(where: { $0 <= max(sight.minY, 0) }) ?? (offsets.isEmpty ? nil : 0) {
            var index = first
            while index < rows.count, offsets[index] < sight.maxY {
                wanted.insert(index)
                index += 1
            }
        }
        for (index, view) in visible where !wanted.contains(index) {
            view.isHidden = true
            spare.append(view)
            visible[index] = nil
        }
        for index in wanted {
            if let view = visible[index] {
                if refresh {
                    view.frame = rowFrame(index)
                    view.show(rows[index], selected: rows[index].id == selection, metrics: metrics)
                }
                continue
            }
            let view = spare.popLast() ?? makeView()
            view.isHidden = false
            view.frame = rowFrame(index)
            view.show(rows[index], selected: rows[index].id == selection, metrics: metrics)
            visible[index] = view
        }
    }

    private func makeView() -> RowView {
        let view = RowView()
        view.onClick = { [weak self] id, count in count > 1 ? self?.onDoubleClick?(id) : self?.onClick?(id) }
        view.onRemove = { [weak self] id in self?.onRemove?(id) }
        document.addSubview(view)
        return view
    }

    /// Keeps the selected row in view; the far end is what scrolls.
    private func revealSelection() {
        guard let index = rows.firstIndex(where: { $0.id == selection }) else {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            return
        }
        document.scrollToVisible(rowFrame(index))
    }

    /// Where a row is, in this view's coordinates: for the actions' menu.
    func frame(of id: String) -> CGRect? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        return convert(rowFrame(index), from: document)
    }

    override func layout() {
        super.layout()
        scroll.frame = CGRect(x: 0, y: Self.padding, width: bounds.width, height: max(0, bounds.height - 2 * Self.padding))
    }
}

/// The rows' document: Cocoa's own coordinates, so the first row sits at the bottom, by the field.
private final class FlippedUp: NSView {
    override var isFlipped: Bool { false }
}

/// A row; under the pointer, a removable one shows its × at the far right, in place of its mark.
@MainActor
private final class RowView: NSView, Hoverable {
    private let highlight = CALayer()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let accessory = NSTextField(labelWithString: "")
    private let accessoryIcon = NSImageView()
    private let remove = NSImageView()
    private var id = ""
    private var row: RowModel?
    private var isSelected = false
    /// Where the title and subtitle stop, the × aside.
    private var textEnd: CGFloat = 0
    var onClick: ((String, Int) -> Void)?
    var onRemove: ((String) -> Void)?
    var isHovered = false { didSet { if isHovered != oldValue { layoutTrailing() } } }

    static let roomForHint: CGFloat = 400

    /// Spotlight's selection: 9.5% darker than the glass, inset 10pt, nearly the row's height.
    private static let inset: CGFloat = 10
    /// The ×, and the room around it a click takes.
    private static let removeSize: CGFloat = 16
    private static let removeSlop: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        highlight.cornerCurve = .continuous
        highlight.isHidden = true
        layer!.addSublayer(highlight)
        icon.imageScaling = .scaleProportionallyUpOrDown
        for field in [title, subtitle, accessory] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            addSubview(field)
        }
        addSubview(icon)
        accessoryIcon.contentTintColor = .secondaryLabelColor
        addSubview(accessoryIcon)
        remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.removeSize - 2, weight: .regular))
        remove.contentTintColor = .tertiaryLabelColor
        remove.isHidden = true
        addSubview(remove)
        title.font = .systemFont(ofSize: 16.5)
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        accessory.font = .systemFont(ofSize: 13)
        accessory.textColor = .secondaryLabelColor
        accessory.alignment = .right
        // The row speaks for its parts.
        for part in [icon, title, subtitle, accessory, accessoryIcon, remove] as [NSView] { part.setAccessibilityElement(false) }
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? {
        row?.kind == .title ? .staticText : .button
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        row?.kind == .title ? NSAccessibility.Subrole(rawValue: "AXHeading") : nil
    }

    override func accessibilityLabel() -> String? {
        guard let row else { return nil }
        return [row.title, row.subtitle, row.accessory].compactMap { $0 }.joined(separator: ", ")
    }

    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityHelp() -> String? { row?.primary }
    override func isAccessibilitySelected() -> Bool { !highlight.isHidden }

    override func accessibilityPerformPress() -> Bool {
        guard row?.isSelectable == true else { return false }
        onClick?(id, 2)
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let removal = row?.removal else { return nil }
        let id = self.id
        return [NSAccessibilityCustomAction(name: removal) { [weak self] in
            self?.onRemove?(id)
            return true
        }]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ row: RowModel, selected: Bool, metrics: RowsView.Metrics) {
        self.row = row
        id = row.id
        let width = bounds.width
        // Room on the right for the accessory, none in a narrow list without one.
        let trailing = width >= Self.roomForHint || row.accessory != nil ? min(150, width * 0.3) : row.accessoryIcon != nil ? 44 : 16
        textEnd = width - trailing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = CGRect(x: Self.inset, y: 0.5, width: width - 2 * Self.inset, height: bounds.height - 1)
        highlight.cornerRadius = metrics.radius
        CATransaction.commit()
        switch row.kind {
        case .item, .message:
            icon.isHidden = row.icon == nil
            icon.image = row.icon?()
            icon.frame = CGRect(x: metrics.iconX, y: (bounds.height - metrics.icon) / 2, width: metrics.icon, height: metrics.icon)
            let left: CGFloat = row.icon == nil ? 24 : metrics.textX
            title.stringValue = row.title
            title.textColor = .labelColor
            title.font = .systemFont(ofSize: metrics.title)
            subtitle.font = .systemFont(ofSize: metrics.subtitle)
            subtitle.stringValue = row.subtitle ?? ""
            subtitle.isHidden = row.subtitle == nil
            // A path's end tells two files apart; anything else reads from its start.
            subtitle.lineBreakMode = row.subtitle?.contains("/") == true ? .byTruncatingMiddle : .byTruncatingTail
            let titleHeight = title.intrinsicContentSize.height, subtitleHeight = subtitle.intrinsicContentSize.height
            if subtitle.isHidden {
                title.frame = CGRect(x: left, y: (bounds.height - titleHeight) / 2, width: width - left - trailing, height: titleHeight)
            } else {
                let top = (bounds.height + titleHeight + subtitleHeight) / 2
                title.frame = CGRect(x: left, y: top - titleHeight, width: width - left - trailing, height: titleHeight)
                subtitle.frame = CGRect(x: left, y: top - titleHeight - subtitleHeight, width: width - left - trailing, height: subtitleHeight)
            }
        case .more:
            icon.isHidden = true
            subtitle.isHidden = true
            title.stringValue = row.title
            title.font = .systemFont(ofSize: 13.5)
            title.textColor = .secondaryLabelColor
            let height = title.intrinsicContentSize.height
            title.frame = CGRect(x: 72, y: (bounds.height - height) / 2, width: width - 144, height: height)
        case .title:
            icon.isHidden = true
            subtitle.isHidden = true
            title.stringValue = row.title
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            title.textColor = .secondaryLabelColor
            let height = title.intrinsicContentSize.height
            title.frame = CGRect(x: 20, y: 4, width: width - 40, height: height)
        }
        alphaValue = row.dimmed ? 0.4 : 1
        setSelected(selected)
    }

    func setSelected(_ selected: Bool) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.backgroundColor = CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.12 : 0.095)
        highlight.isHidden = !selected
        CATransaction.commit()
        isSelected = selected
        layoutTrailing()
    }

    /// The right end: the accessory's text — on the selected row, what ↩ does — and the mark after it, or the ×.
    private func layoutTrailing() {
        guard let row else { return }
        var text = row.accessory ?? ""
        // A list beside a preview keeps its width for names.
        let hint = isSelected && row.isSelectable && bounds.width >= Self.roomForHint
        if hint { text = row.primary.map { "\($0) ↩" } ?? "↩" }
        let removes = isHovered && row.removal != nil
        remove.isHidden = !removes
        remove.frame = CGRect(x: bounds.width - 22 - Self.removeSize, y: (bounds.height - Self.removeSize) / 2,
                              width: Self.removeSize, height: Self.removeSize)
        // The hovered row's names make room for the ×; the rest keep it.
        if row.kind == .item {
            let end = removes ? min(textEnd, remove.frame.minX - 8) : textEnd
            for field in [title, subtitle] { field.frame.size.width = max(0, end - field.frame.minX) }
        }
        // The mark sits at the far right; text, if any, before it.
        let mark = hint || removes ? nil : row.accessoryIcon
        accessoryIcon.image = mark
        accessoryIcon.isHidden = mark == nil
        // An icon at 16pt, a tag at its own width.
        let markSize = mark.map { $0.size.height > 16 && $0.size.width > $0.size.height ? $0.size : CGSize(width: 16, height: 16) } ?? .zero
        accessoryIcon.frame = CGRect(x: bounds.width - 22 - markSize.width, y: (bounds.height - markSize.height) / 2,
                                     width: markSize.width, height: markSize.height)
        let end = bounds.width - 22 - (removes ? Self.removeSize + 8 : mark == nil ? 0 : markSize.width + 6)
        accessory.stringValue = text
        accessory.isHidden = text.isEmpty
        let height = accessory.intrinsicContentSize.height
        let width = min(140, bounds.width * 0.3)
        accessory.frame = CGRect(x: end - width, y: (bounds.height - height) / 2, width: width, height: height)
    }

    override func mouseDown(with event: NSEvent) {
        guard row?.isSelectable == true else { return }
        if !remove.isHidden, remove.frame.insetBy(dx: -Self.removeSlop, dy: -Self.removeSlop).contains(convert(event.locationInWindow, from: nil)) {
            onRemove?(id)
            return
        }
        onClick?(id, event.clickCount)
    }
}
