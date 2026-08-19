// Behavioral tests for where the drawn cells sit while the keyboard obscures the view.
import CoreGraphics
import DanTermMobileKit
import Testing

@Test("The obscured height moves the drawn rectangle without touching its extent")
func placementSlidesTheDrawnRectangleOnly() throws {
    // Intent: varying the obscured height against a fixed content box changes only where
    // the drawn rectangle sits; its width and height stay what the surface allocated.
    // Why it exists: the keyboard must never rescale content or reallocate frame stores;
    // if the rectangle's extent followed the obscured height, it would.
    // Scenario: a phone keyboard rising 300 points under a grid the view draws natively.
    let box = try makeBox()
    let surface = try #require(MobileObserveSurface(
        columns: 20,
        rows: 10,
        contentBox: box,
        fontSize: 11
    ))
    let rest = MobileSurfacePlacement(contentBox: box, obscuredHeight: 0)
    let raised = MobileSurfacePlacement(contentBox: box, obscuredHeight: 300)
    let restFrame = surface.drawnFrame(in: rest)
    let raisedFrame = surface.drawnFrame(in: raised)
    #expect(raisedFrame.size == restFrame.size)
    #expect(raisedFrame.minX == restFrame.minX)
    #expect(raisedFrame.maxY == restFrame.maxY - 300)
}

@Test("The visible bottom edge sits on a whole backing pixel")
func placementQuantizesTheBottomEdge() throws {
    // Intent: whatever fraction the measured rise carries, the drawn content's bottom
    // edge lands on a whole backing pixel.
    // Why it exists: the content's bottom must meet the bar's top exactly; a fractional
    // edge would blur the bottom row or leak a pixel line.
    let box = try makeBox()
    let placement = MobileSurfacePlacement(contentBox: box, obscuredHeight: 100.1)
    let bottomPixels = placement.maxY * box.displayScale
    #expect(bottomPixels == bottomPixels.rounded())
    #expect(abs(placement.maxY - (box.maxY - 100.1)) < 1 / box.displayScale)
}

@Test("A bar below its rest position obscures nothing")
func placementClampsNegativeMeasurementsToZero() throws {
    // Intent: a negative measured rise behaves exactly like zero.
    // Why it exists: iPad undocked keyboards can put the bar below the rest position the
    // measurement assumes; content must never be pushed down out of the clip.
    let box = try makeBox()
    let rest = MobileSurfacePlacement(contentBox: box, obscuredHeight: 0)
    #expect(MobileSurfacePlacement(contentBox: box, obscuredHeight: -50) == rest)
    #expect(MobileSurfacePlacement(contentBox: box, obscuredHeight: .nan) == rest)
    #expect(MobileSurfacePlacement(contentBox: box, obscuredHeight: .infinity) == rest)
}

@Test("A point over a visible row resolves to that row at any obscured height")
func placementMovesTheCellMappingWithTheDrawnRectangle() throws {
    // Intent: gesture-to-cell mapping follows the same offset as the drawn rectangle, so
    // a touch on a visible row names that row while the keyboard is up.
    // Why it exists: the drawn layer, the scroll chrome, and hit testing must move
    // together; a mapping still reading the rest position would put every report a
    // keyboard's height of rows off.
    let box = try makeBox()
    let surface = try #require(MobileObserveSurface(
        columns: 20,
        rows: 10,
        contentBox: box,
        fontSize: 11
    ))
    let rest = MobileSurfacePlacement(contentBox: box, obscuredHeight: 0)
    let raised = MobileSurfacePlacement(contentBox: box, obscuredHeight: 300)
    let restFrame = surface.drawnFrame(in: rest)
    let cell = surface.cellSize(in: box)
    let restPoint = CGPoint(
        x: restFrame.minX + cell.width * 3.5,
        y: restFrame.minY + cell.height * 2.5
    )
    let raisedPoint = CGPoint(x: restPoint.x, y: restPoint.y - 300)
    let restCell = surface.cell(at: restPoint, in: rest)
    let raisedCell = surface.cell(at: raisedPoint, in: raised)
    #expect(restCell.column == 3)
    #expect(restCell.row == 2)
    #expect(raisedCell.column == restCell.column)
    #expect(raisedCell.row == restCell.row)
}

