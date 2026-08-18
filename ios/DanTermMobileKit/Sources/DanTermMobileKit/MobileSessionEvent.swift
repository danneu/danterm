// Everything that can move the phone's session, in the two vocabularies the model answers
// on.
//
// The split is the claim contract in the type system: an ordinary event reaches an entry
// point whose effect type has no resize case, so no ordinary branch can send one whatever
// it constructs. Only the geometry event reaches the entry point that can.
//
// What does not belong here: anything a view decides for itself (raising a keyboard,
// dismissing one, a scroll position inside a sheet). An event is a fact about the session,
// never a request to redraw.
import DanTermClient
import DanTermProtocol
import Foundation

/// The two ambient readings the model is not allowed to take for itself: the moment an
/// event is handled at, and the identity a new request is sent under.
///
/// They are injected rather than read at the leaf so a test states both and every decision
/// the model makes from them is reproducible.
public struct MobileSessionEnv: Sendable {
    public let now: TimeInterval
    public let newRequestId: @Sendable () -> JSONValue

    public init(now: TimeInterval, newRequestId: @Sendable @escaping () -> JSONValue) {
        self.now = now
        self.newRequestId = newRequestId
    }
}

/// What the terminal surface currently is, as the model's own stored fact.
///
/// The surface is a view, so it is the one place these three can be measured; pushing them
/// in as an event is what keeps the model -- not the shell -- the owner of the claim
/// control and of where a scroll goes.
public struct MobileSurfaceFacts: Equatable, Sendable {
    /// The grid the surface draws at native cell metrics, or nothing when no whole cell fits.
    public let nativeGrid: MobileSurfaceGrid?
    /// Whether the replicated pane runs on an override, or nothing while the replica is
    /// not exact.
    public let pinned: Bool?
    /// Whether the replicated pane is on its alternate screen, which decides whether a
    /// scroll moves the local viewport or is sent to the owner.
    public let isAlternateScreenActive: Bool

    public init(
        nativeGrid: MobileSurfaceGrid? = nil,
        pinned: Bool? = nil,
        isAlternateScreenActive: Bool = false
    ) {
        self.nativeGrid = nativeGrid
        self.pinned = pinned
        self.isAlternateScreenActive = isAlternateScreenActive
    }
}

/// Every ordinary input to the session: the user's, the app's lifecycle, the phone's
/// network, the shell's instruments, and the connection itself.
public enum MobileSessionEvent: Equatable, Sendable {
    /// The app started, with the target facts it found outside itself.
    case launched(MobileLaunchInputs)
    /// The user asked to connect to the server the fields name.
    case connectRequested(MobileTargetDraft)
    /// The user chose a pane to read.
    case paneSelected(PaneId)
    case appForegrounded
    case appBackgrounded
    case networkPathChanged(usable: Bool)
    /// The retry deadline the model armed has arrived.
    case retryTimerFired
    /// The checkpoint deadline the model armed has arrived.
    case checkpointTimerFired
    /// An attempt reached a handshaken session and its first pane list.
    case attemptSucceeded(panes: [MobilePaneListItem], serverVersion: String)
    /// The surface holds the chosen pane and resumes from this cursor, or from nothing.
    case paneAttached(pane: PaneId, cursor: PaneTapeCursor?)
    /// The attempt, or the connection it established, ended with this typed cause.
    case connectionEnded(MobileConnectionFailure)
    /// One frame arrived on the serving connection.
    case frameReceived(DanTermClientFrame)
    /// The surface took this record. Its own end record is what ends the connection.
    case recordApplied(PaneTapeRecord)
    /// The replica refused a record, which is a defect on this phone rather than a cause
    /// any server can change.
    case replicaRejectedRecord
    case replicaStateChanged(PaneReplicaState)
    /// The replica reached a newer exact position worth saving.
    case replicaAdvanced
    case surfaceChanged(MobileSurfaceFacts)
    case textEntered(String)
    /// The keyboard's backspace, which the terminal's input responder is the first thing
    /// on this phone able to report.
    case deleteBackwardPressed
    case pasted(String)
    case accessoryKeyPressed(MobileAccessoryKey)
    case hardwareKeyPressed(NamedKey, KeyMods)
    case hardwareCharacterPressed(Character, KeyMods)
    case scrolled(InputWheelDirection)
}

/// The two gestures that may change the grid the pane runs at.
///
/// They are their own event type because they are the only ones allowed to produce a
/// resize: the entry point they reach is the only one whose effect type can carry one.
public enum MobileSessionGeometryEvent: Equatable, Sendable {
    case claimRequested
    case releaseRequested
}
