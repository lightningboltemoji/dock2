import AppKit
import Dock2Core

/// A view's node, drawn: what the views controller routes keys and the field's text to.
@MainActor
protocol Component: NSView {
    func show(_ node: ViewNode)
    /// A list filters by the field; everything else keeps the keyboard in its own controls.
    var usesField: Bool { get }
    func filter(_ text: String)
    /// A text-system command from the field — ↑ ↓ ↩ — or from the component's own controls; true if handled.
    func command(_ selector: Selector) -> Bool
    /// ⌘-chords: ⌘↩, ⌘K, the actions' own keys; true if handled.
    func keyEquivalent(_ event: NSEvent) -> Bool
}

/// A chord as an action writes it — "cmd+shift+c", "opt+return" — as a key and its modifiers.
struct Chord {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init?(_ text: String?) {
        guard let parts = text?.lowercased().split(separator: "+").map(String.init), let last = parts.last else { return nil }
        guard last == "return" || last.count == 1 else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            default: return nil
            }
        }
        key = last == "return" ? "\r" : last
        self.modifiers = modifiers
    }

    func matches(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .shift, .option, .control]) == modifiers
            && event.charactersIgnoringModifiers?.lowercased() == key
    }
}

@MainActor
func matches(_ key: String?, _ event: NSEvent) -> Bool {
    Chord(key)?.matches(event) ?? false
}

/// A view's actions as its keys reach them: the selected item's, then the view's own. ↩ and ⌘↩ are the
/// item's first and second — the view's when the item has none — a chord is either's, and ⌘K lists both,
/// a view's own running with no item.
@MainActor
struct ActionSet {
    var item: String?
    var items: [ActionNode]
    var view: [ActionNode]

    var isEmpty: Bool { items.isEmpty && view.isEmpty }

    var primary: [(action: ActionNode, item: String?)] {
        items.isEmpty ? view.map { ($0, nil) } : items.map { ($0, item) }
    }

    func matching(_ event: NSEvent) -> (action: ActionNode, item: String?)? {
        if let action = items.first(where: { matches($0.key, event) }) { return (action, item) }
        return view.first(where: { matches($0.key, event) }).map { ($0, nil) }
    }

    func keyed(_ key: String) -> (action: ActionNode, item: String?)? {
        if let action = items.first(where: { $0.key == key }) { return (action, item) }
        return view.first(where: { $0.key == key }).map { ($0, nil) }
    }

    func fill(_ builder: MenuBuilder, _ perform: @escaping (ActionNode, String?) -> Void) {
        let item = self.item
        builder.actions(items) { perform($0, item) }
        if !items.isEmpty, !view.isEmpty { builder.separator() }
        builder.actions(view, primary: items.isEmpty) { perform($0, nil) }
    }
}

// MARK: - List

/// A list: its items as rows nearest the field first, filtered by the field, and with `preview` the selected
/// item's detail beside it.
@MainActor
final class ListComponent: NSView, Component {
    private let host: ViewHost
    private let context: ViewContext
    private let rows = RowsView()
    private let preview = DetailComponent()
    private var list: ListNode?
    private var query = Query("")
    /// The items the query leaves, in their order on screen.
    private var items: [ListNode.Item] = []
    private var selection: String?
    private var actionsMenu: MenuBuilder?

    let usesField = true

    init(host: ViewHost, context: ViewContext) {
        self.host = host
        self.context = context
        super.init(frame: .zero)
        addSubview(rows)
        addSubview(preview)
        rows.onClick = { [weak self] id in self?.select(id) }
        rows.onDoubleClick = { [weak self] id in
            self?.select(id)
            self?.run(index: 0)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ node: ViewNode) {
        guard case .list(let list) = node else { return }
        self.list = list
        layoutParts()
        render()
    }

    func filter(_ text: String) {
        query = Query(text)
        guard list?.filtering == .owner else { return render() }
        // The owner hears the text once typing pauses: a server need not answer every keystroke.
        pendingFilter?.cancel()
        let ask = DispatchWorkItem { [weak self] in self?.host.filter(text) }
        pendingFilter = ask
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.filterPause, execute: ask)
    }

    private var pendingFilter: DispatchWorkItem?
    static let filterPause: TimeInterval = 0.15

    override func layout() {
        super.layout()
        layoutParts()
    }

