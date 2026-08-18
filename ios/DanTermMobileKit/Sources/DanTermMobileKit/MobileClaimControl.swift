// Projects the phone's geometry control from the facts that decide it, so the shell
// renders a control rather than remembering one.
//
// What does not belong here: any stored claim state, any comparison of the replica's
// grid against the phone's own (a coincidental match is not a claim), and any notion
// of who pinned the pane -- Release is offered whoever set the override.
import DanTermProtocol

/// Holds the exact requests the two geometry actions would send, so "offered" and
/// "sendable" cannot come apart: an action with no request is an action the phone must
/// not show.
///
/// It is a value computed on demand from four facts, never a stored control state. That
/// is what keeps it honest when the Mac takes a pane back or a third client resizes it:
/// the next stream event moves the facts and the control follows.
public struct MobileClaimControl: Equatable, Sendable {
    /// The resize a claim would send, carrying the grid this phone draws at.
    public let claim: IpcRequest?
    /// The resize a release would send: the fit form, which returns the pane to the
    /// grid its slot implies. It needs no grid of its own, so a surface too small to
    /// show a whole cell still keeps this exit.
    public let release: IpcRequest?

    /// Projects the control from connection state, the selected pane, the replica's
    /// pinnedness (none while the replica is not exact), and the phone's native grid.
    public init(
        connection: MobileConnectionState,
        pane: PaneId?,
        pinned: Bool?,
        nativeGrid: MobileSurfaceGrid?
    ) {
        // `ready` is the one state with a stream serving requests; every other state
        // names a connection that is starting, gone, or ending.
        guard connection == .ready, let pane else {
            claim = nil
            release = nil
            return
        }
        claim = nativeGrid?.claimRequest(for: pane)
        release = pinned == true ? .paneResize(pane: pane, resize: .fit) : nil
    }
}
