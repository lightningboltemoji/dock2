import AppKit
import Dock2Core
import Dock2System

/// Files above its path bar: the banner, when there is something to say, over the columns.
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
        let bannerHeight = banner.height
        banner.frame = CGRect(x: 0, y: bounds.height - bannerHeight, width: bounds.width, height: bannerHeight)
        columns.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - bannerHeight)
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

    static let rowHeight: CGFloat = 40
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
        let row = NSView()
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
        title.frame = CGRect(x: 20, y: 20, width: 600, height: 16)
        bar.frame = CGRect(x: 20, y: 6, width: 860, height: 12)
        stop.frame = CGRect(x: 900, y: 10, width: 20, height: 20)
        [title, bar, stop].forEach(row.addSubview)
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.progressIndicator)
        row.setAccessibilityLabel(job.title)
        return row
    }

    private func accessRow() -> NSView {
        let row = NSView()
        let title = NSTextField(labelWithString: "dock2 needs Full Disk Access to show all your files.")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let detail = NSTextField(labelWithString: "macOS has no prompt for it; the switch is in System Settings.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        title.frame = CGRect(x: 20, y: 21, width: 420, height: 16)
        detail.frame = CGRect(x: 20, y: 5, width: 420, height: 14)
        [title, detail].forEach(row.addSubview)
        var x = PanelMetrics.filesSize.width - 40
        for (label, choice) in [("Open System Settings", FileAccessChoice.fullDisk), ("Just Desktop, Documents and Downloads", .folders),
                                ("Not now", .declined)] {
            let button = ClosureButton(title: label) { [weak self] in self?.answerAccess(choice) }
            button.bezelStyle = .push
            button.controlSize = .small
            if choice == .fullDisk { button.keyEquivalent = "\r" }
            let width = button.intrinsicContentSize.width + 8
            x -= width
            button.frame = CGRect(x: x, y: 8, width: width, height: 24)
            row.addSubview(button)
            x -= 6
        }
        row.setAccessibilityLabel(title.stringValue)
        return row
    }

    private func conflictRow(_ question: ConflictQuestion) -> NSView {
        let row = NSView()
        let folder = question.existing.deletingLastPathComponent().lastPathComponent
        let title = NSTextField(labelWithString: "“\(question.item.lastPathComponent)” is already in “\(folder)”.")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.frame = CGRect(x: 20, y: 12, width: 470, height: 16)
        row.addSubview(title)
        var x: CGFloat = 500
        if question.more {
            forAll.frame = CGRect(x: x, y: 10, width: 74, height: 20)
            row.addSubview(forAll)
            x += 80
        }
        for (label, choice) in [("Skip", ConflictAnswer.Choice.skip), ("Replace", .replace), ("Keep Both", .keepBoth)] {
            let button = ClosureButton(title: label) { [weak self] in self?.answer(choice) }
            button.bezelStyle = .push
            button.controlSize = .small
            let width = button.intrinsicContentSize.width + 8
            button.frame = CGRect(x: x, y: 8, width: width, height: 24)
            row.addSubview(button)
            x += width + 6
        }
        row.setAccessibilityLabel(title.stringValue)
        return row
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
