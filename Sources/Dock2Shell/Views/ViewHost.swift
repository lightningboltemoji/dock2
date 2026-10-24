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
    func submit(_ values: [String: String], in context: ViewContext)
    /// A list item's preview, asked for when it is selected, for an item that carries none.
    func detail(for item: String) -> DetailNode?
    /// A list item's icon drawn by its owner, in place of the one it names: "Show all…" draws search's.
    func icon(for item: String) -> NSImage?
    func closed()
}

extension ViewHost {
    func filter(_ text: String) {}
    func detail(for item: String) -> DetailNode? { nil }
    func icon(for item: String) -> NSImage? { nil }
    func submit(_ values: [String: String], in context: ViewContext) {}
    func closed() {}
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
    static func text(_ accessories: [ListNode.Accessory]?) -> String? {
        let texts = (accessories ?? []).compactMap(\.text)
        return texts.isEmpty ? nil : texts.joined(separator: " · ")
    }

    static func image(_ accessories: [ListNode.Accessory]?) -> NSImage? {
        let images = (accessories ?? []).compactMap { accessory in
            accessory.tag.map(TagImages.image) ?? accessory.icon.flatMap { IconImages.image($0, size: 22) }
        }
        guard images.count > 1 else { return images.first }
        let gap: CGFloat = 6
        let size = NSSize(width: images.map(\.size.width).reduce(0, +) + gap * CGFloat(images.count - 1),
                          height: images.map(\.size.height).max() ?? 0)
        return NSImage(size: size, flipped: false) { rect in
            var x: CGFloat = 0
            for image in images {
                image.draw(in: CGRect(x: x, y: (rect.height - image.size.height) / 2, width: image.size.width, height: image.size.height))
                x += image.size.width + gap
            }
            return true
        }
    }
}

/// A tag as a pill: its text in the tint, over the tint faintly; without one, the secondary label colour.
/// An image drawn as it is shown, so it follows the appearance.
@MainActor
enum TagImages {
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    static func image(_ tag: Tag) -> NSImage {
        let text = tag.text as NSString
        let size = text.size(withAttributes: [.font: font])
        let pill = NSSize(width: (size.width + 14).rounded(.up), height: 18)
        let tint = tag.tint
        return NSImage(size: pill, flipped: false) { rect in
            let color = Self.color(tint)
            color.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            text.draw(at: CGPoint(x: 7, y: (rect.height - size.height) / 2), withAttributes: [.font: font, .foregroundColor: color])
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
