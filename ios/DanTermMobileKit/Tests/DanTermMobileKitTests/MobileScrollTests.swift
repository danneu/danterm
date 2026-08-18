// Behavioral tests for the phone's scroll arithmetic and its scroll-chrome driver.
import CoreGraphics
import DanTermMobileKit
import Testing
import TerminalCore

@Test("A projection and a scroll offset describe the same position in both directions")
func scrollGeometryRoundTripsBetweenRowsAndOffsets() throws {
    // Intent: content height, offset, and the row an offset names are one consistent
    // top-origin space, and a rubber-band bounce past either end still names a real row.
    // Why it exists: the engine is the only scroll authority, so a conversion that drifts
    // would let the chrome ask for a row the user is not looking at.
    // Scenario: a 40-row window browsing a 500-row stream at 10 points per row.
    let geometry = try #require(MobileScrollGeometry(
        projection: TerminalScrollProjection(
            totalRows: 500,
            topRow: 100,
            windowRows: 40,
            isFollowing: false
        ),
        rowHeight: 10
    ))
    #expect(geometry.contentHeight == 5000)
    #expect(geometry.viewportHeight == 400)
    #expect(geometry.contentOffset == 1000)
    #expect(geometry.maximumTopRow == 460)
    #expect(geometry.topRow(forOffset: geometry.contentOffset) == 100)
    #expect(geometry.topRow(forOffset: geometry.contentHeight - geometry.viewportHeight) == 460)
    // Both bounces: past the top and past the bottom of the content.
    #expect(geometry.topRow(forOffset: -240) == 0)
    #expect(geometry.topRow(forOffset: 6000) == 460)
}

@Test("A following projection sits at the very bottom of its content")
func scrollGeometryFollowingIsPinnedToTheBottom() throws {
    let geometry = try #require(MobileScrollGeometry(
        projection: TerminalScrollProjection(
            totalRows: 500,
            topRow: 460,
            windowRows: 40,
            isFollowing: true
        ),
        rowHeight: 10
    ))
    #expect(geometry.contentOffset == geometry.contentHeight - geometry.viewportHeight)
}

@Test("The scrollable viewport is the drawn grid, not the view it is drawn in")
func scrollGeometryViewportIsTheDrawnGrid() throws {
    // Intent: the maximum offset reaches the engine's maximum top row even when the
    // fitted grid is shorter than the terminal view that holds it.
    // Why it exists: the fitted grid is bottom-pinned and routinely leaves a strip of the
    // view empty. Sizing the viewport from the view's height instead would put the
    // maximum offset short of the last row, so the indicator could never reach the bottom
    // and idle reflection could never converge.
    // Scenario: a 24-row window of 12-point rows -- 288 points of grid -- inside a view
    // 800 points tall.
    let viewHeight: CGFloat = 800
    let geometry = try #require(MobileScrollGeometry(
        projection: TerminalScrollProjection(
            totalRows: 1000,
            topRow: 0,
            windowRows: 24,
            isFollowing: false
        ),
        rowHeight: 12
    ))
    #expect(geometry.viewportHeight == 288)
    #expect(geometry.viewportHeight < viewHeight)
    #expect(geometry.maximumTopRow == 976)
    #expect(
        geometry.topRow(forOffset: geometry.contentHeight - geometry.viewportHeight)
            == geometry.maximumTopRow
    )
}

@Test("A row with no height describes no geometry")
func scrollGeometryNeedsARowHeight() {
    let projection = TerminalScrollProjection(
        totalRows: 100,
        topRow: 0,
        windowRows: 24,
        isFollowing: false
    )
    #expect(MobileScrollGeometry(projection: projection, rowHeight: 0) == nil)
    #expect(MobileScrollGeometry(projection: projection, rowHeight: .nan) == nil)
}

