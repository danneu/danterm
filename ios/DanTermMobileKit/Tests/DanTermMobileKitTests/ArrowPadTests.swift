// Behavioral tests for the floating arrow pad's per-pane ownership and its placement
// inside whatever terminal region the phone currently has.
import CoreGraphics
import DanTermMobileKit
import DanTermProtocol
import Foundation
import Testing

private func pane() -> PaneId { PaneId(rawValue: UUID()) }

@Test("A pane starts with the pad hidden at the bottom-trailing corner")
func arrowPadStartsHiddenAtBottomTrailing() {
    // Intent: a pane nobody has touched reports the documented default without needing an
    //   entry to be created for it first.
    // Why it exists: the pad is never pruned and panes appear at any time, so the default
    //   has to come from the absence of an entry rather than from a creation step.
    let state = MobileArrowPadState()
    let a = pane()
    #expect(state.isVisible(a) == false)
    #expect(state.position(a) == MobileArrowPadCorner.bottomTrailing.position)
}

@Test("Toggling, dismissing, and moving one pane leaves every other pane alone")
func arrowPadStateIsPerPane() {
    // Intent: visibility and position are owned per pane, so what one pane reports is
    //   unchanged by every event aimed at another.
    // Why it exists: the pad exists to be parked away from a particular pane's TUI
    //   content, which is worth nothing if a second pane inherits or overwrites it.
    var state = MobileArrowPadState()
    let a = pane()
    let b = pane()

    state.toggle(a)
    #expect(state.isVisible(a))
    #expect(state.isVisible(b) == false)

    state.move(a, to: MobileArrowPadCorner.topLeading.position)
    #expect(state.position(a) == MobileArrowPadCorner.topLeading.position)
    #expect(state.position(b) == MobileArrowPadCorner.bottomTrailing.position)

    state.toggle(b)
    state.hide(b)
    #expect(state.isVisible(b) == false)
    // A's own state survived every event aimed at B.
    #expect(state.isVisible(a))
    #expect(state.position(a) == MobileArrowPadCorner.topLeading.position)
}

@Test("A drag that ends after a pane switch commits to the pane it began on")
func arrowPadDragCommitsToItsOwnPane() {
    // Intent: the pane a completed drag writes to is the pane named at the call, so a
    //   selection change mid-drag cannot move the newly selected pane's pad.
    // Why it exists: the drag lives in UIKit while the selection lives in the session
    //   model; the two change independently, and only the explicit pane argument keeps
    //   them from crossing.
    var state = MobileArrowPadState()
    let a = pane()
    let b = pane()
    state.toggle(a)

    // The drag began on A. The selection moves to B before the finger lifts.
    state.toggle(b)
    state.move(a, to: MobileArrowPadCorner.topTrailing.position)

    #expect(state.position(a) == MobileArrowPadCorner.topTrailing.position)
    #expect(state.position(b) == MobileArrowPadCorner.bottomTrailing.position)
}

@Test("Dismissing a pane that never showed the pad stores nothing")
func arrowPadDismissalOfAnUntouchedPaneIsANoOp() {
    // Intent: hiding an already-hidden pad leaves the state exactly as it was.
    // Why it exists: every terminal tap dismisses, and the map is never pruned, so a tap
    //   on a pane that never opened the pad must not accumulate an entry for it.
    var state = MobileArrowPadState()
    let a = pane()
    let untouched = state
    state.hide(a)
    #expect(state == untouched)
}

@Test("A stored position resolves to the same relative place in any region")
func arrowPadPlacementRestoresTheSameRelativePlace() {
    // Intent: one stored position lands the pad against the same edges whatever region
    //   the phone hands it, which is what makes rotation and a keyboard lift a re-resolve
    //   rather than a move.
    // Why it exists: I4 -- rotation and keyboard changes must never overwrite the saved
    //   preferred position, so placement has to be a pure function of it and the region.
    let padSize = CGSize(width: 120, height: 120)
    let portrait = CGSize(width: 390, height: 700)
    let landscape = CGSize(width: 844, height: 320)

    let corner = MobileArrowPadCorner.bottomTrailing.position
    let inPortrait = MobileArrowPadPlacement(
        position: corner, padSize: padSize, regionSize: portrait
    )
    let inLandscape = MobileArrowPadPlacement(
        position: corner, padSize: padSize, regionSize: landscape
    )
    #expect(inPortrait.leadingInset == portrait.width - padSize.width)
    #expect(inPortrait.topInset == portrait.height - padSize.height)
    #expect(inLandscape.leadingInset == landscape.width - padSize.width)
    #expect(inLandscape.topInset == landscape.height - padSize.height)

    let middle = MobileArrowPadPosition(leadingFraction: 0.5, topFraction: 0.5)
    let centered = MobileArrowPadPlacement(
        position: middle, padSize: padSize, regionSize: portrait
    )
    #expect(centered.leadingInset == (portrait.width - padSize.width) / 2)
    #expect(centered.topInset == (portrait.height - padSize.height) / 2)
}

