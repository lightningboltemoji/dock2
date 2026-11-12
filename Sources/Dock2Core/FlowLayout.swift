import CoreGraphics

/// A list laid out as `flow` ([views](../../.agents/product/plugins/views.md#flow)): each section's title on a line of
/// its own, its items after it as pills side by side, read like words, a line ending where the next would not fit.
public enum FlowLayout {
    public enum Piece: Equatable, Sendable {
        case title
        /// An item, as wide as its pill would draw.
        case pill(width: Double)
        /// Where there is nothing to show: a row's height across the whole width.
        case message
    }

    public static let pillHeight = 7 * PanelMetrics.unit
    /// Between pills, side by side or a line apart; and above a section's title, after the pills before it.
    public static let gap = 2 * PanelMetrics.unit
    /// The widest a pill draws, as a tag: an item in a flow is short, and past this its title ends in an ellipsis.
    public static let widest = 240.0

    /// Each piece's frame from the top, its lines between `left` and `right`, and the height they all take. A pill
    /// wider than its line is cut to it.
    public static func frames(_ pieces: [Piece], left: Double, right: Double, titleHeight: Double,
                              messageHeight: Double) -> (frames: [CGRect], height: Double) {
        var frames: [CGRect] = []
        frames.reserveCapacity(pieces.count)
        var x = left, y = 0.0
        // The bottom of the last line placed: a new line starts there.
        var bottom = 0.0
        var onLine = false
        for piece in pieces {
            switch piece {
            case .title:
                let top = onLine ? bottom + gap : bottom
                frames.append(CGRect(x: left, y: top, width: right - left, height: titleHeight))
                (x, y, bottom, onLine) = (left, top + titleHeight, top + titleHeight, false)
            case .message:
                frames.append(CGRect(x: 0, y: bottom, width: right + left, height: messageHeight))
                (x, y, bottom, onLine) = (left, bottom + messageHeight, bottom + messageHeight, false)
            case .pill(let width):
                let width = min(width, widest, right - left)
                if onLine, x + width > right {
                    (x, y) = (left, bottom + gap)
                }
                frames.append(CGRect(x: x, y: y, width: width, height: pillHeight))
                x += width + gap
                bottom = y + pillHeight
                onLine = true
            }
        }
        return (frames, bottom)
    }

    /// From the pill at `index`, the one on the next line up or down nearest it across, the lines of every section
    /// counted alike; nil past the first line or the last.
    public static func vertical(from index: Int, in frames: [CGRect], pills: [Bool], down: Bool) -> Int? {
        let line = frames[index].minY
        let candidates = frames.indices.filter { pills[$0] && (down ? frames[$0].minY > line : frames[$0].minY < line) }
        guard let next = down ? candidates.map({ frames[$0].minY }).min() : candidates.map({ frames[$0].minY }).max() else { return nil }
        let across = frames[index].midX
        return candidates.filter { frames[$0].minY == next }.min { abs(frames[$0].midX - across) < abs(frames[$1].midX - across) }
    }
}