@Test("The scroll mode and its indicator follow the replicated screen state")
func scrollModeFollowsReplicatedState() {
    // Intent: the alternate screen scrolls by deltas, a stream that already fits the
    // window scrolls not at all, and only a real scrollback shows an indicator.
    // Why it exists: the engine reports a degenerate projection on the alternate screen,
    // so the screen bit -- not the projection -- has to pick delta mode; and an indicator
    // over a window with nothing behind it states an extent that does not exist.
    let scrollback = TerminalScrollProjection(
        totalRows: 500,
        topRow: 100,
        windowRows: 40,
        isFollowing: false
    )
    let fits = TerminalScrollProjection(
        totalRows: 24,
        topRow: 0,
        windowRows: 24,
        isFollowing: true
    )

    let projected = MobileScrollMode.select(
        projection: scrollback,
        rowHeight: 10,
        isAlternateScreenActive: false
    )
    #expect(projected.kind == .projected)
    #expect(projected.showsIndicator)

    let alternate = MobileScrollMode.select(
        projection: fits,
        rowHeight: 10,
        isAlternateScreenActive: true
    )
    #expect(alternate.kind == .delta)
    #expect(alternate.showsIndicator == false)

    let degenerate = MobileScrollMode.select(
        projection: fits,
        rowHeight: 10,
        isAlternateScreenActive: false
    )
    #expect(degenerate.kind == .inert)
    #expect(degenerate.showsIndicator == false)

    // No replica to read, and no drawn row to measure: both are inert.
    #expect(MobileScrollMode.select(
        projection: nil,
        rowHeight: 10,
        isAlternateScreenActive: false
    ).kind == .inert)
    #expect(MobileScrollMode.select(
        projection: scrollback,
        rowHeight: 0,
        isAlternateScreenActive: true
    ).kind == .inert)
}

@Test("An offset stream that crosses one row boundary names one row")
func scrollDriverDeduplicatesRowsWithinAGesture() {
    // Intent: motion inside a single row produces nothing, and crossing into the next one
    // produces exactly one absolute row.
    // Why it exists: a scroll view reports its offset on every frame of a flick, and one
    // session event per frame would flood the model with the row it is already showing.
    var driver = MobileScrollDriver()
    _ = driver.replicaChanged(
        projection: TerminalScrollProjection(
            totalRows: 500,
            topRow: 100,
            windowRows: 40,
            isFollowing: false
        ),
        rowHeight: 10,
        isAlternateScreenActive: false
    )
    #expect(driver.interactionChanged(.dragging).isEmpty)

    var named: [Int] = []
    for offset in stride(from: CGFloat(1000), through: 1010, by: 2) {
        for action in driver.offsetChanged(offset) {
            if case .scrollToTopRow(let row) = action { named.append(row) }
        }
    }
    #expect(named == [101])
}

@Test("Nothing programmatic moves the scroll view while the user is interacting")
func scrollDriverLatchesReflectionDuringInteraction() {
    // Intent: replica changes arriving during tracking, dragging, or deceleration produce
    // no reflection, and the return to idle produces exactly one.
    // Why it exists: output arrives continuously, and reflecting it mid-flick would drag
    // the content out from under the finger.
    for held: MobileScrollInteraction in [.tracking, .dragging, .decelerating] {
        var driver = MobileScrollDriver()
        _ = driver.replicaChanged(
            projection: TerminalScrollProjection(
                totalRows: 500,
                topRow: 460,
                windowRows: 40,
                isFollowing: true
            ),
            rowHeight: 10,
            isAlternateScreenActive: false
        )
        #expect(driver.interactionChanged(held).isEmpty)

        for total in [520, 540, 560] {
            let actions = driver.replicaChanged(
                projection: TerminalScrollProjection(
                    totalRows: total,
                    topRow: total - 40,
                    windowRows: 40,
                    isFollowing: true
                ),
                rowHeight: 10,
                isAlternateScreenActive: false
            )
            #expect(actions.isEmpty)
        }

        #expect(driver.interactionChanged([]) == [
            .reflect(contentHeight: 5600, offset: 5200, showsIndicator: true),
        ])
    }
}

@Test("An idle replica change reflects the engine into the chrome")
func scrollDriverReflectsWhenIdle() {
    var driver = MobileScrollDriver()
    let actions = driver.replicaChanged(
        projection: TerminalScrollProjection(
            totalRows: 500,
            topRow: 100,
            windowRows: 40,
            isFollowing: false
        ),
        rowHeight: 10,
        isAlternateScreenActive: false
    )
    #expect(actions == [.reflect(contentHeight: 5000, offset: 1000, showsIndicator: true)])
    // The offset the shell installs comes straight back as a callback, and it is not
    // gesture motion.
    #expect(driver.offsetChanged(1000).isEmpty)
}

