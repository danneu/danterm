// The phone session's whole decision core: every connection, pane, status, and input fact
// the app holds, and the one function that moves them.
//
// The model is pure. It opens no socket, owns no timer, reads no clock, and touches no
// view: it consumes events and answers with effects the shell performs in order. Keeping
// the decisions here is what gives them tests at all -- the iOS app target is an
// executable with no test target, so anything decided in the shell is decided unproven.
//
// What does not belong here: how an attempt is performed (`MobileSessionAttempt`'s), how a
// deadline is delivered (`MobileDeadlineTimer`'s), where the checkpoint file lives
// (`PaneReplicaCheckpointStore`'s), and every UIKit choice -- colors, sheets, focus.
import DanTermClient
import DanTermProtocol
import Foundation
import TerminalCoreRecording

/// Everything a surface renders, recomputed from the model rather than remembered by a view.
public struct MobileSessionProjection: Equatable, Sendable {
    public let status: MobileStatusLine
    public let draft: MobileTargetDraft
    /// The problem with the target fields, shown beside them and nowhere else.
    public let draftProblem: MobileTargetDraftProblem?
    public let panes: [PaneRosterItem]
    public let selectedPaneId: PaneId?
    public let claim: MobileClaimControl
    /// Whether the one-shot Ctrl latch is armed; the bar's Ctrl key renders it from here.
    public let isControlLatched: Bool
}

/// Holds the phone's session facts and answers every event from them.
///
/// It composes the existing policies rather than replacing them: the reconnect policy still
/// decides when an attempt runs, the resume policy still decides where it starts, the
/// connect target still decides which gesture may read the fields, and the status still
/// composes the line. This type owns the order those answers are applied in, which is the
/// part that had no home and lived in the view controller.
public struct MobileSessionModel: Equatable, Sendable {
    /// How long the phone lets an advanced replica sit before its position is written out.
    public static let checkpointInterval: TimeInterval = 30

    private var draft = MobileTargetDraft(host: nil, port: MobileLaunchPlan.defaultPort)
    private var draftProblem: MobileTargetDraftProblem?
    private var status = MobileStatus()
    private var panes: [PaneRosterItem] = []
    private var selectedPaneId: PaneId?
    private var surface = MobileSurfaceFacts()
    /// The target and pane the current episode is about, so an automatic retry cannot
    /// silently follow a half-typed host field.
    private var connectTarget = MobileConnectTarget()
    private var preferredPaneId: PaneId?
    private var reconnectPolicy = MobileReconnectPolicy()
    private var resumePolicy = MobileResumePolicy()
    private var inputMapper = MobileInputMapper()
    /// The id of the tape subscription, which is the one request whose refusal ends the
    /// connection: the subscription is what the connection is for.
    private var tapeRequestId: JSONValue?
    /// The version reported by the handshake, held until the stream it describes starts.
    private var serverVersion: String?
    /// Input a smoke run drives into the first pane once the stream is serving.
    private var pendingSmokeInput: String?
    private var checkpointIsDirty = false
    private var checkpointDeadlineIsArmed = false
    /// The claim this phone made and still holds. In-memory only: it ends with the
    /// connection and is never persisted, so a reconnect starts with no claim.
    private var standingClaim: StandingClaim?

    /// The grid this phone last requested for the pane, and whether the server has
    /// confirmed it yet.
    ///
    /// Confirmation comes only from the success response to this phone's own latest claim
    /// or renewal request -- the request id below -- never from replica state or a tape
    /// record: a resize naming the grid the pane already runs at is a server-side no-op
    /// that emits no tape transition, so the response is the only confirmation that exists
    /// in every case. Once confirmed, a tape record stating the pane unpinned is an
    /// external release and ends the claim; before confirmation such a record is pre-claim
    /// truth and does not.
    private struct StandingClaim: Equatable, Sendable {
        var grid: MobileSurfaceGrid
        /// The unanswered claim or renewal request, or nil once its success response
        /// arrived. A renewal replaces it, which resets confirmation until its own
        /// response.
        var pendingRequestId: JSONValue?
    }

    /// Creates the session of an app that has not launched yet.
    public init() {}

