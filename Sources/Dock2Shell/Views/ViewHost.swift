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
    func closed()
}

extension ViewHost {
    func filter(_ text: String) {}
    func detail(for item: String) -> DetailNode? { nil }
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

    /// An action as the user chose it: a destructive one asks first.
    func perform(_ action: ActionNode, item: String?, on host: ViewHost) {
        let run = { host.perform(action: action.id, item: item, in: self) }
        if action.destructive == true { confirm(action.title, run) } else { run() }
    }
}

/// Images for the icons a view names, at a list row's size.
@MainActor
enum IconImages {
    private static var cache: [String: NSImage] = [:]

    static func image(_ icon: Icon?, size: CGFloat = 36) -> NSImage? {
        guard let icon else { return nil }
        let key: String
        switch icon {
        case .symbol(let name): key = "s:\(name):\(size)"
        case .file(let path): key = "f:\(path)"
        case .app(let id): key = "a:\(id)"
        case .png: key = ""
        }
        if !key.isEmpty, let image = cache[key] { return image }
        let image: NSImage?
        switch icon {
        case .symbol(let name):
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .regular))
        case .png(let data): image = NSImage(data: data)
        case .file(let path): image = NSWorkspace.shared.icon(forFile: path)
        case .app(let id): image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        if !key.isEmpty { cache[key] = image }
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
