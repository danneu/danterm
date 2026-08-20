// Everything that can move the phone's session, in the two vocabularies the model answers
// on.
//
// The split is the claim contract in the type system: an ordinary event reaches an entry
// point whose effect type has no resize case, so no ordinary branch can send one whatever
// it constructs. Only the geometry event reaches the entry point that can, and its inputs
// are the two deliberate gestures plus the surface report -- which resizes only while a
// standing claim created by a gesture exists.
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
    /// The user asked the Mac to create a pane in the attached pane's tab.
    case newPaneRequested
    case appForegrounded
    case appBackgrounded
    case networkPathChanged(usable: Bool)
    /// The retry deadline the model armed has arrived.
    case retryTimerFired
    /// The checkpoint deadline the model armed has arrived.
    case checkpointTimerFired
    /// An attempt reached a handshaken session and the roster its subscribe replied with.
    case attemptSucceeded(roster: PaneRoster, serverVersion: String)
    /// The surface holds the chosen pane and resumes from this cursor, or from nothing.
    case paneAttached(pane: PaneId, cursor: PaneTapeCursor?)
    /// The attempt, or the connection it established, ended with this typed cause.
    case connectionEnded(MobileConnectionFailure)
    /// One frame arrived on the serving connection.
    case frameReceived(DanTermClientFrame)
    /// The surface took this record. Its own end record is what ends the connection.
    case recordApplied(MobilePaneTapeRecord)
    /// The replica refused a record, which is a defect on this phone rather than a cause
    /// any server can change.
    case replicaRejectedRecord
    case replicaStateChanged(PaneReplicaState)
    /// The replica reached a newer exact position worth saving.
    case replicaAdvanced
    case textEntered(String)
    /// The keyboard's backspace, which the terminal's input responder is the first thing
    /// on this phone able to report.
    case deleteBackwardPressed
    case pasted(String)
    case accessoryKeyPressed(MobileAccessoryKey)
    case hardwareKeyPressed(NamedKey, KeyMods)
    case hardwareCharacterPressed(Character, KeyMods)
    /// The scroll chrome put this absolute row at the top of the window, which it can
    /// only mean while it is projecting the whole stream.
    ///
    /// The two scroll events are spelled as two names rather than as one overloaded
    /// `scrolled`, because Swift resolves an overloaded case pattern by base name and
    /// would send both gestures down whichever branch it matched first.
    case scrolledToTopRow(Int)
    /// The scroll chrome travelled this many whole rows -- negative toward history -- with
    /// the gesture sitting on this grid cell, so a mouse report has a real position.
    case scrolledByRows(Int, column: Int, row: Int)
}

/// The inputs that may change the grid the pane runs at: the two deliberate gestures, and
/// the surface report that renews a standing claim a gesture created.
///
/// They are their own event type because they are the only ones allowed to produce a
/// resize: the entry point they reach is the only one whose effect type can carry one.
public enum MobileSessionGeometryEvent: Equatable, Sendable {
    case claimRequested
    case releaseRequested
    /// The surface's current facts. It resizes nothing on its own: while a standing claim
    /// exists, a report offering a different grid renews the claim at that grid.
    case surfaceChanged(MobileSurfaceFacts)
}