    private func layoutParts() {
        let split = list?.preview == true
        let listWidth = split ? (bounds.width * 0.45).rounded() : bounds.width
        rows.frame = CGRect(x: 0, y: 0, width: listWidth, height: bounds.height)
        preview.isHidden = !split
        preview.frame = CGRect(x: listWidth, y: 0, width: bounds.width - listWidth, height: bounds.height)
    }

    private func render() {
        guard let list else { return }
        let sections = list.filtered(by: query)
        items = sections.flatMap(\.items)
        var models: [RowModel] = []
        for section in sections {
            for item in section.items {
                var lazyIcon: (@MainActor () -> NSImage?)?
                if let icon = item.icon { lazyIcon = { IconImages.image(icon) } }
                models.append(RowModel(id: item.id, kind: .item, icon: lazyIcon, title: item.title,
                                       subtitle: item.subtitle, accessory: AccessoryImages.text(item.accessories),
                                       accessoryIcon: AccessoryImages.image(item.accessories),
                                       primary: (item.actions ?? list.actions)?.first?.title))
            }
            if let title = section.title { models.append(RowModel(id: "title:\(title)", kind: .title, title: title)) }
        }
        // Loading is the field's spinner; only a list done loading says it is empty.
        if models.isEmpty, list.loading != true {
            models = [RowModel(id: "empty", kind: .message, title: list.empty?.title ?? "No results", subtitle: list.empty?.subtitle)]
        }
        if selection == nil || !models.contains(where: { $0.id == selection && $0.isSelectable }) {
            selection = models.first(where: \.isSelectable)?.id
        }
        rows.show(models, selection: selection)
        showPreview()
    }

    private func select(_ id: String) {
        selection = id
        rows.select(id)
        showPreview()
    }

    private func showPreview() {
        guard list?.preview == true else { return }
        let detail = items.first { $0.id == selection }.flatMap { $0.detail ?? host.detail(for: $0.id) }
        preview.show(.detail(detail ?? DetailNode(id: "none")))
    }

    private var selectedItem: ListNode.Item? { items.first { $0.id == selection } }
    private var actions: ActionSet { ActionSet(item: selection, items: selectedItem?.actions ?? [], view: list?.actions ?? []) }

    private func run(index: Int) {
        let primary = actions.primary
        guard primary.indices.contains(index) else { return }
        context.perform(primary[index].action, item: primary[index].item, on: host)
    }

    func command(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(by: 1)
        case #selector(NSResponder.moveDown(_:)): move(by: -1)
        case #selector(NSResponder.insertNewline(_:)): run(index: 0)
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            guard let (action, item) = actions.keyed("opt+return") else { return false }
            context.perform(action, item: item, on: host)
        default: return false
        }
        return true
    }

    private func move(by step: Int) {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
        select(ids[min(max(index + step, 0), ids.count - 1)])
    }

    func keyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers == "\r" {
            run(index: 1)
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "k" {
            showActions()
            return true
        }
        if let (action, item) = actions.matching(event) {
            context.perform(action, item: item, on: host)
            return true
        }
        return false
    }

    /// At the selected row, or — an empty list's own actions — near the field.
    private func showActions() {
        let actions = self.actions
        guard !actions.isEmpty else { return }
        let builder = MenuBuilder()
        actions.fill(builder) { [weak self] action, item in
            guard let self else { return }
            self.context.perform(action, item: item, on: self.host)
        }
        actionsMenu = builder
        let at = selection.flatMap { rows.frame(of: $0) }.map { CGPoint(x: $0.maxX - 200, y: $0.maxY) } ?? CGPoint(x: rows.bounds.maxX - 200, y: 60)
        builder.menu.popUp(positioning: nil, at: at, in: rows)
    }
}

// MARK: - Detail

/// Formatted text, an image above it, metadata beneath: a view of its own, or a list's preview. As a
/// view, its actions are buttons along its foot — ↩ the first, ⌘↩ the second, ⌘K all of them.
@MainActor
final class DetailComponent: NSView, Component {
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let image = NSImageView()
    private let buttons = NSStackView()
    private let scrubber = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let scrubberLeading = NSTextField(labelWithString: "")
    private let scrubberTrailing = NSTextField(labelWithString: "")
    private var node: DetailNode?
    private let host: ViewHost?
    private let context: ViewContext?
    private var actionsMenu: MenuBuilder?
    let usesField = false

