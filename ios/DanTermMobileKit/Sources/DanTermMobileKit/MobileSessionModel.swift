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
    /// The roster as the shell may show it: ordered, grouped, and made of prepared text.
    public let outline: MobilePaneOutline
    /// The selected pane's prepared name, when it remains in the roster.
    public let selectedPaneTitle: MobileDisplayText?
    public let selectedPaneId: PaneId?
    public let claim: MobileClaimControl
    /// Whether the serving stream can issue a tab-targeted split right now.
    public let canCreatePane: Bool
    /// The modifiers the one-shot latch has armed; the bar's latch keys render from here.
    public let latchedModifiers: KeyMods
}

/// Holds the phone's session facts and answers every event from them.
///
/// It composes the existing policies rather than replacing them: the reconnect episode owns
/// the active target and decides when an attempt runs, the resume policy decides where it
/// starts, and the status composes the line. This type owns the order those answers are
/// applied in, which is the part that had no home and lived in the view controller.
public struct MobileSessionModel: Equatable, Sendable {
    /// How long the phone lets an advanced replica sit before its position is written out.
    public static let checkpointInterval: TimeInterval = 30

    private var draft = MobileTargetDraft(host: nil, port: MobileLaunchPlan.defaultPort)
    private var draftProblem: MobileTargetDraftProblem?
    private var lifecycle = ConnectionLifecycle.disconnected
    private var panes: [PaneRosterItem] = []
    /// The pane most recently resolved for attachment. It remains visible after teardown,
    /// but it grants no request authority outside the serving lifecycle.
    private var lastResolvedPaneId: PaneId?
    private var surface = MobileSurfaceFacts()
    private var preferredPaneId: PaneId?
    private var reconnectEpisode = MobileReconnectEpisode()
    private var resumePolicy = MobileResumePolicy()
    private var inputMapper = MobileInputMapper()
    /// Input a smoke run drives into the first pane once the stream is serving.
    private var pendingSmokeInput: String?
    private var checkpointIsDirty = false
    private var checkpointDeadlineIsArmed = false