    /// Everything the surfaces render, composed at the moment of display: a scheduled retry
    /// is worded as the time remaining, which only that moment can state.
    public func projection(at now: TimeInterval) -> MobileSessionProjection {
        var composed = status
        composed.noteRecovery(reconnectPolicy.recoveryPhase(at: now))
        return MobileSessionProjection(
            status: composed.line(at: now),
            draft: draft,
            draftProblem: draftProblem,
            panes: panes,
            selectedPaneId: selectedPaneId,
            claim: claimControl,
            isControlLatched: inputMapper.isControlLatched
        )
    }

    /// Advances the session by one ordinary event.
    ///
    /// The return type has no resize case, so nothing reachable from here can change the
    /// grid the pane runs at.
    public mutating func handle(
        _ event: MobileSessionEvent,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        switch event {
        case .launched(let inputs):
            let plan = MobileLaunchPlan(inputs: inputs)
            pendingSmokeInput = inputs.smokeInput.flatMap { $0.isEmpty ? nil : $0 }
            draft = plan.draft
            guard plan.connectsImmediately else { return [.redraw] }
            return connect(to: plan.draft, env: env)

        case .connectRequested(let draft):
            return connect(to: draft, env: env)

        case .paneSelected(let pane):
            // The gesture names a pane inside the episode that produced the list, so it
            // never consults the fields: editing them cannot retarget or block it.
            switch connectTarget.reuseTarget() {
            case .connect:
                preferredPaneId = pane
                return reconnect(.userRequestedConnect, env: env)
            case .reportDraft(let problem):
                draftProblem = problem
                return [.redraw]
            case .ignore:
                return []
            }

        case .appForegrounded:
            return reconnect(.appForegrounded, env: env)

        case .appBackgrounded:
            // The teardown comes first, and the policy is told after it, so it learns that
            // this connection is one the app dropped itself and still owes on return.
            let teardown: [MobileSessionEffect] = [
                .flushCheckpoint(savingReplica: takeCheckpointDirt(), synchronously: true),
                .disconnect,
            ]
            endConnection()
            return teardown + reconnect(.appBackgrounded, env: env)

        case .networkPathChanged(let usable):
            return reconnect(.networkPathChanged(usable: usable), env: env)

        case .retryTimerFired:
            return reconnect(.clockFired, env: env)

        case .checkpointTimerFired:
            checkpointDeadlineIsArmed = false
            return [.flushCheckpoint(savingReplica: takeCheckpointDirt(), synchronously: false)]

        case .attemptSucceeded(let roster, let serverVersion):
            panes = roster.panes
            guard let pane = preferredPaneId
                .flatMap({ wanted in panes.first { $0.paneId == wanted } })
                ?? panes.first(where: { $0.isSelectedTab && $0.isFocused })
                ?? panes.first
            else {
                return end(with: .requestRefused(reason: "The Mac has no panes"), env: env)
            }
            selectedPaneId = pane.paneId
            self.serverVersion = serverVersion
            return [
                .attachPane(
                    pane: pane.paneId,
                    resumesFromStoredCheckpoint: resumePolicy.trustsStoredPosition
                ),
                .redraw,
            ]

        case .paneAttached(let pane, let cursor):
            let requestId = env.newRequestId()
            tapeRequestId = requestId
            var effects: [MobileSessionEffect] = [.beginStream(
                requestId: requestId,
                request: .paneTape(
                    pane: pane,
                    start: cursor.map(PaneTapeStartPosition.cursor) ?? .now
                )
            )]
            if let smokeInput = pendingSmokeInput {
                pendingSmokeInput = nil
                // The probe is handed to the responder rather than sent from here, so the
                // run exercises the way the user's own typing reaches the pane.
                effects.append(.driveSmokeInput(MobileSmokeInputScript.steps(for: smokeInput)))
            }
            status.noteConnection(
                .ready,
                detail: serverVersion.map { "Connected to DanTerm \($0)" }
            )
            serverVersion = nil
            return effects + reconnect(.attemptConnected, env: env)

        case .connectionEnded(let failure):
            return end(with: failure, env: env)

        case .replicaRejectedRecord:
            return end(with: .deviceSetup, detail: "Replica rejected the stream", env: env)

        case .frameReceived(let frame):
            return receive(frame, env: env)

        case .recordApplied(let record):
            guard case .end(let reason) = record else { return [] }
            return end(with: .streamEnded(reason: reason?.rawValue), env: env)

        case .replicaStateChanged(let state):
            status.noteStream(state)
            switch state {
            // The producer never learns of a gap the replica found for itself, so it sends
            // no repair. Ending the connection is what puts the one recovery mechanism in
            // charge of it, and the next attempt starts away from the disputed position.
            case .gap(.detected):
                return end(with: .streamDesynchronized, env: env)
            case .exact:
                resumePolicy.replicaBecameExact()
                return [.redraw]
            case .gap(.declared), .awaitingSynchronization:
                return [.redraw]
            }

        case .replicaAdvanced:
            checkpointIsDirty = true
            guard checkpointDeadlineIsArmed == false else { return [] }
            checkpointDeadlineIsArmed = true
            return [.armCheckpointTimer(deadline: env.now + Self.checkpointInterval)]

        case .textEntered(let text):
            return mapKeyInput({ $0.text(text) }, env: env)

        case .deleteBackwardPressed:
            return mapKeyInput({ $0.deleteBackward() }, env: env)

        case .pasted(let text):
            return mapKeyInput({ $0.paste(text) }, env: env)

        case .accessoryKeyPressed(let key):
            // The Ctrl key produces no traffic and only moves the latch, which the row
            // renders, so this one input redraws whether or not it sends anything.
            let action = inputMapper.accessory(key)
            return send(action, env: env) + [.redraw]

        case .hardwareKeyPressed(let key, let modifiers):
            return mapKeyInput({ $0.hardwareKey(key, modifiers: modifiers) }, env: env)

        case .hardwareCharacterPressed(let character, let modifiers):
            return mapKeyInput({ $0.hardwareCharacter(character, modifiers: modifiers) }, env: env)

        case .scrolledToTopRow(let topRow):
            let action = inputMapper.scroll(
                toTopRow: topRow,
                alternateScreen: surface.isAlternateScreenActive
            )
            return send(action, env: env)

        case .scrolledByRows(let rows, let column, let row):
            let action = inputMapper.scroll(
                byRows: rows,
                column: column,
                row: row,
                alternateScreen: surface.isAlternateScreenActive
            )
            return send(action, env: env)
        }
    }

