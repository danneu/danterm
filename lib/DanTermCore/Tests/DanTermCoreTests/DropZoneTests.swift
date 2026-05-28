// Swift Testing migration of the legacy `tests/DropZoneTests.swift` harness
// suite. Pins the pure `resolveDropZone` cursor-to-zone mapping against the
// edge, center, corner, boundary, and invalid-input matrix the legacy suite
// asserted. The legacy `testDropZoneFoo` strings double as both the display
// names and the function identifiers; name parity preserves the strings.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct DropZoneTests {
    private static let size = DropZoneSize(width: 400, height: 300)

    // MARK: - Edge bands

    @Test("testDropZoneLeft")
    func testDropZoneLeft() {
        // Intent: x=50 (12.5% from left) resolves into the left edge band as
        //   .splitLeft.
        // Why it exists: pins the left-band threshold so a refactor that
        //   widens or narrows the band cannot silently drop center coverage.
        // Scenario: spec-first edge check -- a drag drops near the left edge
        //   of a 400-wide pane and must split-left.
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 50, y: 150), paneSize: Self.size)
        #expect(result == .splitLeft)
    }

    @Test("testDropZoneRight")
    func testDropZoneRight() {
        // Intent: x=350 (87.5% from left) resolves into the right edge band
        //   as .splitRight.
        // Why it exists: pins the symmetric right-band threshold.
        // Scenario: spec-first edge check -- a drag drops near the right edge
        //   of a 400-wide pane and must split-right.
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 350, y: 150), paneSize: Self.size)
        #expect(result == .splitRight)
    }

    @Test("testDropZoneBottom")
    func testDropZoneBottom() {
        // Intent: y=37 (12.3% from bottom in macOS coords, Y=0 at bottom)
        //   resolves into the bottom edge band as .splitBottom.
        // Why it exists: pins the macOS Y-axis convention (origin at bottom)
        //   so the band logic does not flip after a coordinate-space tweak.
        // Scenario: spec-first edge check -- a drag drops near the bottom of
        //   a 300-tall pane and must split-bottom.
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 200, y: 37), paneSize: Self.size)
        #expect(result == .splitBottom)
    }

    @Test("testDropZoneTop")
    func testDropZoneTop() {
        // Intent: y=263 (87.7%) resolves into the top edge band as .splitTop.
        // Why it exists: pins the symmetric top-band threshold.
        // Scenario: spec-first edge check -- a drag drops near the top of a
        //   300-tall pane and must split-top.
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 200, y: 263), paneSize: Self.size)
        #expect(result == .splitTop)
    }

    // MARK: - Center

    @Test("testDropZoneCenter")
    func testDropZoneCenter() {
        // Intent: the exact center (x=200, y=150 in 400x300) resolves to .swap.
        // Why it exists: pins the center -> swap convention so the central
        //   region does not silently become a split direction.
        // Scenario: spec-first center check -- a drag drops in the pane
        //   center and must swap with the source pane.
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 200, y: 150), paneSize: Self.size)
        #expect(result == .swap)
    }

    @Test("testDropZoneExactCenter")
    func testDropZoneExactCenter() {
        // Intent: a second exact-center sample reaffirms the .swap result.
        // Why it exists: locked in by the legacy suite as a duplicate-anchor
        //   guard; kept verbatim for name parity.
        // Scenario: spec-first center check -- duplicate of testDropZoneCenter
        //   pinning the central region from a second framing.
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 200, y: 150), paneSize: Self.size)
        #expect(result == .swap)
    }

    // MARK: - Corners

    @Test("testDropZoneCornerCloserToTop")
    func testDropZoneCornerCloserToTop() {
        // Intent: a top-left corner sample where the cursor is closer to the
        //   top edge than the left edge resolves to .splitTop.
        // Why it exists: pins the per-axis distance comparison so a refactor
        //   that always picks horizontal in corners cannot silently regress.
        // Scenario: spec-first corner check -- vDist (0.05) < hDist (0.2)
        //   selects the closer top edge.
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 80, y: 285), paneSize: Self.size)
        #expect(result == .splitTop)
    }

    @Test("testDropZoneCornerCloserToLeft")
    func testDropZoneCornerCloserToLeft() {
        // Intent: a top-left corner sample where the cursor is closer to the
        //   left edge than the top edge resolves to .splitLeft.
        // Why it exists: pins the symmetric per-axis choice from the other
        //   side of the corner.
        // Scenario: spec-first corner check -- hDist (0.05) < vDist (0.2)
        //   selects the closer left edge.
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 20, y: 240), paneSize: Self.size)
        #expect(result == .splitLeft)
    }

    @Test("testDropZoneCornerEquidistantHorizontalWins")
    func testDropZoneCornerEquidistantHorizontalWins() {
        // Intent: at an exact corner where horizontal and vertical distances
        //   are equal, the horizontal axis wins (.splitLeft).
        // Why it exists: pins the tiebreaker so a refactor that flips to
        //   vertical-wins cannot silently rotate the corner zones 90 degrees.
        // Scenario: spec-first corner tiebreaker -- both distances equal 0.25.
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 100, y: 75), paneSize: Self.size)
        #expect(result == .splitLeft)
    }

    // MARK: - Boundary (edge band boundary)

    @Test("testDropZoneBoundaryIsEdge")
    func testDropZoneBoundaryIsEdge() {
        // Intent: a cursor exactly on the 25% edge-band threshold counts as
        //   the edge (<=), not the center.
        // Why it exists: pins the inclusive boundary so a strict `<` regression
        //   cannot suddenly bias .swap into the band.
        // Scenario: spec-first boundary check -- x=100 (fx=0.25) at center-y
        //   resolves to .splitLeft, not .swap.
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 100, y: 150), paneSize: Self.size)
        #expect(result == .splitLeft)
    }

    // MARK: - Invalid inputs

    @Test("testDropZoneZeroWidth")
    func testDropZoneZeroWidth() {
        // Intent: a zero-width pane returns nil (no valid zone).
        // Why it exists: pins the divide-by-zero guard so an unsized pane
        //   cannot produce a NaN-driven split direction.
        // Scenario: spec-first guard check -- a pane mid-collapse reports
        //   width=0; the drop must fall through without a zone.
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 0, y: 0), paneSize: DropZoneSize(width: 0, height: 100))
        #expect(result == nil, "zero width returns nil")
    }

    @Test("testDropZoneZeroHeight")
    func testDropZoneZeroHeight() {
        // Intent: a zero-height pane returns nil.
        // Why it exists: pins the symmetric per-axis guard.
        // Scenario: spec-first guard check -- a pane mid-collapse reports
        //   height=0; the drop must fall through without a zone.
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 0, y: 0), paneSize: DropZoneSize(width: 100, height: 0))
        #expect(result == nil, "zero height returns nil")
    }

    @Test("testDropZoneCursorOutside")
    func testDropZoneCursorOutside() {
        // Intent: a cursor with negative x (left of the pane) returns nil.
        // Why it exists: pins the bounds check so a drag that left the pane
        //   cannot silently snap to a band.
        // Scenario: spec-first out-of-bounds check -- a drag wanders left of
        //   the pane and the resolver must produce nil.
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: -10, y: 150), paneSize: Self.size)
        #expect(result == nil, "cursor outside returns nil")
    }

    @Test("testDropZoneCursorOutsideRight")
    func testDropZoneCursorOutsideRight() {
        // Intent: a cursor past the right edge of the pane returns nil.
        // Why it exists: pins the symmetric right-side bounds check.
        // Scenario: spec-first out-of-bounds check -- a drag overshoots the
        //   right edge and the resolver must produce nil.
        let result = resolveDropZone(cursorInPane: DropZonePoint(x: 500, y: 150), paneSize: Self.size)
        #expect(result == nil, "cursor past right edge returns nil")
    }
}