    /// Without a host it only shows: a list's preview.
    init(host: ViewHost? = nil, context: ViewContext? = nil) {
        self.host = host
        self.context = context
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 20, height: 16)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.documentView = text
        addSubview(scroll)
        image.imageScaling = .scaleProportionallyDown
        addSubview(image)
        buttons.orientation = .horizontal
        buttons.spacing = 8
        addSubview(buttons)
        // Submits once, where it is let go.
        scrubber.isContinuous = false
        scrubber.controlSize = .small
        scrubber.target = self
        scrubber.action = #selector(scrubbed)
        for label in [scrubberLeading, scrubberTrailing] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        scrubberTrailing.alignment = .right
        for view in [scrubber, scrubberLeading, scrubberTrailing] as [NSView] { addSubview(view) }
    }

    @objc private func scrubbed() {
        guard let host, let context, let id = node?.scrubber?.id else { return }
        host.submit([id: String(scrubber.doubleValue)], in: context)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { host != nil }

    func show(_ node: ViewNode) {
        guard case .detail(let detail) = node else { return }
        self.node = detail
        image.image = IconImages.image(detail.image, size: 160)
        image.isHidden = image.image == nil
        text.textStorage?.setAttributedString(Self.body(detail))
        let scrubs = detail.scrubber != nil && host != nil
        for view in [scrubber, scrubberLeading, scrubberTrailing] as [NSView] { view.isHidden = !scrubs }
        if let position = detail.scrubber, scrubs {
            scrubber.maxValue = max(position.maximum, 0.001)
            // The plugin's redraws must not pull the knob from under the pointer.
            if NSEvent.pressedMouseButtons & 1 == 0 { scrubber.doubleValue = position.value }
            scrubberLeading.stringValue = position.leading ?? ""
            scrubberTrailing.stringValue = position.trailing ?? ""
            scrubber.setAccessibilityValueDescription([position.leading, position.trailing].compactMap { $0 }.joined(separator: " of "))
        }
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if host != nil {
            for action in detail.actions ?? [] {
                let button = NSButton(title: action.title, target: self, action: #selector(clicked(_:)))
                button.image = IconImages.image(action.icon, size: 18)
                button.imagePosition = button.image == nil ? .noImage : .imageLeading
                button.bezelStyle = .push
                button.identifier = NSUserInterfaceItemIdentifier(action.id)
                buttons.addArrangedSubview(button)
            }
        }
        needsLayout = true
    }

    /// The body's inline Markdown in the panel's type — emphasis kept — then each metadata row.
    private static func body(_ detail: DetailNode) -> NSAttributedString {
        let body = NSMutableAttributedString()
        let base = NSFont.systemFont(ofSize: 14)
        if let markdown = detail.body,
           let parsed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                var font = base
                if intent.contains(.stronglyEmphasized) { font = .systemFont(ofSize: 14, weight: .semibold) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if intent.contains(.code) { font = .monospacedSystemFont(ofSize: 13, weight: .regular) }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
                if let link = run.link { attributes[.link] = link }
                body.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
        }
        for row in detail.metadata ?? [] {
            body.append(NSAttributedString(string: (body.length > 0 ? "\n\n" : "") + row.label + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]))
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
            if let link = row.link.flatMap(URL.init(string:)) { attributes[.link] = link }
            body.append(NSAttributedString(string: row.value, attributes: attributes))
            for (index, tag) in (row.tags ?? []).enumerated() {
                if index > 0 || !row.value.isEmpty { body.append(NSAttributedString(string: " ", attributes: attributes)) }
                let attachment = NSTextAttachment()
                attachment.image = TagImages.image(tag)
                attachment.bounds = CGRect(origin: CGPoint(x: 0, y: -4), size: attachment.image!.size)
                body.append(NSAttributedString(attachment: attachment))
            }
        }
        return body
    }

    private var actions: [ActionNode] { node?.actions ?? [] }

    private func run(_ action: ActionNode) {
        guard let host, let context else { return }
        context.perform(action, item: nil, on: host)
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let action = actions.first(where: { $0.id == sender.identifier?.rawValue }) else { return }
        run(action)
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == 36 || Int(event.keyCode) == 76, event.modifierFlags.intersection([.command, .option, .shift]).isEmpty,
           let first = actions.first {
            run(first)
            return
        }
        super.keyDown(with: event)
    }

    override func layout() {
        super.layout()
        let imageHeight: CGFloat = image.isHidden ? 0 : min(180, bounds.height * 0.45)
        image.frame = CGRect(x: 20, y: bounds.height - imageHeight - 12, width: bounds.width - 40, height: imageHeight)
        var foot: CGFloat = buttons.arrangedSubviews.isEmpty ? 0 : 52
        let fitting = buttons.fittingSize
        buttons.frame = CGRect(x: (bounds.width - fitting.width) / 2, y: 12, width: fitting.width, height: fitting.height)
        // Above the buttons: the position, its times either side.
        if !scrubber.isHidden {
            let y = foot + 6
            scrubberLeading.frame = CGRect(x: 20, y: y + 2, width: 48, height: 16)
            scrubberTrailing.frame = CGRect(x: bounds.width - 68, y: y + 2, width: 48, height: 16)
            scrubber.frame = CGRect(x: 72, y: y, width: bounds.width - 144, height: 20)
            foot += 32
        }
        scroll.frame = CGRect(x: 0, y: foot, width: bounds.width, height: bounds.height - foot - (imageHeight > 0 ? imageHeight + 16 : 0))
        text.frame.size.width = scroll.contentSize.width
    }

    func filter(_ text: String) {}

    func command(_ selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), let first = actions.first else { return false }
        run(first)
        return true
    }

    func keyEquivalent(_ event: NSEvent) -> Bool {
        guard host != nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers == "\r", actions.count > 1 {
            run(actions[1])
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "k", !actions.isEmpty {
            let builder = MenuBuilder()
            builder.actions(actions) { [weak self] action in self?.run(action) }
            actionsMenu = builder
            builder.menu.popUp(positioning: nil, at: CGPoint(x: bounds.midX - 100, y: 60), in: self)
            return true
        }
        if let action = actions.first(where: { matches($0.key, event) }) {
            run(action)
            return true
        }
        return false
    }
}