    /// Advances the session by one geometry event, the only entry point whose effects can
    /// carry a resize.
    ///
    /// A gesture's request is built here, from the facts the model holds at this moment, so
    /// a tap that arrives after the pane was unpinned or the connection dropped either sends
    /// the request those facts imply or sends nothing. A claim that sends its resize becomes
    /// the standing claim; a surface report offering a different grid while one is held
    /// renews it at the new grid, which is how a rotation re-claims without a gesture.
    public mutating func handle(
        _ event: MobileSessionGeometryEvent,
        env: MobileSessionEnv
    ) -> [MobileSessionGeometryEffect] {
        switch event {
        case .claimRequested:
            guard let request = claimControl.claim, let grid = surface.nativeGrid else {
                return []
            }
            let requestId = env.newRequestId()
            standingClaim = StandingClaim(grid: grid, pendingRequestId: requestId)
            return [.resizePane(requestId: requestId, request: request)]

        case .releaseRequested:
            // A tap the facts no longer offer a release for sends nothing and ends
            // nothing; only the gesture that sends the fit resize gives the claim up.
            guard let request = claimControl.release else { return [] }
            standingClaim = nil
            return [.resizePane(requestId: env.newRequestId(), request: request)]

        case .surfaceChanged(let facts):
            guard facts != surface else { return [] }
            surface = facts
            // A renewal fires only on this phone's own grid change while it holds the
            // claim, so no report about another client's pane can start one, and a
            // momentary nil grid neither renews nor ends anything.
            if standingClaim != nil,
               let grid = facts.nativeGrid,
               grid != standingClaim?.grid,
               let request = claimControl.claim {
                let requestId = env.newRequestId()
                standingClaim = StandingClaim(grid: grid, pendingRequestId: requestId)
                return [.resizePane(requestId: requestId, request: request)]
            }
            return [.session(.redraw)]
        }
    }

