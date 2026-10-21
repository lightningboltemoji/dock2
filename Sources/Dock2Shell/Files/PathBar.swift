import AppKit
import Dock2Core

/// Files' path bar, in the field's place ([files](product/files/README.md#layout)): the current folder as
/// segments — a click goes there, the first one's menu lists the places — or a path being typed, Tab
/// completing it, or ⌘F's search; the other tab's chip at the end.
@MainActor
final class PathBar: NSView, NSTextFieldDelegate {
    struct Segment {
        var title: String
        var url: URL
    }

    private let glyph = NSImageView()
    private let segments = NSStackView()
    private let text = NSTextField()
    private let chip = DropButton()
    private var places: MenuBuilder?

    enum Mode { case segments, path, search }
    private(set) var mode = Mode.segments
    var isTyping: Bool { mode == .path }
    var isSearching: Bool { mode == .search }
    /// Its field has the keys: a path typed, or ⌘F's query.
    var isEditing: Bool { mode != .segments && text.currentEditor() != nil }

    /// A segment, a place or the chip chosen.
    var onGo: ((URL) -> Void)?
    var onChip: (() -> Void)?
    /// Items dropped on a segment, or on the chip — the other tab's folder.
    var onDrop: (([URL], URL, _ moving: Bool) -> Void)?
    private var otherFolder: URL?
    var onPlaces: (() -> [(String, URL)])?
    /// While typing: the text, to follow; ↩ with it; Tab asking for its completion.
    var onTyped: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onComplete: ((String) -> String)?
    /// While searching: the text as it changes, and ↑ ↓ ↩ for the results.
    var onSearch: ((String) -> Void)?
    var onSearchCommand: ((Selector) -> Bool)?

