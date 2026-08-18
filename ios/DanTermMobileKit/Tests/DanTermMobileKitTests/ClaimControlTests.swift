// The truth table for the phone's claim control: which of Claim and Release each
// combination of connection, pane, replica pinnedness, and surface grid offers.
import DanTermMobileKit
import DanTermProtocol
import Foundation
import Testing

@Test("A disconnected phone offers nothing")
func claimControlOffersNothingWhileDisconnected() {
    // Intent: neither action appears while no stream can carry a request.
    // Why it exists: a tappable control on a dead connection sends nothing and
    // reports nothing, so it can only lie about what the tap did.
    // Scenario: a pinned pane still selected from the connection that just ended.
    let control = MobileClaimControl(
        connection: .disconnected,
        pane: paneId(1),
        pinned: true,
        nativeGrid: grid()
    )
    #expect(control.claim == nil)
    #expect(control.release == nil)
}

@Test("A connecting phone offers nothing")
func claimControlOffersNothingWhileConnecting() {
    let control = MobileClaimControl(
        connection: .connecting,
        pane: paneId(1),
        pinned: nil,
        nativeGrid: grid()
    )
    #expect(control.claim == nil)
    #expect(control.release == nil)
}

@Test("A serving stream with no selected pane offers nothing")
func claimControlNeedsASelectedPane() {
    let control = MobileClaimControl(
        connection: .ready,
        pane: nil,
        pinned: true,
        nativeGrid: grid()
    )
    #expect(control.claim == nil)
    #expect(control.release == nil)
}

@Test("Unavailable pinnedness withholds Release and keeps Claim")
func claimControlWithholdsReleaseWithoutPinnedness() {
    // Intent: a claim is offered as soon as one can be sent, which does not wait on
    // the replica; Release waits, because it is the only one that needs pinnedness.
    // Why it exists: offering Release on an unknown bit would show an exit the pane
    // may not have, which is the class of lie this control exists to remove.
    // Scenario: the three states a replica reports no pinnedness in -- awaiting its
    // first synchronization, frozen behind a declared gap, and behind a detected one
    // (`PaneReplicaTests` pins that all three read as none).
    let control = MobileClaimControl(
        connection: .ready,
        pane: paneId(1),
        pinned: nil,
        nativeGrid: grid()
    )
    #expect(control.claim == .paneResize(pane: paneId(1), resize: .grid(columns: 80, rows: 24)))
    #expect(control.release == nil)
}

@Test("A connected unpinned pane offers only Claim")
func claimControlOffersClaimWhenUnpinned() {
    let control = MobileClaimControl(
        connection: .ready,
        pane: paneId(1),
        pinned: false,
        nativeGrid: grid()
    )
    #expect(control.claim == .paneResize(pane: paneId(1), resize: .grid(columns: 80, rows: 24)))
    #expect(control.release == nil)
}

@Test("A connected pinned pane offers Release beside Claim")
func claimControlOffersReleaseWhenPinned() {
    // Intent: Release is the phone's one-gesture exit from a pinned pane, and it
    // carries the fit form rather than any grid.
    // Why it exists: before this, a phone that claimed a pane had no exit at all --
    // only the Mac's take-back could unpin it.
    // Scenario: the replica is exact and reports the pane's grid as an override.
    let control = MobileClaimControl(
        connection: .ready,
        pane: paneId(1),
        pinned: true,
        nativeGrid: grid()
    )
    #expect(control.claim == .paneResize(pane: paneId(1), resize: .grid(columns: 80, rows: 24)))
    #expect(control.release == .paneResize(pane: paneId(1), resize: .fit))
}

@Test("A surface with no whole cell offers Release but no Claim")
func claimControlWithholdsClaimWithoutAWholeCell() {
    // Intent: Claim needs a grid to name, Release does not, so a surface too small to
    // show one cell loses exactly one of the two actions.
    // Why it exists: "nothing offered that cannot be sent" cuts both ways -- dropping
    // Release here would strip a working exit from a pinned pane.
    // Scenario: the terminal view has collapsed to no room for a whole cell.
    let control = MobileClaimControl(
        connection: .ready,
        pane: paneId(1),
        pinned: true,
        nativeGrid: nil
    )
    #expect(control.claim == nil)
    #expect(control.release == .paneResize(pane: paneId(1), resize: .fit))
}

private func grid() -> MobileSurfaceGrid {
    MobileSurfaceGrid(
        widthPixels: 800,
        heightPixels: 480,
        cellWidthPixels: 10,
        cellHeightPixels: 20
    )!
}

private func paneId(_ value: Int) -> PaneId {
    PaneId(rawValue: UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012d", value))!)
}
