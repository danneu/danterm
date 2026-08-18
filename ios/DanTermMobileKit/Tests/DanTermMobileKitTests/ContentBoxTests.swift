// Behavioral tests for the one pixel box the phone claims and draws inside.
import CoreGraphics
import DanTermMobileKit
import Testing

@Test("The claimed grid is drawn at native metrics inside the same content box")
func contentBoxClaimAndDrawAgree() throws {
    // Intent: the grid a claim names is the grid the surface draws, at the phone's own
    // cell metrics, and it never needs more pixels than the box it came from.
    // Why it exists: the claim reading and the drawing fit used to be two separate
    // readings of the view's extent, so an inset applied to one and not the other would
    // pin the pane to a grid the surface cannot show.
    // Scenario: a phone-sized box with a Dynamic Island top inset and side insets, at
    // both display scales a handset reports.
    for scale in [CGFloat(2), CGFloat(3)] {
        let box = try #require(MobileContentBox(
            width: 393,
            height: 852,
            insetTop: 59,
            insetLeading: 12,
            insetTrailing: 12,
            insetBottom: 0,
            displayScale: scale
        ))
        let grid = try #require(box.nativeGrid(fontSize: 11))
        let drawn = try #require(MobileObserveSurface(
            columns: grid.columns,
            rows: grid.rows,
            contentBox: box,
            fontSize: 11
        ))
        #expect(drawn.metrics.displayScale == scale)
        #expect(drawn.pixelWidth <= box.widthPixels)
        #expect(drawn.pixelHeight <= box.heightPixels)
    }
}

@Test("A content box with no room for a whole cell claims nothing")
func contentBoxWithoutAWholeCellHasNoGrid() throws {
    let box = try #require(MobileContentBox(
        width: 4,
        height: 4,
        insetTop: 0,
        insetLeading: 0,
        insetTrailing: 0,
        insetBottom: 0,
        displayScale: 3
    ))
    #expect(box.nativeGrid(fontSize: 11) == nil)
}

@Test("Insets that consume the whole extent leave no content box")
func contentBoxNeedsPixelsToDescribe() {
    #expect(MobileContentBox(
        width: 100,
        height: 100,
        insetTop: 60,
        insetLeading: 0,
        insetTrailing: 0,
        insetBottom: 40,
        displayScale: 3
    ) == nil)
    #expect(MobileContentBox(
        width: 100,
        height: 100,
        insetTop: 0,
        insetLeading: 50,
        insetTrailing: 50,
        insetBottom: 0,
        displayScale: 3
    ) == nil)
}

@Test("The content box stays clear of fractional insets at a non-integral scale")
func contentBoxRoundsAwayFromTheInsets() throws {
    // Intent: rounding the box to whole pixels moves its edges inward, never outward,
    // so no pixel it describes lies inside a top or side inset.
    // Why it exists: insets and display scales both produce fractions, and rounding the
    // box outward by half a pixel is how a row of cells ends up under the Dynamic Island.
    // Scenario: fractional insets on a fractional extent at a non-integral scale.
    let scale = CGFloat(2.5)
    let width = CGFloat(100.4)
    let height = CGFloat(200.6)
    let box = try #require(MobileContentBox(
        width: width,
        height: height,
        insetTop: 5.3,
        insetLeading: 2.1,
        insetTrailing: 3.7,
        insetBottom: 0,
        displayScale: scale
    ))
    #expect(CGFloat(box.originXPixels) >= 2.1 * scale)
    #expect(CGFloat(box.originXPixels + box.widthPixels) <= (width - 3.7) * scale)
    #expect(CGFloat(box.originYPixels) >= 5.3 * scale)
    #expect(CGFloat(box.originYPixels + box.heightPixels) <= height * scale)
}

@Test("New insets at unchanged bounds describe a new box")
func contentBoxFollowsInsetOnlyChanges() throws {
    // Intent: the box is recomputed from the insets, so an inset change with no bounds
    // change still moves it.
    // Why it exists: iOS delivers safe-area changes without a bounds change on some
    // rotations, and a box that only tracked bounds would keep drawing under the notch.
    // Scenario: the same extent read once with no insets and once with a top inset.
    let flat = try #require(MobileContentBox(
        width: 393,
        height: 852,
        insetTop: 0,
        insetLeading: 0,
        insetTrailing: 0,
        insetBottom: 0,
        displayScale: 3
    ))
    let inset = try #require(MobileContentBox(
        width: 393,
        height: 852,
        insetTop: 59,
        insetLeading: 0,
        insetTrailing: 0,
        insetBottom: 0,
        displayScale: 3
    ))
    #expect(flat != inset)
    #expect(inset.originYPixels > flat.originYPixels)
    #expect(inset.heightPixels < flat.heightPixels)
}

@Test("The content box reports its own point-space edges")
func contentBoxDescribesItsPointEdges() throws {
    // The layer that shows the drawn pixels is positioned in points, so the box has to
    // answer in points too or the position would be a third reading of the extent.
    let box = try #require(MobileContentBox(
        width: 393,
        height: 852,
        insetTop: 59,
        insetLeading: 12,
        insetTrailing: 12,
        insetBottom: 0,
        displayScale: 3
    ))
    #expect(box.originX == 12)
    #expect(box.maxY == 852)
}
