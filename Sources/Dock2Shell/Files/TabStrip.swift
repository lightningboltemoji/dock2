import AppKit
import Dock2Core

/// Files' tabs ([files](product/files/README.md#tabs)), at the bar's end: with two or more, a pill for each —
/// the one showing tinted, a ring on one an operation is filling — then New Tab. A pill takes drops into
/// its folder and, a drag held over it, shows its tab; hovered, its icon becomes its close button.
@MainActor
final class TabStrip: NSView {
    struct Tab: Equatable {
        var title: String
        var folder: URL
        /// An operation going into its folder, as a fraction done.
        var progress: Double?
    }

    private var pills: [TabPill] = []
    private let add = PillButton()

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onDrop: (([URL], URL, _ moving: Bool) -> Void)?

    static let height: CGFloat = 28
    static let gap: CGFloat = 4
    static let minimumWidth: CGFloat = 84
    static let maximumWidth: CGFloat = 176

    override init(frame: CGRect) {
        super.init(frame: frame)
        add.set(title: "", image: Self.symbol("plus", size: 13))
        add.padding = (Self.height - 16) / 2
        add.icon.contentTintColor = .secondaryLabelColor
        add.toolTip = "New Tab  ⌘T"
        add.setAccessibilityLabel("New Tab")
        add.onClick = { [weak self] in self?.onNew?() }
        addSubview(add)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ tabs: [Tab], current: Int, canAdd: Bool) {
        // One tab is the folder the path already names: only New Tab shows.
        let shown = tabs.count > 1 ? tabs : []
        while pills.count < shown.count {
            let pill = TabPill()
            let index = pills.count
            pill.onClick = { [weak self] in self?.onSelect?(index) }
            pill.onSpring = { [weak self] in self?.onSelect?(index) }
            pill.onClose = { [weak self] in self?.onClose?(index) }
            pill.onDrop = { [weak self] urls, folder, moving in self?.onDrop?(urls, folder, moving) }
            addSubview(pill)
            pills.append(pill)
        }
        while pills.count > shown.count { pills.removeLast().removeFromSuperview() }
        for (index, (pill, tab)) in zip(pills, shown).enumerated() {
            pill.show(tab, isCurrent: index == current)
        }
        add.isHidden = !canAdd
        needsLayout = true
    }

    /// How wide it is, given no more than `limit`: the pills shrink, down to their minimum, to fit.
    func width(within limit: CGFloat) -> CGFloat {
        let widths = pillWidths(within: limit)
        let pills = widths.reduce(0, +) + CGFloat(widths.count) * Self.gap
        return pills + (add.isHidden ? 0 : Self.height)
    }

    private func pillWidths(within limit: CGFloat) -> [CGFloat] {
        let natural = pills.map { min(Self.maximumWidth, max(Self.minimumWidth, $0.intrinsicContentSize.width)) }
        let room = limit - (add.isHidden ? 0 : Self.height) - CGFloat(pills.count) * Self.gap
        guard natural.reduce(0, +) > room, !natural.isEmpty else { return natural }
        let each = max(Self.minimumWidth, (room / CGFloat(natural.count)).rounded(.down))
        return natural.map { min($0, each) }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (pill, width) in zip(pills, pillWidths(within: bounds.width)) {
            pill.frame = CGRect(x: x, y: 0, width: width, height: Self.height)
            x += width + Self.gap
        }
        add.frame = CGRect(x: bounds.width - Self.height, y: 0, width: Self.height, height: Self.height)
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
}

/// A tab's pill: its folder's icon and name; hovered, the icon is a close button.
@MainActor
private final class TabPill: PillButton {
    var onClose: (() -> Void)?
    private var tab: TabStrip.Tab?

    override init() {
        super.init()
        padding = 8
        label.font = .systemFont(ofSize: 13, weight: .medium)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ tab: TabStrip.Tab, isCurrent: Bool) {
        let changed = tab != self.tab || isCurrent != self.isCurrent
        self.tab = tab
        self.isCurrent = isCurrent
        folder = tab.folder
        guard changed else { return }
        toolTip = FilesScreen.abbreviate(tab.folder)
        dress()
    }

    override func hoverChanged() { dress() }

    private func dress() {
        guard let tab else { return }
        let image: NSImage?
        if isHovered {
            image = TabStrip.symbol("xmark", size: 10, weight: .bold)
            icon.contentTintColor = .secondaryLabelColor
        } else if let progress = tab.progress {
            image = Self.ring(progress)
            icon.contentTintColor = nil
        } else {
            image = NSWorkspace.shared.icon(forFile: tab.folder.path)
            icon.contentTintColor = nil
        }
        set(title: tab.title, image: image)
        label.textColor = isCurrent ? .labelColor : .secondaryLabelColor
        setAccessibilityRole(.radioButton)
        setAccessibilityValue(isCurrent ? 1 : 0)
        setAccessibilityLabel([tab.title, tab.progress.map { "\(Int($0 * 100)) percent copied" }].compactMap { $0 }.joined(separator: ", "))
    }

    /// On the icon while it shows the close button: the tab closes rather than shows.
    override func clicked(at point: CGPoint) {
        if isHovered, icon.frame.insetBy(dx: -4, dy: -6).contains(point) { onClose?() } else { onClick?() }
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "Close Tab") { [weak self] in
            self?.onClose?()
            return true
        }]
    }

    /// 12pt across: the track in the tertiary label colour, the part done in the accent colour.
    private static func ring(_ fraction: Double) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let track = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            track.lineWidth = 2
            NSColor.tertiaryLabelColor.setStroke()
            track.stroke()
            let done = NSBezierPath()
            done.appendArc(withCenter: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2 - 1,
                           startAngle: 90, endAngle: 90 - 360 * min(max(fraction, 0.02), 1), clockwise: true)
            done.lineWidth = 2
            done.lineCapStyle = .round
            NSColor.controlAccentColor.setStroke()
            done.stroke()
            return true
        }
    }
}