@Test("Delta mode turns fractional point motion into whole rows without losing any")
func scrollDeltaAccumulatesFractionsIntoWholeRows() {
    // Intent: whole rows are emitted as they are earned, in both directions, and the
    // fraction left over is carried into the next callback rather than dropped.
    var delta = MobileScrollDelta()
    #expect(delta.rows(atOffset: 25, rowHeight: 10) == 2)
    #expect(delta.rows(atOffset: 25, rowHeight: 10) == 0)
    // The five points left over plus five more are the third row.
    #expect(delta.rows(atOffset: 30, rowHeight: 10) == 1)

    var backward = MobileScrollDelta()
    #expect(backward.rows(atOffset: -25, rowHeight: 10) == -2)
    #expect(backward.rows(atOffset: -30, rowHeight: 10) == -1)
}

@Test("A delta baseline reset emits nothing and preserves the pending fraction")
func scrollDeltaRecenterIsInvisibleToTheRowCount() {
    // Intent: motion that crosses a recenter maps to the same total rows it would have
    // mapped to without one.
    // Why it exists: the reset is bookkeeping, not a gesture. Counting it as motion would
    // fling the terminal by the recentering distance.
    var recentered = MobileScrollDelta(baseline: 100)
    var total = recentered.rows(atOffset: 125, rowHeight: 10)
    recentered.recenter(from: 125, to: 500)
    total += recentered.rows(atOffset: 510, rowHeight: 10)

    var straight = MobileScrollDelta(baseline: 100)
    #expect(straight.rows(atOffset: 135, rowHeight: 10) == total)
}

@Test("A delta-mode gesture emits rows and recenters itself without double counting")
func scrollDriverRecentersDeltaModeMidGesture() {
    // Intent: the baseline reset lands mid-gesture, emits no motion of its own, and the
    // fraction pending when it lands still counts toward the next row.
    // Why it exists: the reset is what makes an endless flick possible on a screen with no
    // extent to project. Counting it as motion would fling the terminal by the recentering
    // distance; dropping the fraction would lose part of the user's swipe.
    // Scenario: both halves of a flick -- the finger down, and the momentum after it lifts.
    for held: MobileScrollInteraction in [.dragging, .decelerating] {
        var driver = MobileScrollDriver()
        #expect(driver.replicaChanged(
            projection: nil,
            rowHeight: 10,
            isAlternateScreenActive: true
        ) == [.reflect(contentHeight: 100_000, offset: 50_000, showsIndicator: false)])
        #expect(driver.interactionChanged(held).isEmpty)
        #expect(driver.offsetChanged(50_000).isEmpty)

        #expect(driver.offsetChanged(70_001) == [
            .scrollByRows(2000),
            .recenter(offset: 50_000),
        ])
        // The shell installs the recentered offset; the one point still pending is not yet
        // a row, and nine more points finish it.
        #expect(driver.offsetChanged(50_000).isEmpty)
        #expect(driver.offsetChanged(50_009) == [.scrollByRows(1)])
    }
}

@Test("Motion routed under a screen mode the replica has left goes inert")
func scrollDriverDropsMotionAfterAMidGestureModeFlip() {
    // Intent: once the replica leaves the screen the gesture was routed under, the rest of
    // that gesture produces nothing, and the return to idle still reconciles the chrome.
    // Why it exists: a full-screen application appearing mid-flick would otherwise be sent
    // the leftover momentum as arrow keys.
    var driver = MobileScrollDriver()
    _ = driver.replicaChanged(projection: nil, rowHeight: 10, isAlternateScreenActive: true)
    #expect(driver.interactionChanged(.decelerating).isEmpty)

    let browsing = TerminalScrollProjection(
        totalRows: 500,
        topRow: 100,
        windowRows: 40,
        isFollowing: false
    )
    #expect(driver.replicaChanged(
        projection: browsing,
        rowHeight: 10,
        isAlternateScreenActive: false
    ).isEmpty)
    #expect(driver.offsetChanged(60_000).isEmpty)
    #expect(driver.offsetChanged(0).isEmpty)

    #expect(driver.interactionChanged([]) == [
        .reflect(contentHeight: 5000, offset: 1000, showsIndicator: true),
    ])
}

@Test("An inert mode scrolls nothing whatever the offset does")
func scrollDriverInertModeEmitsNoMotion() {
    var driver = MobileScrollDriver()
    #expect(driver.replicaChanged(
        projection: TerminalScrollProjection(
            totalRows: 24,
            topRow: 0,
            windowRows: 24,
            isFollowing: true
        ),
        rowHeight: 10,
        isAlternateScreenActive: false
    ) == [.reflect(contentHeight: 0, offset: 0, showsIndicator: false)])
    #expect(driver.interactionChanged(.dragging).isEmpty)
    #expect(driver.offsetChanged(-120).isEmpty)
}
