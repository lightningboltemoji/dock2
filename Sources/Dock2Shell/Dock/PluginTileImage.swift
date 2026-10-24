import AppKit
import Dock2Core

/// A plugin's tile as an image at whatever size the dock draws it ([dock](product/dock.md#what-dock2-adds)):
/// its icon as it stands among apps' — a symbol or a picture on the plate in `tint`, its plugin's — a progress
/// ring at its foot's corner, a badge at its head's, a caption across its foot.
enum PluginTileImage {
    static func image(_ node: TileNode, tint: Tint?) -> NSImage {
        let color = IconColor(tint ?? .gray)
        let base: NSImage? = switch node.image {
        case .symbol(let name, let own): IconPlate.symbol(name, color: own.map(IconColor.init) ?? color, size: 128)
        case .png(let data): NSImage(data: data).flatMap { IconPlate.picture($0, color: color, size: 128) }
        case .app(let id): NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
        case .file(let file): NSWorkspace.shared.icon(forFile: file)
        case .image, nil: IconPlate.empty(color: color, size: 128)
        }
        // Drawn on demand, so it is sharp at the tile's own size and scale.
        return NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            base?.draw(in: rect)
            draw(node, in: rect)
            return true
        }
    }

    private static func draw(_ node: TileNode, in rect: CGRect) {
        let inset = rect.width * (1 - IconPlate.fraction) / 2
        let shape = rect.insetBy(dx: inset, dy: inset)
        if let caption = node.caption, !caption.isEmpty { drawCaption(caption, in: shape) }
        if let progress = node.progress { drawRing(progress, in: shape) }
        if let badge = node.badge, !badge.isEmpty { drawBadge(badge, in: shape) }
    }

    private static func drawCaption(_ text: String, in shape: CGRect) {
        let font = NSFont.systemFont(ofSize: shape.height * 0.13, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let string = NSAttributedString(string: text, attributes: attributes)
        let width = min(string.size().width + shape.width * 0.12, shape.width * 0.9)
        let height = font.pointSize * 1.5
        let pill = CGRect(x: shape.midX - width / 2, y: shape.minY + shape.height * 0.06, width: width, height: height)
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: height / 2, yRadius: height / 2).fill()
        string.draw(with: pill.insetBy(dx: shape.width * 0.06, dy: (height - font.ascender + font.descender) / 2 - 1),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static func drawRing(_ progress: Double, in shape: CGRect) {
        let radius = shape.width * 0.16
        let center = CGPoint(x: shape.maxX - radius * 0.7, y: shape.minY + radius * 0.7)
        NSColor(white: 1, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius * 0.68, startAngle: 0, endAngle: 360)
        track.lineWidth = radius * 0.28
        NSColor(white: 0, alpha: 0.12).setStroke()
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius * 0.68, startAngle: 90, endAngle: 90 - 360 * min(1, max(0, progress)), clockwise: true)
        arc.lineWidth = radius * 0.28
        arc.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        arc.stroke()
    }

    private static func drawBadge(_ text: String, in shape: CGRect) {
        let font = NSFont.systemFont(ofSize: shape.height * 0.17, weight: .semibold)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let height = shape.height * 0.3
        let width = max(height, string.size().width + height * 0.6)
        let badge = CGRect(x: shape.maxX - width * 0.75, y: shape.maxY - height * 0.75, width: width, height: height)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: badge, xRadius: height / 2, yRadius: height / 2).fill()
        let size = string.size()
        string.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
    }
}
