import AppKit
import Dock2Core

/// Whoever a view belongs to: dock2's own code for its views, the plugin host for a plugin's. The renderer
/// draws `node` and tells the host what the user did; the host answers by changing `node`.
@MainActor
protocol ViewHost: AnyObject {
    var node: ViewNode { get }
    /// Set by the renderer: call it whenever `node` changes.
    var onUpdate: (() -> Void)? { get set }
    /// An action chosen, on an item or — with no item — on the view.
    func perform(action: String, item: String?, in context: ViewContext)
    /// The field's text, for a list whose owner filters it.
    func filter(_ text: String)
    /// An option of the view's scope chosen, by id: the owner answers with the items it leaves, and the choice.
    func choose(scope value: String)
    func submit(_ values: [String: String], in context: ViewContext)
    /// A list item's preview, asked for when it is selected, for an item that carries none.
    func detail(for item: String) -> DetailNode?
    /// A list item's icon drawn by its owner, in place of the one it names: "Show all" draws search's.
    func icon(for item: String) -> NSImage?
    /// Popped or dismissed, with the item it had selected.
    func closed(selected: String?)
}

extension ViewHost {
    func filter(_ text: String) {}
    func choose(scope value: String) {}
    func detail(for item: String) -> DetailNode? { nil }
    func icon(for item: String) -> NSImage? { nil }
    func submit(_ values: [String: String], in context: ViewContext) {}
    func closed(selected: String?) {}
}

/// What a view's owner can do to the panel.
@MainActor
struct ViewContext {
    /// Done: dock2 goes back to resting.
    var dismiss: () -> Void
    var push: (ViewHost) -> Void
    var pop: () -> Void
    var toast: (String) -> Void
    /// Said where the field was, after a dismissal: "Copied".
    var notice: (String) -> Void
    /// Asks before `run`: an action marked destructive.
    var confirm: (String, @escaping () -> Void) -> Void
    /// Where ⌘Z finds what an action did: the panel's, which the field's typing shares.
    var undoManager: UndoManager?

    /// An action as the user chose it: a destructive one asks first.
    func perform(_ action: ActionNode, item: String?, on host: ViewHost) {
        let run = { host.perform(action: action.id, item: item, in: self) }
        if action.destructive == true { confirm(action.title, run) } else { run() }
    }
}

/// Images for the icons a view names, at a list row's size: a symbol is a glyph, in its tint if it names one.
/// Where an icon stands among apps' — search, Settings, the dock — it is `plated` instead.
@MainActor
enum IconImages {
    private static var cache: [String: NSImage] = [:]

    static func image(_ icon: Icon?, size: CGFloat = 36) -> NSImage? {
        guard let icon else { return nil }
        let key: String
        switch icon {
        case .symbol(let name, let tint): key = "s:\(name):\(tint?.rawValue ?? ""):\(size)"
        case .file(let path): key = "f:\(path)"
        case .app(let id): key = "a:\(id)"
        case .png, .image: key = ""
        }
        if !key.isEmpty, let image = cache[key] { return image }
        let image: NSImage?
        switch icon {
        case .symbol(let name, let tint):
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .regular))
            image = tint.flatMap { tint in symbol?.tinted(TagImages.color(tint)) } ?? symbol
        case .png(let data): image = NSImage(data: data)
        // Read into `png` as its plugin loads.
        case .image: image = nil
        case .file(let path): image = NSWorkspace.shared.icon(forFile: path)
        case .app(let id): image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        if !key.isEmpty { cache[key] = image }
        return image
    }

    /// An icon as a row draws it, in its box (`PanelMetrics.Row.iconBox`): an app's or a file's as it is, its plate
    /// within its own margin; a symbol or a picture fitted to the plate, so it shows as large as an app's beside it.
    static func row(_ icon: Icon, _ row: PanelMetrics.Row) -> NSImage? {
        let box = row.iconBox
        guard let image = image(icon, size: box) else { return nil }
        switch icon {
        case .file, .app: return image
        case .symbol, .png, .image: return fitted(image, to: row.plate, in: box)
        }
    }

    /// `image` scaled to fit a square `side` across, centred in one `box` across.
    static func fitted(_ image: NSImage, to side: CGFloat, in box: CGFloat) -> NSImage {
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1))
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = CGRect(x: (box - drawn.width) / 2, y: (box - drawn.height) / 2, width: drawn.width, height: drawn.height)
        let fitted = NSImage(size: NSSize(width: box, height: box), flipped: false) { _ in
            image.draw(in: rect)
            return true
        }
        fitted.isTemplate = image.isTemplate
        return fitted
    }

    /// An icon as it stands among apps': a symbol on the plate in its tint, else `tint`, else gray; a picture
    /// cropped to the plate's shape; an app's or a file's icon as it is.
    static func plated(_ icon: Icon, tint: Tint?, size: CGFloat = 36) -> NSImage? {
        switch icon {
        case .symbol(let name, let own): return plated(symbol: name, color: IconColor(own ?? tint ?? .gray), size: size)
        case .png(let data):
            guard let picture = NSImage(data: data) else { return nil }
            return IconPlate.picture(picture, color: IconColor(tint ?? .gray), size: size) ?? picture
        case .image, .file, .app: return image(icon, size: size)
        }
    }

    /// One of dock2's own: a symbol on the plate in any colour, violet among them.
    static func plated(symbol name: String, color: IconColor, size: CGFloat = 36) -> NSImage? {
        let key = "p:\(name):\(color.red),\(color.green),\(color.blue):\(size)"
        if let image = cache[key] { return image }
        let image = IconPlate.symbol(name, color: color, size: size) ?? image(.symbol(name), size: size)
        cache[key] = image
        return image
    }
}