    /// The control the phone offers right now, computed from the facts and stored nowhere.
    private var claimControl: MobileClaimControl {
        MobileClaimControl(
            connection: status.connection,
            pane: selectedPaneId,
            pinned: surface.pinned,
            nativeGrid: surface.nativeGrid
        )
    }

    /// The gesture that names a server: the Go button, or the attempt made at launch.
    private mutating func connect(
        to draft: MobileTargetDraft,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        self.draft = draft
        switch connectTarget.setTarget(from: draft) {
        case .connect(let target):
            draftProblem = nil
            preferredPaneId = selectedPaneId
            return [.storeTarget(host: target.host, port: String(target.port))]
                + reconnect(.userRequestedConnect, env: env)
        case .reportDraft(let problem):
            // A field problem is reported beside its field and nowhere else. The policy is
            // left alone deliberately: a typo must not cancel a retry already owed to a
            // good target.
            draftProblem = problem
            return [.redraw]
        case .ignore:
            return []
        }
    }

    /// Feeds the reconnect policy one event and turns the single decision it returns into
    /// effects. The policy's own moment is handed over as it stands: no arithmetic here.
    private mutating func reconnect(
        _ event: MobileReconnectEvent,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        switch reconnectPolicy.handle(event, at: env.now) {
        case .attemptNow:
            return [.cancelRetryTimer] + startAttempt() + [.redraw]
        case .wait(let until):
            return [.armRetryTimer(deadline: until), .redraw]
        case .rest:
            return [.cancelRetryTimer, .redraw]
        }
    }

    /// Opens one attempt against the episode's target. The policy only says `attemptNow`
    /// inside an episode a gesture started, and a gesture only starts one against a target
    /// it resolved.
    private mutating func startAttempt() -> [MobileSessionEffect] {
        guard let target = connectTarget.established else { return [] }
        let teardown: [MobileSessionEffect] = [
            .flushCheckpoint(savingReplica: takeCheckpointDirt(), synchronously: true),
            .disconnect,
        ]
        endConnection()
        status.noteConnection(.connecting, detail: "Connecting to \(target.host):\(target.port)")
        return teardown + [.connect(target)]
    }

    /// Ends the current connection on one typed cause and lets the policy decide what
    /// follows it.
    ///
    /// The teardown comes first and is what makes the cause unique: it fences the runner,
    /// so a stream that ended and then reported its read error cannot hand the policy a
    /// second, differently classified cause for the same connection.
    private mutating func end(
        with failure: MobileConnectionFailure,
        detail: String? = nil,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        endConnection()
        status.noteConnection(failure.state, detail: detail)
        resumePolicy.connectionEnded(with: failure)
        return [.disconnect] + reconnect(.attemptFailed(failure), env: env)
    }

    /// Drops what described the connection that is going away. The stream condition and the
    /// last request outcome both belong to it, so they go with it rather than being shown
    /// beside the next one.
    private mutating func endConnection() {
        status.noteStream(nil)
        status.noteRequestOutcome(nil)
        tapeRequestId = nil
        serverVersion = nil
        standingClaim = nil
    }

    /// Reports whether a checkpoint write has anything to save, and clears the dirt in the
    /// same step so one flush cannot be counted twice.
    private mutating func takeCheckpointDirt() -> Bool {
        defer { checkpointIsDirty = false; checkpointDeadlineIsArmed = false }
        return checkpointIsDirty
    }

