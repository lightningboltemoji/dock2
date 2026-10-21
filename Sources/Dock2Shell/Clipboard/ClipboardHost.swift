import AppKit
import Dock2Core
import Dock2System

/// Clipboard History ([clipboard](product/clipboard.md#finding-it)): every entry as a list with a preview,
/// newest nearest the field; each one's text, image or files loaded only when it is selected.
@MainActor
final class ClipboardHost: ViewHost {
    private let clipboard: ClipboardController
    private let settings: SettingsStore
    private(set) var node: ViewNode
    var onUpdate: (() -> Void)?
    /// Typed in the field: the history filters by search's own rule, its text included.
    private var query = Query("")

    /// Quick Look of a copied file, on the stack.
    private let quickLook: (URL) -> Void

    init(clipboard: ClipboardController, settings: SettingsStore, quickLook: @escaping (URL) -> Void) {
        self.clipboard = clipboard
        self.settings = settings
        self.quickLook = quickLook
        node = .list(ListNode(id: "clipboard", sections: []))
        node = makeNode()
    }

    private func makeNode() -> ViewNode {
        let now = Date()
        let entries = query.isEmpty ? clipboard.history.entries
            : clipboard.history.matches(query).enumerated().sorted { ($0.element.match.kind, $0.offset) < ($1.element.match.kind, $1.offset) }
                .map(\.element.entry)
        let items = entries.map { entry in
            ListNode.Item(id: entry.id, icon: Self.icon(entry), title: entry.title, subtitle: Self.subtitle(entry, now: now),
                          accessories: entry.pinned ? [.init(icon: .symbol("pin.fill"))] : nil,
                          actions: actions(entry))
        }
        let empty = !query.isEmpty ? nil : settings[Settings.clipboardHistory]
            ? ListNode.EmptyState(title: "Nothing copied yet", subtitle: "What you copy shows here.")
            : ListNode.EmptyState(title: "Clipboard history is off", subtitle: "Settings → Clipboard turns it on.")
        return .list(ListNode(id: "clipboard", title: "Clipboard History", sections: [.init(items: items)], filtering: .owner,
                              preview: true, empty: empty))
    }

    func filter(_ text: String) {
        query = Query(text)
        refresh()
    }

    /// The history changed while open.
    func refresh() {
        node = makeNode()
        onUpdate?()
    }

    /// ↩ pastes and ⌘↩ copies — the other way round when Settings says ↩ copies.
    private func actions(_ entry: ClipEntry) -> [ActionNode] {
        let paste = ActionNode(id: "paste", title: "Paste", icon: .symbol("doc.on.clipboard"))
        let copy = ActionNode(id: "copy", title: "Copy", icon: .symbol("doc.on.doc"))
        var actions = settings[Settings.clipboardPastes] ? [paste, copy] : [copy, paste]
        actions.append(ActionNode(id: "plain", title: "Paste as Plain Text", key: "opt+return"))
        actions.append(ActionNode(id: entry.pinned ? "unpin" : "pin", title: entry.pinned ? "Unpin" : "Pin", key: "cmd+shift+p"))
        if entry.kind == .files || entry.kind == .link { actions.append(ActionNode(id: "open", title: "Open", key: "cmd+o")) }
        // Quick Look needs a file on disk: what else the history holds stays sealed, its preview beside the list.
        if entry.kind == .files { actions.append(ActionNode(id: "look", title: "Quick Look", key: "cmd+y")) }
        actions.append(ActionNode(id: "delete", title: "Delete", key: "cmd+shift+d", destructive: true))
        return actions
    }

    func perform(action: String, item: String?, in context: ViewContext) {
        guard let id = item, let entry = clipboard.entry(id) else { return }
        switch action {
        case "paste":
            context.dismiss()
            clipboard.paste(id)
        case "plain":
            context.dismiss()
            clipboard.paste(id, plain: true)
        case "copy":
            if clipboard.copy(id) {
                context.dismiss()
                context.notice("Copied")
            }
        case "pin", "unpin":
            clipboard.setPinned(id, action == "pin")
            refresh()
        case "delete":
            clipboard.delete(id)
            refresh()
        case "look":
            if let file = entry.files.first { quickLook(URL(fileURLWithPath: file)) }
        case "open":
            clipboard.open(id)
            context.dismiss()
        default:
            break
        }
    }

    /// The selected entry, in full: its text, its image, its files; where it came from and when.
    func detail(for item: String) -> DetailNode? {
        guard let entry = clipboard.entry(item) else { return nil }
        let data = clipboard.data(for: item) ?? [:]
        var metadata: [DetailNode.Metadata] = []
        if let source = entry.sourceName { metadata.append(.init(label: "From", value: source)) }
        metadata.append(.init(label: "Copied", value: entry.date.formatted(date: .abbreviated, time: .shortened)))
        var body: String?
        var image: Icon?
        switch entry.kind {
        case .text, .richText, .link:
            body = data["public.utf8-plain-text"].map { String(decoding: $0, as: UTF8.self) } ?? entry.title
            metadata.append(.init(label: "Size", value: "\(body?.count ?? 0) characters"))
        case .image:
            if let bytes = data["public.png"] ?? data["public.tiff"] ?? data["public.jpeg"] ?? data["public.heic"],
               let picture = NSImage(data: bytes), let tiff = picture.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                image = .png(png)
                metadata.append(.init(label: "Size", value: "\(Int(picture.size.width)) × \(Int(picture.size.height))"))
            }
        case .files:
            body = entry.files.map { FileRanking.abbreviate($0, home: NSHomeDirectory()) }.joined(separator: "\n")
        case .color:
            // Kept as AppKit writes it: an archived NSColor.
            if let bytes = data["com.apple.cocoa.pasteboard.color"],
               let color = (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: bytes))?.usingColorSpace(.sRGB) {
                let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
                image = Self.swatch(color)
                body = "#" + channels.map { String(format: "%02X", $0) }.joined()
                metadata.append(.init(label: "sRGB", value: channels.map(String.init).joined(separator: " ")))
            } else {
                body = "A colour"
            }
        }
        // Markdown would read a pasted asterisk as emphasis: the text is shown as it was copied.
        return DetailNode(id: item, body: body.map(Self.literal), image: image, metadata: metadata)
    }

    /// The colour as a swatch, for the preview.
    private static func swatch(_ color: NSColor) -> Icon? {
        let image = NSImage(size: NSSize(width: 240, height: 140), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return .png(png)
    }

    /// Text that Markdown leaves as it is.
    private static func literal(_ text: String) -> String {
        var escaped = ""
        for character in text {
            // A backslash before any ASCII punctuation is an escape, consumed: safe for every one of them.
            if character.isASCII, character.isPunctuation || character.isSymbol { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    static func icon(_ entry: ClipEntry) -> Icon {
        switch entry.kind {
        case .files: entry.files.first.map(Icon.file) ?? .symbol("doc")
        case .image: entry.thumbnail.map(Icon.png) ?? .symbol("photo")
        case .color: .symbol("paintpalette")
        case .link: .symbol("link")
        case .richText: .symbol("doc.richtext")
        case .text: .symbol("doc.plaintext")
        }
    }

    /// "Safari · 5 min ago".
    static func subtitle(_ entry: ClipEntry, now: Date) -> String {
        let when = RelativeDateTimeFormatter().localizedString(for: entry.date, relativeTo: now)
        return [entry.sourceName, when].compactMap { $0 }.joined(separator: " · ")
    }
}