@Test("The lift is the minimum that keeps the cursor row visible")
func placementLiftsOnlyAsFarAsTheAnchorNeeds() throws {
    // Intent: with an anchor, the lift is clamp(obscured - slack, 0, obscured): a
    // bottom-row cursor keeps the full lift, a cursor with slack at least the obscured
    // height keeps the content put, and a mid-screen cursor lands its row's bottom edge
    // exactly on the visible floor, on a whole backing pixel.
    // Why it exists: a lift blind to the cursor slides a fresh prompt off the top of the
    // screen to protect empty rows at the bottom; the anchor keeps the prompt put while
    // a full screen of output keeps the full lift.
    let box = try makeBox()
    let surface = try #require(MobileObserveSurface(
        columns: 20,
        rows: 40,
        contentBox: box,
        fontSize: 11
    ))
    let obscuredHeight: CGFloat = 100
    let obscuredPixels = Int(obscuredHeight * box.displayScale)
    let full = MobileSurfacePlacement(contentBox: box, obscuredHeight: obscuredHeight)
    let rest = MobileSurfacePlacement(contentBox: box, obscuredHeight: 0)

    // A bottom-row cursor has no slack below it, so the anchor changes nothing.
    #expect(surface.slackPixels(belowRow: 39) == 0)
    let bottomAnchored = MobileSurfacePlacement(
        contentBox: box,
        obscuredHeight: obscuredHeight,
        anchorSlackPixels: 0
    )
    #expect(bottomAnchored == full)

    // A cursor with slack at least the obscured height leaves the content put.
    let topSlack = surface.slackPixels(belowRow: 0)
    #expect(topSlack >= obscuredPixels)
    let unlifted = MobileSurfacePlacement(
        contentBox: box,
        obscuredHeight: obscuredHeight,
        anchorSlackPixels: topSlack
    )
    #expect(unlifted.maxY == rest.maxY)

    // A mid-screen cursor puts its row's bottom edge exactly on the visible floor.
    let midSlack = surface.slackPixels(belowRow: 38)
    #expect(midSlack > 0)
    #expect(midSlack < obscuredPixels)
    let partial = MobileSurfacePlacement(
        contentBox: box,
        obscuredHeight: obscuredHeight,
        anchorSlackPixels: midSlack
    )
    let frame = surface.drawnFrame(in: partial)
    let cursorBottom = frame.maxY - CGFloat(midSlack) / box.displayScale
    #expect(cursorBottom == box.maxY - CGFloat(obscuredPixels) / box.displayScale)
    let bottomPixels = partial.maxY * box.displayScale
    #expect(bottomPixels == bottomPixels.rounded())

    // The clamp holds at both ends: a negative slack behaves like none, and no slack
    // can push the content below its rest position.
    #expect(MobileSurfacePlacement(
        contentBox: box,
        obscuredHeight: obscuredHeight,
        anchorSlackPixels: -100
    ) == full)
    #expect(MobileSurfacePlacement(
        contentBox: box,
        obscuredHeight: obscuredHeight,
        anchorSlackPixels: .max
    ).maxY == rest.maxY)
}

@Test("A point over a visible row resolves to that row at a partial lift")
func placementMovesTheCellMappingAtAPartialLift() throws {
    // Intent: at an anchor-limited partial lift, the drawn rectangle and gesture-to-cell
    // mapping move by the same amount, so a touch on a visible row names that row.
    // Why it exists: the drawn layer, the scroll chrome, and hit testing read one
    // placement; a partial lift must move all of them together just like the full one.
    let box = try makeBox()
    let surface = try #require(MobileObserveSurface(
        columns: 20,
        rows: 40,
        contentBox: box,
        fontSize: 11
    ))
    let rest = MobileSurfacePlacement(contentBox: box, obscuredHeight: 0)
    let partial = MobileSurfacePlacement(
        contentBox: box,
        obscuredHeight: 100,
        anchorSlackPixels: surface.slackPixels(belowRow: 38)
    )
    let lift = rest.maxY - partial.maxY
    #expect(lift > 0)
    #expect(lift < 100)
    let restFrame = surface.drawnFrame(in: rest)
    let partialFrame = surface.drawnFrame(in: partial)
    #expect(partialFrame.size == restFrame.size)
    #expect(partialFrame.maxY == restFrame.maxY - lift)
    let cell = surface.cellSize(in: box)
    let restPoint = CGPoint(
        x: restFrame.minX + cell.width * 3.5,
        y: restFrame.minY + cell.height * 2.5
    )
    let partialPoint = CGPoint(x: restPoint.x, y: restPoint.y - lift)
    let mapped = surface.cell(at: partialPoint, in: partial)
    #expect(mapped.column == 3)
    #expect(mapped.row == 2)
}

/// A phone-shaped content box; these tests are about the offset, not inset arithmetic.
private func makeBox() throws -> MobileContentBox {
    try #require(MobileContentBox(
        width: 393,
        height: 700,
        insetTop: 59,
        insetLeading: 0,
        insetTrailing: 0,
        insetBottom: 0,
        displayScale: 3
    ))
}
