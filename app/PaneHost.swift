// Runtime-owned lifetime root for one pane: its terminal session, its persistent pane
// chrome, and every other resource created and destroyed with the pane.
// What does NOT belong here: state keyed by the pane *id* rather than by this record.
// A discarded staged restore can carry the same pane id as a live pane, so anything
// resolved by id -- pane-tape follow streams -- stays in PaneTapeBroker and is retired
// only when a live pane goes away.
import Cocoa

/// The runtime's whole record of one pane. It is produced whole by session creation and
/// destroyed whole by `tearDown`, so a resource added here is released on every path a
/// pane can leave by, without a second edit somewhere else.
@MainActor
final class PaneHost {
    let session: any TerminalSession
    let wrapper: PaneWrapperView
    /// Last visibility pushed to the session, `nil` until the first push. A pane installed
    /// under a reused pane id starts at `nil`, so it gets its own push instead of having it
    /// suppressed by what its predecessor was told.
    var pushedVisibility: Bool?
    /// Debounces this pane's short search needles. Unarmed until the pane gets one, and
    /// armed with the timer that will deliver it, so the pending delivery and its census
    /// entry cannot come apart.
    let searchDebounce: AppRuntimeScheduledOwner<DispatchSourceTimer>
    /// Scrollback replay file written for a restored pane and read once by its shell.
    private var replayFile: URL?
    /// Retires the session's `onEvent` and `onPrimaryHistoryMutation` callbacks. Armed
    /// when the session is built, which is before the record exists, so it is handed in.
    private let sessionSubscriptionToken: AppRuntimeSchedulingToken?

    init(
        paneId: PaneId,
        session: any TerminalSession,
        runtime: AppRuntime,
        subscriptionToken: AppRuntimeSchedulingToken? = nil,
        replayFile: URL? = nil
    ) {
        self.session = session
        self.sessionSubscriptionToken = subscriptionToken
        self.replayFile = replayFile
        self.searchDebounce = AppRuntimeScheduledOwner(
            timerIn: runtime.schedulingLifecycle,
            category: .debouncer
        )
        self.wrapper = PaneWrapperView(
            paneId: paneId,
            terminalView: session,
            runtime: runtime
        )
    }

    /// Deletes the pane's replay file and forgets it. Idempotent, because app termination
    /// sweeps the files without tearing the panes down.
    func removeReplayFile() {
        guard let replayFile else { return }
        self.replayFile = nil
        try? FileManager.default.removeItem(at: replayFile)
    }

    /// Destroys everything the record owns. Correct for a staged record as much as a live
    /// one: nothing here reaches state that another pane could be sharing.
    func tearDown(scheduling: AppRuntimeSchedulingLifecycle) {
        searchDebounce.cancel()
        scheduling.cancel(sessionSubscriptionToken)
        removeReplayFile()
        session.tearDown()
    }
}