// MARK: - Form

/// Fields in a column, Tab between them and ⌘↩ to submit; each with its own validation message.
@MainActor
final class FormComponent: NSView, Component {
    private let host: ViewHost
    private let context: ViewContext
    private let stack = NSStackView()
    private var controls: [(field: FormNode.Field, control: NSView)] = []
    private var node: FormNode?
    let usesField = false

    init(host: ViewHost, context: ViewContext) {
        self.host = host
        self.context = context
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 28, bottom: 20, right: 28)
        addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ node: ViewNode) {
        guard case .form(let form) = node else { return }
        // Keep what was typed: a form redrawn with an error must not lose it.
        let typed = values
        self.node = form
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        controls = []
        if let title = form.title {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 17, weight: .semibold)
            stack.addArrangedSubview(label)
        }
        for field in form.fields {
            let control = makeControl(field, value: typed[field.id] ?? field.value)
            // The label above it is separate text: the control says its own name, and its error.
            control.setAccessibilityLabel(field.title)
            if let error = field.error { control.setAccessibilityHelp(error) }
            let label = NSTextField(labelWithString: field.title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            if field.kind != .toggle { stack.addArrangedSubview(label) }
            stack.addArrangedSubview(control)
            control.widthAnchor.constraint(equalToConstant: 560).isActive = field.kind != .toggle
            if let error = field.error {
                let message = NSTextField(labelWithString: error)
                message.textColor = .systemRed
                message.font = .systemFont(ofSize: 12)
                stack.addArrangedSubview(message)
            }
            controls.append((field, control))
        }
        let hint = NSTextField(labelWithString: "\(form.submit)  ⌘↩")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(hint)
        // Tab and ⇧Tab walk the fields in order.
        for (current, next) in zip(controls, controls.dropFirst()) { current.control.nextKeyView = next.control }
        controls.last?.control.nextKeyView = controls.first?.control
        needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.focusFirst() }
    }

    private func focusFirst() {
        guard let first = controls.first(where: { $0.field.error != nil })?.control ?? controls.first?.control else { return }
        window?.makeFirstResponder(first)
    }

    private func makeControl(_ field: FormNode.Field, value: String?) -> NSView {
        switch field.kind {
        case .text:
            let control = NSTextField(string: value ?? "")
            control.placeholderString = field.placeholder
            return control
        case .date:
            // ISO 8601's date, as the field's value is written; today when it has none.
            let control = NSDatePicker()
            control.datePickerStyle = .textFieldAndStepper
            control.datePickerElements = .yearMonthDay
            control.dateValue = value.flatMap(Self.dayFormat.date(from:)) ?? Date()
            return control
        case .folder:
            return FolderField(path: value ?? "", placeholder: field.placeholder)
        case .secure:
            let control = NSSecureTextField(string: value ?? "")
            control.placeholderString = field.placeholder
            return control
        case .multiline:
            let control = NSTextField(string: value ?? "")
            control.usesSingleLineMode = false
            control.cell?.wraps = true
            control.heightAnchor.constraint(equalToConstant: 72).isActive = true
            return control
        case .toggle:
            let control = NSButton(checkboxWithTitle: field.title, target: nil, action: nil)
            control.state = value == "true" ? .on : .off
            return control
        case .choice:
            let control = NSPopUpButton()
            for option in field.options ?? [] {
                control.addItem(withTitle: option.title)
                control.lastItem?.representedObject = option.value
            }
            if let index = field.options?.firstIndex(where: { $0.value == value }) { control.selectItem(at: index) }
            return control
        }
    }

    private static let dayFormat: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withFullDate]
        format.timeZone = .current
        return format
    }()

    /// What every field holds now, as the form submits it.
    var values: [String: String] {
        var values: [String: String] = [:]
        for (field, control) in controls {
            switch control {
            case let folder as FolderField: values[field.id] = folder.path
            case let date as NSDatePicker: values[field.id] = Self.dayFormat.string(from: date.dateValue)
            case let popUp as NSPopUpButton: values[field.id] = popUp.selectedItem?.representedObject as? String
            case let button as NSButton: values[field.id] = button.state == .on ? "true" : "false"
            case let text as NSTextField: values[field.id] = text.stringValue
            default: break
            }
        }
        return values
    }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    func filter(_ text: String) {}

    func command(_ selector: Selector) -> Bool { false }

    func keyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command, event.charactersIgnoringModifiers == "\r" else { return false }
        host.submit(values, in: context)
        return true
    }
}