/// A list item's accessories as its row draws them: the texts joined, the tags and icons side by side.
@MainActor
enum AccessoryImages {
    /// The square an icon stands in.
    private static let iconSize: CGFloat = 16
    /// What a tag cut to fit keeps: its pill, and a few letters.
    private static let shortestTag: CGFloat = 40

    static func text(_ accessories: [ListNode.Accessory]?) -> String? {
        let texts = (accessories ?? []).compactMap(\.text)
        return texts.isEmpty ? nil : texts.joined(separator: " · ")
    }

    /// The tags and icons side by side, as many as fit `room`, then a count of the rest.
    static func image(_ accessories: [ListNode.Accessory], in room: CGFloat) -> NSImage? {
        let marks = accessories.flatMap { accessory in
            [accessory.icon.flatMap(mark), accessory.tag.flatMap(mark)].compactMap { $0 }
        }
        let fit = PanelMetrics.marks(marks.map(\.image.size.width), in: room, gap: TagImages.gap, floor: shortestTag) {
            TagImages.width(Tag(text: "+\($0)"))
        }
        var images = zip(marks, fit.widths).map { mark, width in
            mark.tag.flatMap { width < mark.image.size.width ? TagImages.image($0, within: width) : nil } ?? mark.image
        }
        if fit.rest > 0 { images.append(TagImages.image(Tag(text: "+\(fit.rest)"))) }
        guard images.count > 1 else { return images.first }
        let size = NSSize(width: images.map(\.size.width).reduce(0, +) + TagImages.gap * CGFloat(images.count - 1),
                          height: images.map(\.size.height).max() ?? 0)
        return NSImage(size: size, flipped: false) { rect in
            var x: CGFloat = 0
            for image in images {
                image.draw(in: CGRect(x: x, y: (rect.height - image.size.height) / 2, width: image.size.width, height: image.size.height))
                x += image.size.width + TagImages.gap
            }
            return true
        }
    }

    private static func mark(_ tag: Tag) -> (image: NSImage, tag: Tag?)? {
        tag.line.isEmpty ? nil : (TagImages.image(tag), tag)
    }

    /// An icon in its square, never scaled up; a symbol that names no tint takes the secondary label colour.
    private static func mark(_ icon: Icon) -> (image: NSImage, tag: Tag?)? {
        guard let image = IconImages.image(icon, size: 22) else { return nil }
        let fitted = IconImages.fitted(image, to: min(iconSize, max(image.size.width, image.size.height)), in: iconSize)
        return (image.isTemplate ? fitted.tinted(.secondaryLabelColor) : fitted, nil)
    }
}

/// A tag as a pill: its text in the tint, over the tint faintly; without one, the secondary label colour.
/// An image drawn as it is shown, so it follows the appearance.
@MainActor
enum TagImages {
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let height: CGFloat = 18
    /// Between tags, side by side or a line apart.
    static let gap: CGFloat = 6
    /// The widest a pill draws: a tag is short text, and past this its text ends in an ellipsis.
    static let widest: CGFloat = 240
    private static let padding: CGFloat = 7

    static func width(_ tag: Tag) -> CGFloat {
        ((tag.line as NSString).size(withAttributes: [.font: font]).width + 2 * padding).rounded(.up)
    }

    /// The pill, at most `limit` wide, with `below` of clear space under it.
    static func image(_ tag: Tag, within limit: CGFloat = widest, below: CGFloat = 0) -> NSImage {
        let tint = tag.tint
        let line = tag.line
        let size = NSSize(width: min(width(tag), limit, widest), height: height + below)
        return NSImage(size: size, flipped: false) { rect in
            let pill = CGRect(x: 0, y: below, width: rect.width, height: height)
            let color = Self.color(tint)
            color.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: pill, xRadius: height / 2, yRadius: height / 2).fill()
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            let textHeight = text.size().height
            text.draw(in: CGRect(x: padding, y: pill.midY - textHeight / 2, width: rect.width - 2 * padding, height: textHeight))
            return true
        }
    }

    static func color(_ tint: Tint?) -> NSColor {
        switch tint {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .gray: .systemGray
        case nil: .secondaryLabelColor
        }
    }
}
