import AppKit
import Dock2Core
import Dock2System

/// Files' geometry over its bar. Everything sits `inset` in from the glass's edge, so the corners of what
/// is drawn inside are concentric with the panel's.
enum FilesLayout {
    static let inset: CGFloat = 10
    static let columnWidth: CGFloat = 236
    /// What three columns leave of the panel's width.
    static let previewWidth = PanelMetrics.filesSize.width - 2 * inset - 3 * columnWidth
    static let cardRadius = PanelMetrics.fieldSize.height / 2 - inset
    /// A pane over the glass, a shade off it: the banner's.
    static let card = PillButton.ink(0.04)
}

/// Files above its bar: the columns, the banner over them when there is something to say.
@MainActor
final class FilesView: NSView {
    let columns = ColumnsView()
    let banner = FilesBanner()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(columns)
        addSubview(banner)
        banner.onResize = { [weak self] in self?.needsLayout = true }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let inset = FilesLayout.inset
        let left = inset
        let width = bounds.width - 2 * inset
        let bannerHeight = banner.height
        // Aligned with the columns' selection, which is inset within them.
        banner.frame = CGRect(x: left + 10, y: bounds.height - inset - bannerHeight, width: width - 10, height: bannerHeight)
        let top = bannerHeight > 0 ? banner.frame.minY - 4 : bounds.height - inset
        columns.frame = CGRect(x: left, y: 0, width: width, height: top)
    }
}

/// The top of Files ([operations](product/files/operations.md#progress)): a row for each operation still
/// running after a moment — its title, its progress, a button to cancel it — and a name already taken,
/// asked about inline: Replace, Keep Both or Skip, for all when more are coming.
@MainActor
final class FilesBanner: NSView {
    private var rows: [NSView] = []
    private var question: (ConflictQuestion, @Sendable (ConflictAnswer) -> Void)?
    private var shownJobs: [FileJob] = []
    private var accessAsk: ((FileAccessChoice) -> Void)?
    /// The jobs as last told: running, or waiting.
    private var jobs: [FileJob] = []
    private var pending: DispatchWorkItem?
    private let forAll = NSButton(checkboxWithTitle: "For all", target: nil, action: nil)
    var onResize: (() -> Void)?

    static let rowHeight: CGFloat = 44
    /// An operation shorter than this never shows.
    static let delay = 0.5

    var height: CGFloat { CGFloat(rows.count) * Self.rowHeight }

    var isAsking: Bool { question != nil }