/// A folder's path, typed or chosen: a field and Choose… beside it.
@MainActor
final class FolderField: NSView {
    private let text = NSTextField(string: "")
    private let choose = NSButton(title: "Choose…", target: nil, action: nil)

    var path: String { (text.stringValue as NSString).expandingTildeInPath }

    init(path: String, placeholder: String?) {
        super.init(frame: .zero)
        text.stringValue = (path as NSString).abbreviatingWithTildeInPath
        text.placeholderString = placeholder ?? "~/Folder"
        choose.bezelStyle = .push
        choose.target = self
        choose.action = #selector(chooseFolder)
        let row = NSStackView(views: [text, choose])
        row.spacing = 8
        row.frame = bounds
        row.autoresizingMask = [.width, .height]
        addSubview(row)
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // The control's name is its field's: Tab lands in the text.
    override func setAccessibilityLabel(_ label: String?) { text.setAccessibilityLabel(label) }
    override var nextKeyView: NSView? {
        get { text.nextKeyView }
        set { text.nextKeyView = newValue }
    }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(text) ?? false }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        text.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Grid

/// Images in rows, read upward from the field as the list is: the first row at the foot, ↑ away from it.
/// The arrows walk them, ↩ runs the selected one's first action, ⌘↩ its second, ⌘K all of them; it
/// scrolls, with views only for the rows in sight.
@MainActor
final class GridComponent: NSView, Component {
    private let host: ViewHost
    private let context: ViewContext
    private let scroll = NSScrollView()
    private let canvas = NSView()
    private var grid: GridNode?
    private var items: [GridNode.Item] = []
    private var selection = 0
    private var cells: [Int: GridCell] = [:]
    private var actionsMenu: MenuBuilder?
    let usesField = true
    private var query = Query("")

    static let inset: CGFloat = 16

    init(host: ViewHost, context: ViewContext) {
        self.host = host
        self.context = context
        super.init(frame: .zero)
        scroll.documentView = canvas
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ node: ViewNode) {
        guard case .grid(let grid) = node else { return }
        self.grid = grid
        refilter()
    }

    func filter(_ text: String) {
        query = Query(text)
        selection = 0
        refilter()
    }

    private func refilter() {
        let all = grid?.items ?? []
        items = query.isEmpty ? all : all.filter { item in item.title.map { Matcher.match(query, $0, subsequence: true) != nil } ?? false }
        selection = min(selection, max(items.count - 1, 0))
        cells.values.forEach { $0.removeFromSuperview() }
        cells = [:]
        needsLayout = true
    }

    private var columns: Int { max(1, grid?.columns ?? 5) }
    private var cellSize: CGFloat { max(1, (bounds.width - 2 * Self.inset) / CGFloat(columns)) }