    static let fontSize: CGFloat = 17

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyph.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 21, weight: .medium))
        glyph.contentTintColor = .labelColor
        addSubview(glyph)
        segments.orientation = .horizontal
        segments.spacing = 2
        addSubview(segments)
        text.isBordered = false
        text.drawsBackground = false
        text.focusRingType = .none
        text.font = .systemFont(ofSize: PanelMetrics.fontSize)
        text.cell?.usesSingleLineMode = true
        text.cell?.isScrollable = true
        text.delegate = self
        text.isHidden = true
        text.setAccessibilityLabel("Path")
        addSubview(text)
        chip.bezelStyle = .push
        chip.controlSize = .large
        chip.font = .systemFont(ofSize: 13, weight: .medium)
        chip.target = self
        chip.action = #selector(chipClicked)
        chip.isHidden = true
        addSubview(chip)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// The segments, the selected item last; the chip naming the other tab's folder, if there is one.
    func show(_ path: [Segment], selected: String?, other: (title: String, folder: URL)?) {
        segments.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, segment) in path.enumerated() {
            if index > 0 { segments.addArrangedSubview(separator()) }
            let button = SegmentButton(title: segment.title, url: segment.url, isFirst: index == 0)
            button.target = self
            button.action = #selector(segmentClicked(_:))
            button.onDrop = { [weak self] urls, folder, moving in self?.onDrop?(urls, folder, moving) }
            segments.addArrangedSubview(button)
        }
        if let selected {
            segments.addArrangedSubview(separator())
            let label = NSTextField(labelWithString: selected)
            label.font = .systemFont(ofSize: Self.fontSize, weight: .medium)
            label.lineBreakMode = .byTruncatingMiddle
            segments.addArrangedSubview(label)
        }
        chip.isHidden = other == nil
        otherTitle = other?.title
        showChipTitle()
        otherFolder = other?.folder
        chip.onDrop = { [weak self] urls, _, moving in
            guard let folder = self?.otherFolder else { return }
            self?.onDrop?(urls, folder, moving)
        }
        chip.folder = other?.folder
        chip.toolTip = "The other tab — ⌃⇥"
        needsLayout = true
    }

    private func separator() -> NSView {
        let label = NSTextField(labelWithString: "›")
        label.font = .systemFont(ofSize: Self.fontSize)
        label.textColor = .tertiaryLabelColor
        return label
    }

    // MARK: - Typing a path

    func beginTyping(_ initial: String) {
        begin(.path, initial, placeholder: nil, symbol: "folder")
        onTyped?(initial)
    }

    /// ⌘F: the field becomes a search of `scope`.
    func beginSearching(_ initial: String, placeholder: String) {
        begin(.search, initial, placeholder: placeholder, symbol: "magnifyingglass")
        onSearch?(initial)
    }

    private func begin(_ mode: Mode, _ initial: String, placeholder: String?, symbol: String) {
        self.mode = mode
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 21, weight: .medium))
        segments.isHidden = true
        text.isHidden = false
        text.stringValue = initial
        text.placeholderAttributedString = placeholder.map {
            NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: PanelMetrics.fontSize), .foregroundColor: NSColor.secondaryLabelColor])
        }
        window?.makeFirstResponder(text)
        text.currentEditor()?.selectedRange = NSRange(location: initial.utf16.count, length: 0)
    }

    /// Back to the segments, from typing a path or searching.
    func endTyping() {
        guard mode != .segments else { return }
        mode = .segments
        glyph.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 21, weight: .medium))
        text.isHidden = true
        segments.isHidden = false
    }

    func controlTextDidChange(_ notification: Notification) {
        switch mode {
        case .path: onTyped?(text.stringValue)
        case .search: onSearch?(text.stringValue)
        case .segments: break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        if mode == .search { return onSearchCommand?(selector) ?? false }
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            let completed = onComplete?(text.stringValue) ?? text.stringValue
            text.stringValue = completed
            textView.selectedRange = NSRange(location: completed.utf16.count, length: 0)
            onTyped?(completed)
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(text.stringValue)
        default:
            return false
        }
        return true
    }

    // MARK: -

    @objc private func segmentClicked(_ sender: SegmentButton) {
        guard sender.isFirst, let places = onPlaces?() else {
            onGo?(sender.url)
            return
        }
        let builder = MenuBuilder()
        builder.item(sender.title) { [weak self] in self?.onGo?(sender.url) }
        builder.separator()
        for (title, url) in places {
            builder.item(title) { [weak self] in self?.onGo?(url) }
        }
        self.places = builder
        builder.menu.popUp(positioning: nil, at: CGPoint(x: sender.frame.minX, y: sender.frame.maxY + 4), in: segments)
    }

    @objc private func chipClicked() { onChip?() }

    private var otherTitle: String?
    private var progress: Double?

    /// An operation going to the other tab's folder, as a ring filling on its chip in place of the ⇥; nil
    /// when none is.
    func showProgress(_ fraction: Double?) {
        guard fraction != progress else { return }
        progress = fraction
        showChipTitle()
        needsLayout = true
    }

    private func showChipTitle() {
        guard let otherTitle else { return }
        chip.image = progress.map(Self.ring)
        chip.imagePosition = .imageLeading
        chip.title = progress == nil ? "⇥ \(otherTitle)" : otherTitle
        chip.setAccessibilityValue(progress.map { "\(Int($0 * 100)) percent" })
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

    override func layout() {
        super.layout()
        let height = bounds.height
        glyph.frame = CGRect(x: PanelMetrics.glyphLeft, y: (height - 26) / 2 + PanelMetrics.glyphLift, width: 26, height: 26)
        let chipWidth = chip.isHidden ? 0 : min(220, chip.intrinsicContentSize.width + 8)
        chip.frame = CGRect(x: bounds.width - 18 - chipWidth, y: (height - 28) / 2, width: chipWidth, height: 28)
        let left = PanelMetrics.textLeft - 4
        let available = bounds.width - left - (chipWidth > 0 ? chipWidth + 30 : 24)
        let fitting = segments.fittingSize
        segments.frame = CGRect(x: left, y: (height - fitting.height) / 2, width: min(fitting.width, available), height: fitting.height)
        let font = text.font!
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up) + 2
        text.frame = CGRect(x: PanelMetrics.textLeft - 3.5, y: PanelMetrics.baseline + font.descender - 2.5,
                            width: available, height: lineHeight)
    }
}

/// A button files can be dropped on, into its folder.
@MainActor
class DropButton: NSButton {
    var folder: URL?
    var onDrop: (([URL], URL, Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let folder, DropRule.accepts(DropRule.fileURLs(sender), into: folder) else { return [] }
        highlight(true)
        return DropRule.moves(DropRule.fileURLs(sender), to: folder, allowed: sender.draggingSourceOperationMask) ? .move : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight(false)
        let urls = DropRule.fileURLs(sender)
        guard let folder, DropRule.accepts(urls, into: folder) else { return false }
        onDrop?(urls, folder, DropRule.moves(urls, to: folder, allowed: sender.draggingSourceOperationMask))
        return true
    }
}

/// A folder in the path bar: borderless, its title the folder's name.
@MainActor
private final class SegmentButton: DropButton {
    let url: URL
    let isFirst: Bool

    init(title: String, url: URL, isFirst: Bool) {
        self.url = url
        self.isFirst = isFirst
        super.init(frame: .zero)
        folder = url
        self.title = isFirst ? "\(title) ⌄" : title
        isBordered = false
        font = .systemFont(ofSize: PathBar.fontSize)
        contentTintColor = .labelColor
        setButtonType(.momentaryPushIn)
        lineBreakMode = .byTruncatingMiddle
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
