// The phone's scroll chrome: a scroll view that owns gesture physics and the system scroll
// indicator while the engine keeps every scroll decision.
//
// The terminal surface is not inside this scroll view. The renderer holds only the window's
// pixels, and the engine moves its own viewport when output arrives or a remote record
// replays, so a scroll view that owned the offset would fight the engine for it. Instead
// this view is transparent chrome over the drawn grid: it runs the momentum and draws the
// indicator, and `MobileScrollDriver` turns its offsets into the rows the session asks the
// engine for.
//
// What does not belong here: any decision. Which mode a gesture is routed under, whether
// the latch is held, and which row a given offset means all belong to the driver, which is
// a pure value in `DanTermMobileKit` and tested there. This file only translates UIKit
// callbacks into the driver's three inputs and performs the actions it hands back.
import DanTermMobileKit
import UIKit

/// Overlays the drawn grid with a scroll view whose state is a projection of the engine.
///
/// Its own pan recognizer is moved onto the terminal's input view by the placing controller,
/// because that view covers the grid and must keep tap-to-focus and long-press. That
/// layering is also what keeps this view out of the touch path: it is placed underneath the
/// input view, which covers every point of it, so no touch is ever delivered here.
@MainActor
final class TerminalScrollChromeView: UIScrollView, UIScrollViewDelegate {
    /// Asks the session to put this absolute row at the top of the window.
    var onScrollToTopRow: ((Int) -> Void)?
    /// Asks the session to move the window by whole rows -- negative toward history -- with
    /// the grid cell the gesture sits on.
    var onScrollByRows: ((_ rows: Int, _ column: Int, _ row: Int) -> Void)?

    /// The surface this chrome describes. Weak because the session controller owns both
    /// views; this one only borrows the surface to read its facts.
    weak var surface: TerminalSurfaceView?

    private var driver = MobileScrollDriver()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Chrome only: every pixel of the terminal is drawn by the surface underneath, and
        // the one thing this view draws of its own is the indicator.
        backgroundColor = .clear
        isOpaque = false
        indicatorStyle = .white
        showsHorizontalScrollIndicator = false
        // The content is sized to the engine's own extent, so nothing may adjust it: an
        // inset would move the offset a row maps to and put the chrome off by a safe area.
        contentInsetAdjustmentBehavior = .never
        isDirectionalLockEnabled = true
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Re-reads the surface and hands the driver the engine's current truth.
    ///
    /// Called for every replica change, every local scroll, and every layout pass. Which of
    /// those actually moved the projection is the driver's question: while the user is
    /// interacting it reflects nothing, and when idle it reconciles the chrome with the
    /// engine, which is also how a remote viewport record reaches the indicator.
    func refresh() {
        let facts = surface?.scrollFacts
        // Before the reflection, because the offset a projection implies is only reachable
        // once the viewport is the window's own height.
        if let facts { resizeViewport(facts) }
        perform(driver.replicaChanged(
            projection: facts?.projection,
            rowHeight: facts?.rowHeight ?? 0,
            isAlternateScreenActive: facts?.isAlternateScreenActive ?? false
        ))
    }

    /// Puts this view exactly over the window the engine is showing.
    ///
    /// The height is the window's rows rather than the drawn frame's, so UIKit's maximum
    /// offset lands on the engine's maximum top row. An oversized viewport would keep the
    /// indicator from ever reaching the bottom and keep idle reflection from converging.
    private func resizeViewport(_ facts: TerminalScrollFacts) {
        guard let surface, let superview else { return }
        var rect = facts.drawnFrame
        if let projection = facts.projection, projection.windowRows > 0 {
            let height = CGFloat(projection.windowRows) * facts.rowHeight
            rect = CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
        }
        let placed = surface.convert(rect, to: superview)
        if frame != placed { frame = placed }
    }

    private func perform(_ actions: [MobileScrollDriverAction]) {
        for action in actions {
            switch action {
            case .reflect(let contentHeight, let offset, let showsIndicator):
                showsVerticalScrollIndicator = showsIndicator
                // No content width at all, rather than the view's: the engine has one
                // scrollable axis, and a width left behind by a rotation would let a
                // diagonal flick scroll sideways over nothing.
                contentSize = CGSize(width: 0, height: contentHeight)
                if contentOffset.y != offset { contentOffset = CGPoint(x: 0, y: offset) }
            case .scrollToTopRow(let row):
                onScrollToTopRow?(row)
            case .scrollByRows(let rows):
                let cell = gestureCell()
                onScrollByRows?(rows, cell.column, cell.row)
            case .recenter(let offset):
                // Bookkeeping, not a scroll: the driver has already moved its baseline by
                // the same distance, so this offset change carries no gesture. It lands
                // mid-drag on purpose, which is what keeps delta mode's ends unreachable.
                contentOffset = CGPoint(x: 0, y: offset)
            }
        }
    }

    /// The grid cell the gesture sits on. The origin when the surface cannot answer, which
    /// is the position the phone reported before it could ask at all.
    private func gestureCell() -> (column: Int, row: Int) {
        guard let surface,
              let cell = surface.gridCell(at: panGestureRecognizer.location(in: surface))
        else { return (0, 0) }
        return cell
    }

    /// Reports the latch from the callback that fired rather than from `isDragging` and its
    /// siblings, whose value at the exact instant a delegate method runs is not stated. A
    /// latch left held by one wrong reading would freeze the chrome for good.
    private func interactionChanged(_ interaction: MobileScrollInteraction) {
        perform(driver.interactionChanged(interaction))
    }

    // MARK: - UIScrollViewDelegate

    // UIScrollViewDelegate: called for every offset change, this view's own and the user's.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        perform(driver.offsetChanged(contentOffset.y))
    }

    // UIScrollViewDelegate: called when a drag begins.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        interactionChanged([.tracking, .dragging])
    }

    // UIScrollViewDelegate: called when the finger lifts, saying whether momentum follows.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        interactionChanged(decelerate ? .decelerating : [])
    }

    // UIScrollViewDelegate: called when momentum starts.
    func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        interactionChanged(.decelerating)
    }

    // UIScrollViewDelegate: called when momentum stops.
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        interactionChanged([])
    }
}