    /// A cell's place on the canvas, whose origin is at its foot.
    private func frame(of index: Int) -> CGRect {
        CGRect(x: Self.inset + CGFloat(index % columns) * cellSize, y: CGFloat(index / columns) * cellSize + 8, width: cellSize, height: cellSize)
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let rows = (items.count + columns - 1) / columns
        canvas.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height, CGFloat(rows) * cellSize + 16))
        for (index, cell) in cells { cell.frame = frame(of: index) }
        showVisible()
    }

    @objc private func scrolled() { showVisible() }

    /// Cells for the rows in sight, and a row either side; the rest go.
    private func showVisible() {
        guard !items.isEmpty else { return }
        let visible = scroll.contentView.bounds
        let first = max(0, Int((visible.minY - 8) / cellSize) - 1), last = Int((visible.maxY - 8) / cellSize) + 1
        let wanted = Set((first * columns)..<min(items.count, (last + 1) * columns))
        for (index, cell) in cells where !wanted.contains(index) {
            cell.removeFromSuperview()
            cells[index] = nil
        }
        for index in wanted where cells[index] == nil {
            let cell = GridCell(item: items[index], size: cellSize)
            cell.frame = frame(of: index)
            cell.isSelected = index == selection
            cell.onClick = { [weak self] count in
                self?.select(index)
                if count == 2 { self?.run(index: 0) }
            }
            canvas.addSubview(cell)
            cells[index] = cell
        }
    }

    private func select(_ index: Int) {
        cells[selection]?.isSelected = false
        selection = index
        cells[selection]?.isSelected = true
        canvas.scrollToVisible(frame(of: index).insetBy(dx: 0, dy: -8))
        NSAccessibility.post(element: cells[selection] ?? self, notification: .focusedUIElementChanged)
    }

    private var actions: ActionSet {
        let selected = items.indices.contains(selection) ? items[selection] : nil
        return ActionSet(item: selected?.id, items: selected?.actions ?? [], view: grid?.actions ?? [])
    }

    private func run(index: Int) {
        let primary = actions.primary
        guard primary.indices.contains(index) else { return }
        context.perform(primary[index].action, item: primary[index].item, on: host)
    }

    func command(_ selector: Selector) -> Bool {
        let count = items.count
        // ↩ reaches the view's own first action with no item to select.
        if selector == #selector(NSResponder.insertNewline(_:)) {
            run(index: 0)
            return true
        }
        guard count > 0 else { return false }
        switch selector {
        case #selector(NSResponder.moveLeft(_:)): select(max(0, selection - 1))
        case #selector(NSResponder.moveRight(_:)): select(min(count - 1, selection + 1))
        case #selector(NSResponder.moveUp(_:)): select(min(count - 1, selection + columns))
        case #selector(NSResponder.moveDown(_:)): select(max(0, selection - columns))
        default: return false
        }
        return true
    }

    func keyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers == "\r" {
            run(index: 1)
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "k" {
            showActions()
            return true
        }
        if let (action, item) = actions.matching(event) {
            context.perform(action, item: item, on: host)
            return true
        }
        return false
    }

    private func showActions() {
        let actions = self.actions
        guard !actions.isEmpty else { return }
        let builder = MenuBuilder()
        actions.fill(builder) { [weak self] action, item in
            guard let self else { return }
            self.context.perform(action, item: item, on: self.host)
        }
        actionsMenu = builder
        let frame = items.indices.contains(selection) ? frame(of: selection) : CGRect(x: canvas.bounds.midX, y: 60, width: 0, height: 0)
        builder.menu.popUp(positioning: nil, at: CGPoint(x: frame.midX, y: frame.minY), in: canvas)
    }
}

/// One grid item: its image, its title beneath, the selection a rounded band behind both.
@MainActor
private final class GridCell: NSView {
    var onClick: ((Int) -> Void)?
    var isSelected = false {
        didSet {
            layer?.backgroundColor = isSelected ? CGColor(gray: 0, alpha: 0.095) : nil
            setAccessibilitySelected(isSelected)
        }
    }

    init(item: GridNode.Item, size: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title ?? item.id)
        let titled = item.title != nil
        let image = NSImageView(frame: bounds.insetBy(dx: 12, dy: titled ? 22 : 12).offsetBy(dx: 0, dy: titled ? 10 : 0))
        image.image = IconImages.image(item.image, size: size)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.autoresizingMask = [.width, .height]
        addSubview(image)
        if let title = item.title {
            let label = NSTextField(labelWithString: title)
            label.alignment = .center
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingTail
            label.frame = CGRect(x: 4, y: 4, width: size - 8, height: 16)
            label.autoresizingMask = [.width]
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.clickCount)
    }
}