    /// The claim this phone made, the grid it requested, and whether the server confirmed it.
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
        var pendingRequestId: MobileRequestId?
    }

    /// The complete connection state. Associated values make serving-only facts
    /// impossible in every other phase.
    private enum ConnectionLifecycle: Equatable, Sendable {
        case disconnected
        case connecting(target: MobileServerTarget)
        case attaching(target: MobileServerTarget, pane: PaneId, serverVersion: String)
        case serving(ServingConnection)
        case failed(failure: MobileConnectionFailure, detail: String?)

        /// Only an active attempt or connection may consume its callbacks.
        var acceptsConnectionCallbacks: Bool {
            switch self {
            case .connecting, .attaching, .serving: true
            case .disconnected, .failed: false
            }
        }
    }

    /// Every fact whose lifetime is the serving connection.
    private struct ServingConnection: Equatable, Sendable {
        let pane: PaneId
        let tapeRequestId: MobileRequestId
        let detail: String
        var newPaneRequestId: MobileRequestId?
        var stream: PaneReplicaState?
        var requestOutcome: MobileRequestOutcome?
        var standingClaim: StandingClaim?

        init(pane: PaneId, tapeRequestId: MobileRequestId, detail: String) {
            self.pane = pane
            self.tapeRequestId = tapeRequestId
            self.detail = detail
        }
    }

    /// Creates the session of an app that has not launched yet.
    public init() {}

    /// Everything the surfaces render, composed at the moment of display: a scheduled retry
    /// is worded as the time remaining, which only that moment can state.
    public func projection(at now: TimeInterval) -> MobileSessionProjection {
        let selectedPaneId = selectedPaneId
        let outline = MobilePaneOutline(items: panes, selectedPaneId: selectedPaneId)
        return MobileSessionProjection(
            status: status(at: now),
            draft: draft,
            draftProblem: draftProblem,
            outline: outline,
            selectedPaneTitle: outline.title(for: selectedPaneId),
            selectedPaneId: selectedPaneId,
            claim: claimControl,
            canCreatePane: canCreatePane,
            latchedModifiers: inputMapper.latchedModifiers
        )
    }

    /// The attached pane is authoritative while serving; every other phase only presents
    /// the retained pane that was last resolved.
    private var selectedPaneId: PaneId? {
        if case .serving(let serving) = lifecycle { return serving.pane }
        return lastResolvedPaneId
    }

    /// Builds the immutable status projection from the lifecycle and reconnect episode.
    private func status(at now: TimeInterval) -> MobileStatusLine {
        let status: MobileStatus
        switch lifecycle {
        case .disconnected:
            status = MobileStatus(connection: .disconnected)
        case .connecting(let target):
            status = MobileStatus(
                connection: .connecting,
                detail: "Connecting to \(target.host):\(target.port)",
                recovery: reconnectEpisode.recoveryPhase(at: now)
            )
        case .attaching(let target, _, _):
            status = MobileStatus(
                connection: .connecting,
                detail: "Connecting to \(target.host):\(target.port)",
                recovery: reconnectEpisode.recoveryPhase(at: now)
            )
        case .serving(let serving):
            status = MobileStatus(
                connection: .ready,
                detail: serving.detail,
                recovery: reconnectEpisode.recoveryPhase(at: now),
                stream: serving.stream,
                requestOutcome: serving.requestOutcome
            )
        case .failed(let failure, let detail):
            status = MobileStatus(
                connection: failure.state,
                detail: detail,
                recovery: reconnectEpisode.recoveryPhase(at: now)
            )
        }
        return status.line(at: now)
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
            return connect(to: plan.draft, saving: false, env: env)

        case .connectRequested(let draft):
            return connect(to: draft, saving: true, env: env)

        case .paneSelected(let pane):
            // The gesture names a pane inside the episode that produced the list, so it
            // never consults the fields: editing them cannot retarget or block it.
            return selectPane(pane, env: env)

        case .newPaneRequested:
            guard canCreatePane,
                  case .serving(var serving) = lifecycle,
                  let tabId = panes.first(where: { $0.paneId == serving.pane })?.tabId
            else { return [] }
            let requestId = env.newRequestId()
            serving.newPaneRequestId = requestId
            lifecycle = .serving(serving)
            return [
                .send(requestId: requestId, request: .paneSplit(tab: tabId)),
                .redraw,
            ]

        case .appForegrounded:
            return reconnect(.appForegrounded, env: env)

        case .appBackgrounded:
            // The teardown comes first, and the episode is told after it, so it learns that
            // this connection is one the app dropped itself and still owes on return.
            let teardown: [MobileSessionEffect] = [
                .flushCheckpoint(savingReplica: takeCheckpointDirt(), synchronously: true),
                .disconnect,
            ]
            lifecycle = .disconnected
            return teardown + reconnect(.appBackgrounded, env: env)

        case .networkPathChanged(let usable):
            return reconnect(.networkPathChanged(usable: usable), env: env)

        case .retryTimerFired:
            return reconnect(.clockFired, env: env)

        case .checkpointTimerFired:
            checkpointDeadlineIsArmed = false
            return [.flushCheckpoint(savingReplica: takeCheckpointDirt(), synchronously: false)]

        case .attemptSucceeded(let roster, let serverVersion):
            guard case .connecting(let target) = lifecycle else { return [] }
            panes = roster.panes
            guard let pane = preferredPaneId
                .flatMap({ wanted in panes.first { $0.paneId == wanted } })
                ?? panes.first(where: { $0.isSelectedTab && $0.isFocused })
                ?? panes.first
            else {
                return end(with: .requestRefused(reason: "The Mac has no panes"), env: env)
            }
            lastResolvedPaneId = pane.paneId
            lifecycle = .attaching(
                target: target,
                pane: pane.paneId,
                serverVersion: serverVersion
            )
            return [
                .attachPane(
                    pane: pane.paneId,
                    resumesFromStoredCheckpoint: resumePolicy.trustsStoredPosition
                ),
                .redraw,
            ]

        case .paneAttached(let pane, let cursor):
            guard case .attaching(_, let expectedPane, let serverVersion) = lifecycle,
                  pane == expectedPane
            else { return [] }
            let requestId = env.newRequestId()
            lifecycle = .serving(ServingConnection(
                pane: pane,
                tapeRequestId: requestId,
                detail: "Connected to DanTerm \(serverVersion)"
            ))
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
            return effects + reconnect(.attemptConnected, env: env)

        case .connectionEnded(let failure):
            guard lifecycle.acceptsConnectionCallbacks else { return [] }
            return end(with: failure, env: env)

        case .replicaRejectedRecord:
            guard case .serving = lifecycle else { return [] }
            return end(with: .deviceSetup, detail: "Replica rejected the stream", env: env)

        case .frameReceived(let frame):
            guard case .serving = lifecycle else { return [] }
            return receive(frame, env: env)

        case .replicaStateChanged(let state):
            guard case .serving(var serving) = lifecycle else { return [] }
            serving.stream = state
            lifecycle = .serving(serving)
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
            guard case .serving(var serving) = lifecycle,
                  let request = claimControl.claim,
                  let grid = surface.nativeGrid
            else {
                return []
            }
            let requestId = env.newRequestId()
            serving.standingClaim = StandingClaim(grid: grid, pendingRequestId: requestId)
            lifecycle = .serving(serving)
            return [.resizePane(requestId: requestId, request: request)]

        case .releaseRequested:
            // A tap the facts no longer offer a release for sends nothing and ends
            // nothing; only the gesture that sends the fit resize gives the claim up.
            guard case .serving(var serving) = lifecycle,
                  let request = claimControl.release
            else { return [] }
            serving.standingClaim = nil
            lifecycle = .serving(serving)
            return [.resizePane(requestId: env.newRequestId(), request: request)]

        case .surfaceChanged(let facts):
            guard facts != surface else { return [] }
            surface = facts
            // A renewal fires only on this phone's own grid change while it holds the
            // claim, so no report about another client's pane can start one, and a
            // momentary nil grid neither renews nor ends anything.
            if case .serving(var serving) = lifecycle,
               serving.standingClaim != nil,
               let grid = facts.nativeGrid,
               grid != serving.standingClaim?.grid,
               let request = claimControl.claim {
                let requestId = env.newRequestId()
                serving.standingClaim = StandingClaim(grid: grid, pendingRequestId: requestId)
                lifecycle = .serving(serving)
                return [.resizePane(requestId: requestId, request: request)]
            }
            return [.session(.redraw)]
        }
    }

    /// The control the phone offers right now, computed from the facts and stored nowhere.
    private var claimControl: MobileClaimControl {
        let pane: PaneId?
        if case .serving(let serving) = lifecycle {
            pane = serving.pane
        } else {
            pane = nil
        }
        return MobileClaimControl(
            connection: pane == nil ? .disconnected : .ready,
            pane: pane,
            pinned: surface.pinned,
            nativeGrid: surface.nativeGrid
        )
    }

    /// New pane needs a live request channel, the attached pane's tab, and no prior split
    /// still waiting for its answer.
    private var canCreatePane: Bool {
        guard case .serving(let serving) = lifecycle,
              serving.newPaneRequestId == nil
        else { return false }
        return panes.contains { $0.paneId == serving.pane }
    }

    /// Routes a pane choice through the one reconnect path shared by the picker and a
    /// successful New pane response.
    private mutating func selectPane(
        _ pane: PaneId,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        let effects = reconnect(.targetReused, env: env)
        guard effects.isEmpty == false else { return [] }
        preferredPaneId = pane
        return effects
    }

    /// The gesture that names a server: the Go button, or the attempt made at launch.
    ///
    /// Only the user's own Go gesture saves what it names (`saving: true`). A launch target
    /// belongs to this process alone -- `just ios-app --slot N` aims the phone at a
    /// development slot, and saving that would leave the next ordinary launch dialing a
    /// slot that no longer exists.
    private mutating func connect(
        to draft: MobileTargetDraft,
        saving: Bool,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        self.draft = draft
        switch draft.validate() {
        case .valid(let target):
            draftProblem = nil
            preferredPaneId = selectedPaneId
            let store: [MobileSessionEffect] = saving
                ? [.storeTarget(host: target.host, port: String(target.port))]
                : []
            return store + reconnect(.targetNamed(target), env: env)
        case .reportDraft(let problem):
            // A field problem is reported beside its field and nowhere else. The episode
            // is left alone deliberately: a typo must not cancel a retry already owed to a
            // good target.
            draftProblem = problem
            return [.redraw]
        }
    }

    /// Feeds the reconnect episode one event and turns the single decision it returns into
    /// effects. The episode's own moment is handed over as it stands: no arithmetic here.
    private mutating func reconnect(
        _ event: MobileReconnectEvent,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        switch reconnectEpisode.handle(event, at: env.now) {
        case .attemptNow(let target):
            return [.cancelRetryTimer] + startAttempt(target) + [.redraw]
        case .wait(let until):
            return [.armRetryTimer(deadline: until), .redraw]
        case .rest:
            return [.cancelRetryTimer, .redraw]
        case .ignore:
            return []
        }
    }

    /// Opens one attempt against the non-optional target the episode authorized.
    private mutating func startAttempt(_ target: MobileServerTarget) -> [MobileSessionEffect] {
        let teardown: [MobileSessionEffect] = [
            .flushCheckpoint(savingReplica: takeCheckpointDirt(), synchronously: true),
            .disconnect,
        ]
        lifecycle = .connecting(target: target)
        return teardown + [.connect(target)]
    }

    /// Ends the current connection on one typed cause and lets the episode decide what
    /// follows it.
    ///
    /// The teardown comes first and is what makes the cause unique: it fences the runner,
    /// so a stream that ended and then reported its read error cannot hand the episode a
    /// second, differently classified cause for the same connection.
    private mutating func end(
        with failure: MobileConnectionFailure,
        detail: String? = nil,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        lifecycle = .failed(failure: failure, detail: detail)
        resumePolicy.connectionEnded(with: failure)
        return [.disconnect] + reconnect(.attemptFailed(failure), env: env)
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
        guard case .serving(var serving) = lifecycle else { return [] }
        switch frame {
        case .response(let response):
            if let pendingNewPaneRequestId = serving.newPaneRequestId,
               pendingNewPaneRequestId.matches(response.id) {
                serving.newPaneRequestId = nil
                if let error = response.error {
                    serving.requestOutcome = .refused(reason: error.message)
                    lifecycle = .serving(serving)
                    return [.redraw]
                }
                guard let pane = response.result.flatMap(paneReference) else {
                    serving.requestOutcome = .refused(
                        reason: "Mac returned an unreadable pane"
                    )
                    lifecycle = .serving(serving)
                    return [.redraw]
                }
                serving.requestOutcome = .succeeded
                lifecycle = .serving(serving)
                return selectPane(pane, env: env)
            }
            if let error = response.error {
                if let pending = serving.standingClaim?.pendingRequestId,
                   pending.matches(response.id) {
                    serving.standingClaim = nil
                }
                // Only the tape subscription's refusal ends the connection. A refused input
                // request is the newest outcome on a stream that is still serving, and the
                // next completed request replaces it.
                guard serving.tapeRequestId.matches(response.id) else {
                    serving.requestOutcome = .refused(reason: error.message)
                    lifecycle = .serving(serving)
                    return [.redraw]
                }
                return end(with: .requestRefused(reason: error.message), env: env)
            }
            if let pending = serving.standingClaim?.pendingRequestId,
               pending.matches(response.id) {
                serving.standingClaim?.pendingRequestId = nil
            }
            guard serving.tapeRequestId.matches(response.id) else {
                serving.requestOutcome = .succeeded
                lifecycle = .serving(serving)
                return [.redraw]
            }
            lifecycle = .serving(serving)
            return take(response.result, env: env)
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
            ) else { return [] }
            // One notification can carry a whole delivered batch. Each record is taken in
            // wire order, exactly as it would have been had the producer sent them one at a
            // time. A record that ends the connection ends the batch with it: `take` answers
            // nothing once the model has stopped serving.
            var effects: [MobileSessionEffect] = []
            for record in notification.records {
                effects += take(record, env: env)
            }
            return effects
        }
    }

    /// Reads the pane reference returned by `pane.split`, or refuses a success whose
    /// result cannot name a typed pane.
    private func paneReference(_ result: JSONValue) -> PaneId? {
        guard let raw = result["pane"]?["id"]?.asString,
              let uuid = UUID(uuidString: raw)
        else { return nil }
        return PaneId(rawValue: uuid)
    }

    /// Decides everything about one arriving tape record: whether this build can read it,
    /// what it states about pinnedness, and whether it ends the stream. Both frame arms
    /// come through here, so the wire has exactly one verdict and the record is parsed
    /// once -- past this point it carries the typed event, so no consumer reads the JSON
    /// again.
    ///
    /// A record this build cannot read ends the connection rather than being skipped or
    /// dropped. Skipping one leaves the replica's cursor behind, and the next record then
    /// reports a gap: the phone would blame the Mac, and throw away the stored checkpoint,
    /// over bytes the phone itself could not parse. A nil value is the reply that carried
    /// neither result nor error, which is the same defect on this phone.
    private mutating func take(
        _ value: JSONValue?,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        guard case .serving = lifecycle else { return [] }
        guard let value,
              let record = decodePaneTapeRecord(value),
              let typed = try? record.mapEvent({ event in
                  try JSONValueDecoder().decode(NeutralTerminalRecordingEvent.self, from: event)
              })
        else {
            return end(with: .deviceSetup, detail: "Stream carried an unreadable record", env: env)
        }
        noteRecordPinnedness(typed)
        // The end is decided here, not reported back by the surface: the replica ignores an
        // end record, so a round trip through the shell only delayed the same answer.
        if case .end(let reason) = typed {
            return end(with: .streamEnded(reason: reason?.rawValue), env: env)
        }
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
        guard case .serving(var serving) = lifecycle,
              let claim = serving.standingClaim,
              claim.pendingRequestId == nil
        else { return }
        guard pinnedStatement(in: record) == false else { return }
        serving.standingClaim = nil
        lifecycle = .serving(serving)
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

    /// Runs one key-shaped input through the mapper and adds a redraw when it changed the
    /// one-shot latch, so the bar's highlights follow the projection without a latch-key
    /// tap of their own.
    private mutating func mapKeyInput(
        _ map: (inout MobileInputMapper) -> MobileInputAction?,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        let wasLatched = inputMapper.latchedModifiers
        let action = map(&inputMapper)
        let effects = send(action, env: env)
        guard inputMapper.latchedModifiers != wasLatched else { return effects }
        return effects + [.redraw]
    }

    /// Turns one mapped input into the effect it implies, or into nothing when there is no
    /// pane to send it to.
    private func send(
        _ action: MobileInputAction?,
        env: MobileSessionEnv
    ) -> [MobileSessionEffect] {
        guard let action else { return [] }
        switch action {
        case .scrollViewport(let scroll):
            guard lastResolvedPaneId != nil else { return [] }
            return [.scrollViewport(scroll)]
        case .send(let input):
            guard case .serving(let serving) = lifecycle else { return [] }
            return [.send(
                requestId: env.newRequestId(),
                request: .paneInput(pane: serving.pane, input: input)
            )]
        }
    }
}