    private mutating func receive(
        _ frame: DanTermClientFrame,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        switch frame {
        case .response(let response):
            if let error = response.error {
                // `pending` is unwrapped first so a confirmed claim (pending nil) can
                // never match a response that carries no id.
                if let pending = standingClaim?.pendingRequestId, pending == response.id {
                    standingClaim = nil
                }
                // Only the tape subscription's refusal ends the connection. A refused input
                // request is the newest outcome on a stream that is still serving, and the
                // next completed request replaces it.
                guard response.id == tapeRequestId else {
                    status.noteRequestOutcome(.refused(reason: error.message))
                    return [.redraw]
                }
                return end(with: .requestRefused(reason: error.message), env: env)
            }
            if let pending = standingClaim?.pendingRequestId, pending == response.id {
                standingClaim?.pendingRequestId = nil
            }
            guard response.id == tapeRequestId else {
                status.noteRequestOutcome(.succeeded)
                return [.redraw]
            }
            guard let value = response.result, let record = decodePaneTapeRecord(value) else {
                return []
            }
            return take(record, env: env)
        case .notification(let method, let params):
            // A roster replaces the list and nothing else. The streamed pane leaving the
            // roster is not this notification's news to act on: the tape stream reports
            // its own pane's closure with an end record, which is what drives recovery.
            if let carried = PaneRosterNotification(method: method, params: params) {
                panes = carried.roster.panes
                return [.redraw]
            }
            guard let notification = PaneTapeEventNotification<JSONValue>(
                      method: method,
                      params: params
                  ),
                  let record = decodePaneTapeRecord(notification.record)
            else { return [] }
            return take(record, env: env)
        }
    }

    /// Lifts one decoded record's JSON event into the engine's own event type and hands the
    /// result on. This is the only place a tape event is parsed: past it the record carries
    /// the typed event, so no consumer can read the JSON a second time.
    ///
    /// An event this build cannot read ends the connection rather than being skipped. The
    /// phone would otherwise render across a recorder event it does not understand and go
    /// on claiming the replica is exact.
    private mutating func take(
        _ record: PaneTapeRecord<JSONValue>,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        guard let typed = try? record.mapEvent({ event in
            try JSONValueDecoder().decode(NeutralTerminalRecordingEvent.self, from: event)
        }) else {
            return end(with: .deviceSetup, detail: "Stream carried an unreadable event", env: env)
        }
        noteRecordPinnedness(typed)
        return [.applyRecord(typed)]
    }

    /// Ends a confirmed standing claim when the tape states the pane unpinned.
    ///
    /// This runs at the decode point because the frame stream is what orders records
    /// against responses: a record decoded after the latest claim or renewal's success
    /// response states post-claim truth (the server replies before it reconciles), while
    /// one decoded before it is pre-claim truth and ends nothing. Surface facts lawfully
    /// lag the response, so they never end a claim; no record confirms one either.
    private mutating func noteRecordPinnedness(_ record: MobilePaneTapeRecord) {
        guard let claim = standingClaim, claim.pendingRequestId == nil else { return }
        guard pinnedStatement(in: record) == false else { return }
        standingClaim = nil
    }

    /// The pinnedness one tape record states, or nil for a record that says nothing
    /// about it. Three kinds state it: the opening contract, a sync transfer's first
    /// part, and the recorder's resize event.
    private func pinnedStatement(in record: MobilePaneTapeRecord) -> Bool? {
        switch record {
        case .start(let start):
            return start.pinned
        case .sync(let sync):
            return sync.transfer?.pinned
        case .event(let event):
            // A pre-pinnedness recording omits the bit, and the event's own decode is where
            // that absence became "unpinned" -- it is not restated here.
            guard case .resize(_, _, let pinned) = event.event else { return nil }
            return pinned
        case .gap, .end, .unknown:
            return nil
        }
    }

    /// Runs one key-shaped input through the mapper and adds a redraw when it spent the
    /// one-shot Ctrl latch, so the bar's highlight follows the projection without a Ctrl
    /// tap of its own.
    private mutating func mapKeyInput(
        _ map: (inout MobileInputMapper) -> MobileInputAction?,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        let wasLatched = inputMapper.isControlLatched
        let action = map(&inputMapper)
        let effects = send(action, env: env)
        guard inputMapper.isControlLatched != wasLatched else { return effects }
        return effects + [.redraw]
    }

    /// Turns one mapped input into the effect it implies, or into nothing when there is no
    /// pane to send it to.
    private func send(
        _ action: MobileInputAction?,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        guard let action, let pane = selectedPaneId else { return [] }
        switch action {
        case .scrollViewport(let scroll):
            return [.scrollViewport(scroll)]
        case .send(let input):
            return [.send(
                requestId: env.newRequestId(),
                request: .paneInput(pane: pane, input: input)
            )]
        }
    }
}
