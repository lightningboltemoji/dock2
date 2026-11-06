import AppKit

/// A scroll view that stays on overlay scrollers. AppKit puts a scroll view back on the system's style, which can be
/// `legacy`: a track down the side of the content, there whether anything scrolls or not.
final class OverlayScrollView: NSScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        super.scrollerStyle = .overlay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}