    func show(jobs: [FileJob]) {
        self.jobs = jobs
        // A job shows once it has run for the delay; look again then, at the jobs running by then.
        let due = jobs.filter { Date().timeIntervalSince($0.started) >= Self.delay }
        if due.count < jobs.count, pending == nil {
            let check = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.show(jobs: self.jobs)
            }
            pending = check
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: check)
        }
        shownJobs = due
        rebuild()
    }

    func ask(_ question: ConflictQuestion, _ reply: @escaping @Sendable (ConflictAnswer) -> Void) {
        self.question = (question, reply)
        rebuild()
        announce("“\(question.item.lastPathComponent)” is already in “\(question.existing.deletingLastPathComponent().lastPathComponent)”.")
    }

    /// Said once, as a question is put: the rows are rebuilt with every progress tick.
    private func announce(_ text: String) {
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The ask for Full Disk Access ([access](product/files/access.md#the-ask)), above everything else.
    func askForAccess(_ reply: @escaping (FileAccessChoice) -> Void) {
        accessAsk = reply
        rebuild()
        announce("dock2 needs Full Disk Access to show all your files.")
    }

    var isAskingForAccess: Bool { accessAsk != nil }

    private func answerAccess(_ choice: FileAccessChoice) {
        guard let reply = accessAsk else { return }
        accessAsk = nil
        rebuild()
        reply(choice)
    }

    /// Esc: a question pending is answered Skip; the ask, Not now.
    func cancelQuestion() -> Bool {
        if accessAsk != nil {
            answerAccess(.declined)
            return true
        }
        guard question != nil else { return false }
        answer(.skip)
        return true
    }

    /// ↩: Keep Both, which loses nothing; the ask, Open System Settings.
    func acceptQuestion() -> Bool {
        if accessAsk != nil {
            answerAccess(.fullDisk)
            return true
        }
        guard question != nil else { return false }
        answer(.keepBoth)
        return true
    }

    private func answer(_ choice: ConflictAnswer.Choice) {
        guard let (_, reply) = question else { return }
        question = nil
        reply(ConflictAnswer(choice, forAll: forAll.state == .on))
        forAll.state = .off
        rebuild()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 12
        layer?.backgroundColor = FilesLayout.card.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        if accessAsk != nil { rows.append(accessRow()) }
        if let (question, _) = question { rows.append(conflictRow(question)) }
        for job in shownJobs { rows.append(jobRow(job)) }
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(rows.count - 1 - index) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
            row.autoresizingMask = [.width]
            addSubview(row)
        }
        onResize?()
    }

    private func jobRow(_ job: FileJob) -> NSView {
        let row = BannerRow()
        let title = NSTextField(labelWithString: job.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = job.progress.fractionCompleted
        let progress = job.progress
        let stop = ClosureButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Stop")!) {
            progress.cancel()
        }
        stop.isBordered = false
        stop.contentTintColor = .secondaryLabelColor
        [title, bar, stop].forEach(row.addSubview)
        row.arrange = { width in
            title.frame = CGRect(x: 14, y: 23, width: width - 60, height: 16)
            bar.frame = CGRect(x: 14, y: 8, width: width - 60, height: 12)
            stop.frame = CGRect(x: width - 34, y: 12, width: 20, height: 20)
        }
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.progressIndicator)
        row.setAccessibilityLabel(job.title)
        return row
    }

    private func accessRow() -> NSView {
        let row = BannerRow()
        let title = NSTextField(labelWithString: "dock2 needs Full Disk Access to show all your files.")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let detail = NSTextField(labelWithString: "macOS has no prompt for it; the switch is in System Settings.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        [title, detail].forEach(row.addSubview)
        var buttons: [NSButton] = []
        for (label, choice) in [("Open System Settings", FileAccessChoice.fullDisk), ("Just Desktop, Documents and Downloads", .folders),
                                ("Not now", .declined)] {
            let button = ClosureButton(title: label) { [weak self] in self?.answerAccess(choice) }
            button.bezelStyle = .push
            button.controlSize = .small
            if choice == .fullDisk { button.keyEquivalent = "\r" }
            row.addSubview(button)
            buttons.append(button)
        }
        row.arrange = { width in
            var x = width - 10
            for button in buttons {
                let buttonWidth = button.intrinsicContentSize.width + 8
                x -= buttonWidth
                button.frame = CGRect(x: x, y: 10, width: buttonWidth, height: 24)
                x -= 6
            }
            title.frame = CGRect(x: 14, y: 23, width: x - 20, height: 16)
            detail.frame = CGRect(x: 14, y: 7, width: x - 20, height: 14)
        }
        row.setAccessibilityLabel(title.stringValue)
        return row
    }

    private func conflictRow(_ question: ConflictQuestion) -> NSView {
        let row = BannerRow()
        let folder = question.existing.deletingLastPathComponent().lastPathComponent
        let title = NSTextField(labelWithString: "“\(question.item.lastPathComponent)” is already in “\(folder)”.")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        row.addSubview(title)
        if question.more { row.addSubview(forAll) }
        var buttons: [NSButton] = []
        for (label, choice) in [("Skip", ConflictAnswer.Choice.skip), ("Replace", .replace), ("Keep Both", .keepBoth)] {
            let button = ClosureButton(title: label) { [weak self] in self?.answer(choice) }
            button.bezelStyle = .push
            button.controlSize = .small
            row.addSubview(button)
            buttons.append(button)
        }
        let more = question.more, forAll = forAll
        row.arrange = { width in
            var x = width - 10
            for button in buttons.reversed() {
                let buttonWidth = button.intrinsicContentSize.width + 8
                x -= buttonWidth
                button.frame = CGRect(x: x, y: 10, width: buttonWidth, height: 24)
                x -= 6
            }
            if more {
                x -= 74
                forAll.frame = CGRect(x: x, y: 12, width: 74, height: 20)
                x -= 6
            }
            title.frame = CGRect(x: 14, y: 14, width: x - 20, height: 16)
        }
        row.setAccessibilityLabel(title.stringValue)
        return row
    }
}

/// A row of the banner, laid out against its width each time it changes.
@MainActor
private final class BannerRow: NSView {
    var arrange: ((CGFloat) -> Void)?

    override func layout() {
        super.layout()
        arrange?(bounds.width)
    }
}

/// A button that runs a closure: the banner's rows are rebuilt too often for targets of their own.
@MainActor
private final class ClosureButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, _ handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        setHandler(handler)
    }

    convenience init(image: NSImage, _ handler: @escaping () -> Void) {
        self.init(image: image, target: nil, action: nil)
        setHandler(handler)
    }

    private func setHandler(_ handler: @escaping () -> Void) {
        self.handler = handler
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { handler?() }
}