@Test("The resolved pad never leaves the region it was given")
func arrowPadPlacementStaysInsideTheRegion() {
    // Intent: whatever the stored position and however small the region, the resolved
    //   frame sits inside it -- including the degenerate region a keyboard can leave.
    // Why it exists: I4 -- the pad must stay within the visible safe terminal region, and
    //   a keyboard-shortened region is the case that produces a negative free space.
    let padSize = CGSize(width: 120, height: 120)
    let regions = [
        CGSize(width: 390, height: 700),
        CGSize(width: 844, height: 320),
        // A keyboard-shortened region narrower and shorter than the pad itself.
        CGSize(width: 100, height: 90),
        CGSize(width: 0, height: 0),
    ]
    for region in regions {
        for corner in MobileArrowPadCorner.allCases {
            let placement = MobileArrowPadPlacement(
                position: corner.position, padSize: padSize, regionSize: region
            )
            #expect(placement.leadingInset >= 0)
            #expect(placement.topInset >= 0)
            #expect(placement.leadingInset <= max(region.width - padSize.width, 0))
            #expect(placement.topInset <= max(region.height - padSize.height, 0))
        }
    }
}

@Test("A drag's insets become the fraction that restores them")
func arrowPadPositionRoundTripsThroughInsets() {
    // Intent: the position a completed drag commits resolves back to the insets the drag
    //   ended at, so the pad does not jump when the drag's own layout is replaced by the
    //   resolved one.
    // Why it exists: the drag is the only writer of a non-corner position; a lossy
    //   conversion would show as a visible snap the moment the finger lifts.
    let padSize = CGSize(width: 120, height: 120)
    let region = CGSize(width: 390, height: 700)
    let moved = MobileArrowPadCorner.bottomTrailing.position.moved(
        toLeadingInset: 30, topInset: 200, padSize: padSize, regionSize: region
    )
    let placement = MobileArrowPadPlacement(
        position: moved, padSize: padSize, regionSize: region
    )
    #expect(abs(placement.leadingInset - 30) < 0.0001)
    #expect(abs(placement.topInset - 200) < 0.0001)
}

@Test("A drag past an edge, or in a region with no room, keeps a usable position")
func arrowPadPositionRejectsPlacesThatAreNotPlaces() {
    // Intent: insets outside the free space clamp to the nearest edge, and a region with
    //   no free space at all leaves the stored position untouched.
    // Why it exists: the drag reports raw translation, so it can overshoot; and a region
    //   smaller than the pad has no fraction to compute, which must not become a NaN
    //   written into stored state.
    let padSize = CGSize(width: 120, height: 120)
    let region = CGSize(width: 390, height: 700)
    let start = MobileArrowPadCorner.topLeading.position

    let overshot = start.moved(
        toLeadingInset: 10_000, topInset: -500, padSize: padSize, regionSize: region
    )
    #expect(overshot == MobileArrowPadPosition(leadingFraction: 1, topFraction: 0))

    let noRoom = MobileArrowPadCorner.bottomTrailing.position.moved(
        toLeadingInset: 40, topInset: 40, padSize: padSize, regionSize: CGSize(width: 50, height: 50)
    )
    #expect(noRoom == MobileArrowPadCorner.bottomTrailing.position)

    #expect(
        MobileArrowPadPosition(leadingFraction: .nan, topFraction: .infinity)
            == MobileArrowPadCorner.bottomTrailing.position
    )
}

@Test("The bottom row omits the arrows while the mapper still maps all four")
func accessoryBarRowOmitsTheArrows() {
    // Intent: the row the bar draws no longer offers an arrow, and every one of the four
    //   arrow cases still produces the input the pad will send.
    // Why it exists: the arrows moved out of the row into the floating pad, and the enum
    //   deliberately kept all four cases -- so the row's contents and the mapper's
    //   coverage are two separate claims that both have to hold.
    let arrows: [MobileAccessoryKey] = [.up, .down, .left, .right]
    for arrow in arrows {
        #expect(MobileAccessoryKey.barRow.contains(arrow) == false)
        var mapper = MobileInputMapper()
        #expect(mapper.accessory(arrow) != nil)
    }
    // Everything that is not an arrow still reaches the row exactly once.
    let expected = MobileAccessoryKey.allCases.filter { arrows.contains($0) == false }
    #expect(MobileAccessoryKey.barRow == expected)
}
