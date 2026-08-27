// Behavioral tests for the phone session's decision core: what leaves the phone, in what
// order, and which facts each decision is made from.
//
// Every test drives the model with an explicit clock and explicit request ids, so nothing
// here waits on real time or on a socket. What is deliberately absent: how an effect is
// performed -- the model decides only what the shell must do.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Foundation
import Testing

@Test("A valid Go gesture replaces an in-flight attempt with its new target")
func goGestureReplacesInFlightAttempt() {
    // Intent: the second valid server becomes both the persisted target and the target of
    //   the replacement attempt, with the old attempt torn down before the new one starts.
    // Why it exists: target storage used to accept the edit while reconnect policy rejected
    //   the gesture, leaving the old attempt current after the user replaced its server.
    // Scenario: the first Mac is still connecting when the user submits a second Mac.
    var session = Session()
    _ = session.handle(.launched(MobileLaunchInputs(environmentHost: session.target.host)))
    let replacement = MobileServerTarget(host: "other.tailnet", port: 9000)

    let effects = session.handle(.connectRequested(MobileTargetDraft(
        host: replacement.host,
        port: String(replacement.port)
    )))

    #expect(effects.filter(\.leavesThePhone) == [
        .storeTarget(host: replacement.host, port: String(replacement.port)),
        .flushCheckpoint(savingReplica: false, synchronously: true),
        .disconnect,
        .connect(replacement),
    ])
    #expect(session.model.projection(at: session.now).status.text.contains(replacement.host))
}

@Test("A pane gesture replaces an in-flight attach without reading an invalid draft")
func paneGestureReusesTargetDuringInFlightAttach() {
    // Intent: selecting a pane is the same manual replacement remedy as Go, but it reuses
    //   the active server even when the edited draft cannot name one.
    // Why it exists: the separate policy used to reject every manual gesture while an
    //   attempt was in flight, and a shared shell route once let draft edits block panes.
    // Scenario: the roster arrived, the user half-edits the host, then picks another pane
    //   before the first pane has attached.
    var session = Session()
    _ = session.handle(.launched(MobileLaunchInputs(environmentHost: session.target.host)))
    _ = session.handle(.attemptSucceeded(
        roster: roster(panes: [(201, "zsh"), (202, "vim")]),
        serverVersion: "1.2.3"
    ))
    #expect(session.handle(.connectRequested(MobileTargetDraft(host: "   ", port: "7420")))
        == [.redraw])

    let effects = session.handle(.paneSelected(paneId(202)))

    #expect(effects.filter(\.leavesThePhone) == [
        .flushCheckpoint(savingReplica: false, synchronously: true),
        .disconnect,
        .connect(session.target),
    ])
}

@Test("A pane gesture before the first target has no effect")
func paneGestureWithoutAnEpisodeIsIgnored() {
    var session = Session()
    let before = session.model
    #expect(session.handle(.paneSelected(session.pane)).isEmpty)
    #expect(session.model == before)
}

@Test("An invalid draft leaves the active target and its timed retry unchanged")
func invalidDraftDoesNotDisturbPendingRecovery() {
    // Intent: a field error reports itself without changing the target, retry budget, or
    //   deadline already owed to the established server.
    // Why it exists: draft validation is outside the reconnect episode so partial edits
    //   cannot become scheduling inputs or silently cancel recovery.
    // Scenario: two failed attempts arm backoff, then the user submits a blank host before
    //   that timer fires.
    var session = Session()
    let delay = MobileReconnectEpisode.Schedule.standard.delays[1]
    _ = session.handle(.launched(MobileLaunchInputs(environmentHost: session.target.host)))
    _ = session.handle(.connectionEnded(.transport(.peerClosed)))
    let waiting = session.handle(
        .connectionEnded(.transport(.peerClosed))
    )
    #expect(waiting.contains(.armRetryTimer(deadline: session.now + delay)))

    #expect(session.handle(.connectRequested(MobileTargetDraft(host: "   ", port: "7420")))
        == [.redraw])
    session.now += delay

    #expect(session.handle(.retryTimerFired).contains(.connect(session.target)))
}

@Test("Backgrounding saves the position, drops the connection, and owes a reconnect")
func backgroundingFlushesThenDisconnects() throws {
    // Intent: the background event returns exactly the checkpoint flush and then the
    //   disconnect, and leaves the reconnect owed so returning to the foreground dials
    //   again on its own.
    // Why it exists: the two effects are ordered against each other -- a flush after the
    //   teardown would save a position the replica no longer holds -- and the reconnect
    //   debt is policy state, so an implementation that announced it as an effect could
    //   perform it twice or lose it.
    // Scenario: the user switches away from the phone client mid-session and comes back.
    var session = Session()
    try session.reachServingStream()

    let backgrounded = session.handle(.appBackgrounded)
    #expect(backgrounded.filter(\.leavesThePhone) == [
        .flushCheckpoint(savingReplica: false, synchronously: true),
        .disconnect,
    ])
    #expect(session.model.projection(at: session.now).status == MobileStatusLine(
        text: "Disconnected",
        severity: .normal,
        isResting: false
    ))

    session.now += 5
    #expect(session.handle(.appForegrounded).contains(.connect(session.target)))
    #expect(session.model.projection(at: session.now).status.text.contains(
        "Connecting to \(session.target.host):\(session.target.port)"
    ))
}

@Test("Teardown rejects remote actions but retains local viewport movement")
func teardownRevokesRemoteAuthorityOnly() throws {
    // Intent: every request-bearing input and owner scroll is silent after teardown, while
    //   the retained primary-screen replica can still move its local viewport.
    // Why it exists: the selected pane used to survive as enough authority to send after
    //   the connection lifecycle had ended.
    // Scenario: the connection drops while the user continues typing and scrolling the
    //   replica that remains on screen.
    var session = Session()
    try session.reachServingStream()
    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: false,
        isAlternateScreenActive: true
    )))
    _ = session.handle(.connectionEnded(.transport(.peerClosed)))

    let remoteInputs: [MobileSessionEvent] = [
        .textEntered("ls"),
        .deleteBackwardPressed,
        .pasted("pwd"),
        .accessoryKeyPressed(.tab),
        .hardwareKeyPressed(.enter, []),
        .hardwareCharacterPressed("c", []),
        .scrolledByRows(2, column: 4, row: 5),
    ]
    for event in remoteInputs {
        #expect(requests(session.handle(event)).isEmpty, "\(event)")
    }
    #expect(resizes(session.handle(.claimRequested)).isEmpty)
    #expect(resizes(session.handle(.releaseRequested)).isEmpty)
    #expect(session.handle(.newPaneRequested).isEmpty)

    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(isAlternateScreenActive: false)))
    #expect(session.handle(.scrolledByRows(-3, column: 4, row: 5)) == [
        .scrollViewport(.byRows(-3)),
    ])
}

@Test("Connection callbacks outside their lifecycle phase are stale")
func staleConnectionCallbacksCannotReviveAConnection() throws {
    // Intent: callbacks from the fenced connection do nothing after teardown, including
    //   callbacks that would otherwise attach a pane, start a stream, or mutate status.
    // Why it exists: the shell generation fence is a useful transport boundary, but the
    //   model must make stale connection input invalid on its own.
    // Scenario: background teardown wins a race with every callback source in turn.
    var session = Session()
    try session.reachServingStream()
    _ = session.handle(.appBackgrounded)
    let before = session.model

    let callbacks: [MobileSessionEvent] = [
        .attemptSucceeded(roster: roster(panes: [(202, "vim")]), serverVersion: "9.9.9"),
        .paneAttached(pane: paneId(202), cursor: nil),
        .frameReceived(.notification(
            method: Methods.rosterEvent,
            params: roster(panes: [(202, "vim")]).jsonValue
        )),
        .replicaStateChanged(.gap(.detected)),
        .replicaRejectedRecord,
        .connectionEnded(.transport(.peerClosed)),
    ]
    for event in callbacks {
        #expect(session.handle(event).isEmpty, "\(event)")
        #expect(session.model == before, "\(event)")
    }

    #expect(session.handle(.replicaAdvanced) == [
        .armCheckpointTimer(deadline: session.now + MobileSessionModel.checkpointInterval),
    ])
    #expect(session.handle(.checkpointTimerFired) == [
        .flushCheckpoint(savingReplica: true, synchronously: false),
    ])
}

@Test("An advanced replica is what a background flush has to save")
func backgroundingSavesAnAdvancedReplica() {
    // Intent: the flush the background event returns saves the replica exactly when the
    //   replica moved since the last write.
    // Why it exists: a flush that always saved would write a stale snapshot on every
    //   switch away, and one that never saved would lose the session's newest position.
    var session = Session()
    _ = session.handle(.replicaAdvanced)
    #expect(session.handle(.appBackgrounded).contains(
        .flushCheckpoint(savingReplica: true, synchronously: true)
    ))
}

@Test("Replica transitions redraw, detected gaps end, and current facts control release")
func replicaTransitionsAndSurfaceFactsDriveTheirOwnEffects() throws {
    // Intent: every replica state transition redraws, a locally detected gap ends the
    //   connection, and a facts report that withdraws pinnedness withdraws the release.
    // Why it exists: the app shell reports state and replica-derived facts on separate
    //   change-only callbacks, so each model input must still carry its whole behavior.
    // Scenario: a serving stream synchronizes, declares a recoverable gap, repairs it,
    //   then detects an irrecoverable gap after its pane is no longer known to be pinned.
    var session = Session()
    try session.reachServingStream()

    let declaredLoss = PaneTapeGapRecord.Loss.exact(
        droppedEventCount: 1,
        droppedFeedBytes: 2,
        droppedWriteBytes: 3
    )
    for state: PaneReplicaState in [
        .awaitingSynchronization,
        .exact,
        .gap(.declared(declaredLoss)),
        .exact,
    ] {
        #expect(session.handle(.replicaStateChanged(state)) == [.redraw])
    }

    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: true
    )))
    #expect(session.model.projection(at: session.now).claim.release != nil)
    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: nil
    )))
    #expect(session.model.projection(at: session.now).claim.release == nil)

    #expect(session.handle(.replicaStateChanged(.gap(.detected))).contains(.disconnect))
}

@Test("A claim sends the grid the surface draws now, and a release sends the fit form")
func geometryGesturesSendTheCurrentGrid() throws {
    // Intent: the claim gesture's whole wire effect is one resize carrying the surface's
    //   current grid, and the release gesture's is the fit form.
    // Why it exists: the resize is the phone's only authoritative geometry statement, so
    //   a claim that named a grid the surface does not draw would pin the pane to a size
    //   nothing can show.
    var session = Session()
    try session.reachServingStream()
    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: false
    )))

    #expect(resizes(session.handle(.claimRequested)) == [
        .paneResize(pane: session.pane, resize: .grid(columns: 80, rows: 24)),
    ])
    #expect(resizes(session.handle(.releaseRequested)).isEmpty)

    // The changed-grid report lands on a standing claim (the release above ended none:
    // it sent nothing), so it renews rather than merely storing the facts.
    #expect(resizes(session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 40, rows: 12),
        pinned: true
    )))) == [
        .paneResize(pane: session.pane, resize: .grid(columns: 40, rows: 12)),
    ])
    #expect(resizes(session.handle(.claimRequested)) == [
        .paneResize(pane: session.pane, resize: .grid(columns: 40, rows: 12)),
    ])
    #expect(resizes(session.handle(.releaseRequested)) == [
        .paneResize(pane: session.pane, resize: .fit),
    ])
}

@Test("A geometry gesture the facts no longer offer sends nothing")
func geometryGesturesFollowTheFactsAtTheTap() throws {
    // Intent: the gesture is answered from the facts as they stand when it is handled,
    //   so a tap that arrives after the pane was unpinned or the connection dropped
    //   sends nothing rather than the request the earlier facts would have produced.
    // Why it exists: a menu item stays on screen while the Mac takes the pane back, and
    //   a request built when the menu opened would resize a pane the phone no longer has
    //   any claim on.
    // Scenario: the menu is left open while the Mac releases the pane, and again while
    //   the connection drops under it.
    var session = Session()
    try session.reachServingStream()
    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: true
    )))
    #expect(resizes(session.handle(.releaseRequested)).isEmpty == false)

    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: false
    )))
    #expect(resizes(session.handle(.releaseRequested)).isEmpty)

    _ = session.handle(.connectionEnded(.transport(.peerClosed)))
    #expect(resizes(session.handle(.claimRequested)).isEmpty)
    #expect(resizes(session.handle(.releaseRequested)).isEmpty)
}

@Test("A surface with no room for a whole cell offers no claim")
func noClaimWithoutAWholeCell() throws {
    var session = Session()
    try session.reachServingStream()
    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(nativeGrid: nil, pinned: false)))
    #expect(resizes(session.handle(.claimRequested)).isEmpty)
}

@Test("A surface report renews only a claim this phone made")
func surfaceReportRenewsOnlyThePhonesOwnClaim() throws {
    // Intent: after a claim, a surface report offering a different grid emits exactly one
    //   effect -- a resize at that grid; the same report without a prior claim, including
    //   on an externally pinned pane whose grid moves, emits no resize.
    // Why it exists: the renewal is what re-claims on rotation without a gesture, and its
    //   gate is what keeps this phone from renewing a claim it never made -- the only
    //   thing standing between two clients and a renewal loop.
    var session = Session()
    try session.reachServingStream()
    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: false
    )))
    _ = session.handle(.claimRequested)

    let rotated = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 40, rows: 60),
        pinned: true
    )))
    #expect(rotated.count == 1)
    #expect(resizes(rotated) == [
        .paneResize(pane: session.pane, resize: .grid(columns: 40, rows: 60)),
    ])

    var observer = Session()
    try observer.reachServingStream()
    _ = observer.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: true
    )))
    #expect(resizes(observer.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 40, rows: 60),
        pinned: true
    )))).isEmpty)
}

@Test("Renewals are self-quiescing")
func renewalQuiescesOnRepeatedFactsAndItsOwnEcho() throws {
    // Intent: after a renewal, repeating the same facts emits nothing, and the renewal's
    //   own echo -- the pinned flip at the renewed grid -- emits no further resize.
    // Why it exists: the renewal reads the same facts it changes, so without quiescence
    //   the echo would renew again and the phone would resize the pane forever.
    var session = Session()
    try session.reachServingStream()
    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: false
    )))
    _ = session.handle(.claimRequested)
    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 40, rows: 60),
        pinned: false
    )))

    #expect(session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 40, rows: 60),
        pinned: false
    ))).isEmpty)
    let echo = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 40, rows: 60),
        pinned: true
    )))
    #expect(resizes(echo).isEmpty)
    #expect(session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 40, rows: 60),
        pinned: true
    ))).isEmpty)
}

@Test("The standing claim ends on release, on connection end, and on an error response")
func standingClaimEndsOnReleaseConnectionEndAndErrorResponse() throws {
    // Intent: each of the three endings leaves no claim behind, proven by the next
    //   changed-grid report emitting no renewal.
    // Why it exists: a claim that outlived its ending would re-pin the pane on the next
    //   rotation -- after the user released it, on a connection the server never
    //   confirmed, or over a request the server refused.
    var released = Session()
    try released.reachServingStream()
    _ = released.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: false
    )))
    _ = released.handle(.claimRequested)
    _ = released.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: true
    )))
    #expect(resizes(released.handle(.releaseRequested)).isEmpty == false)
    #expect(resizes(released.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 40, rows: 60),
        pinned: true
    )))).isEmpty)

    var dropped = Session()
    try dropped.reachServingStream()
    _ = dropped.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: false
    )))
    _ = dropped.handle(.claimRequested)
    _ = dropped.handle(.connectionEnded(.transport(.peerClosed)))
    _ = dropped.handle(.attemptSucceeded(roster: roster(), serverVersion: "1.2.3"))
    _ = dropped.handle(.paneAttached(pane: dropped.pane, cursor: nil))
    #expect(resizes(dropped.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 40, rows: 60),
        pinned: false
    )))).isEmpty)

    var refused = Session()
    try refused.reachServingStream()
    _ = refused.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: false
    )))
    let claimId = try #require(resizeRequestIds(refused.handle(.claimRequested)).first)
    _ = refused.handle(.frameReceived(.response(JsonRpcResponse(
        id: claimId.jsonValue,
        error: JsonRpcError(code: -1, message: "no")
    ))))
    #expect(resizes(refused.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 40, rows: 60),
        pinned: false
    )))).isEmpty)
}

@Test("Only the phone's own response confirms, and only a later unpinned record ends")
func claimConfirmationAndExternalReleaseFollowTheFrameOrder() throws {
    // Intent: a replica report showing the pane pinned at exactly the claimed grid does
    //   not confirm the claim, so an unpinned record decoded before the request's success
    //   response is pre-claim truth and ends nothing; the same record decoded after the
    //   response is an external release and ends it.
    // Why it exists: the pane may already be pinned at this phone's grid by another
    //   client, so the phone's resize is a server-side no-op with no tape transition --
    //   the response is the only confirmation that exists, and reading the record's
    //   pinnedness anywhere but the decode point would misorder it against the response.
    var session = Session()
    try session.reachServingStream()
    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: true
    )))
    let claimId = try #require(resizeRequestIds(session.handle(.claimRequested)).first)

    // Pinned-at-the-claimed-grid replica facts must not confirm: the unpinned record
    // decoded next still precedes the response, so the claim must survive it.
    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: true,
        isAlternateScreenActive: true
    )))
    _ = session.handle(tapeResizeNotification(columns: 80, rows: 24, pinned: false))
    _ = session.handle(.frameReceived(.response(JsonRpcResponse(
        id: claimId.jsonValue,
        result: .object(["ok": .bool(true)])
    ))))

    // The claim survived the pre-response record, the pinned facts, the pre-claim
    // unpinned facts repeated after confirmation, and a momentary nil-grid report.
    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: false
    )))
    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(nativeGrid: nil, pinned: false)))
    let renewal = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 40, rows: 60),
        pinned: false
    )))
    let renewalId = try #require(resizeRequestIds(renewal).first)
    #expect(resizes(renewal) == [
        .paneResize(pane: session.pane, resize: .grid(columns: 40, rows: 60)),
    ])

    // The renewal reset confirmation, so an unpinned record before its response ends
    // nothing; after the response, the same record is an external release.
    _ = session.handle(tapeResizeNotification(columns: 40, rows: 60, pinned: false))
    _ = session.handle(.frameReceived(.response(JsonRpcResponse(
        id: renewalId.jsonValue,
        result: .object(["ok": .bool(true)])
    ))))
    let survived = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 30, rows: 50),
        pinned: false
    )))
    let secondRenewalId = try #require(resizeRequestIds(survived).first)
    _ = session.handle(.frameReceived(.response(JsonRpcResponse(
        id: secondRenewalId.jsonValue,
        result: .object(["ok": .bool(true)])
    ))))

    _ = session.handle(tapeResizeNotification(columns: 30, rows: 50, pinned: false))
    #expect(resizes(session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: false
    )))).isEmpty)
}

@Test("A tape event this build cannot read ends the connection and reaches no surface")
func undecodableTapeEventEndsTheConnection() throws {
    // Intent: a well-formed record whose inner event does not decode produces no
    //   applyRecord effect and ends the connection exactly as a replica refusal does.
    // Why it exists: the event is decoded once, at the model's edge, so the refusal that
    //   used to come back from the surface has to be decided here instead -- and it must
    //   still end the connection rather than let a record the phone cannot read pass by.
    var refusing = Session()
    try refusing.reachServingStream()
    let refusal = refusing.handle(.replicaRejectedRecord)

    var session = Session()
    try session.reachServingStream()
    // A feed event with neither byte encoding: the record shape is valid, the event is not.
    let effects = session.handle(tapeEventNotification(.object(["type": .string("feed")])))

    #expect(!effects.contains { effect in
        if case .applyRecord = effect { return true }
        return false
    })
    #expect(effects == refusal)
}

@Test("Every record of a batched notification is applied, in wire order")
func batchedTapeNotificationAppliesEveryRecordInOrder() throws {
    // Intent: a notification carrying several records applies all of them, in the order
    //   they arrived, exactly as the same records would have been applied one at a time.
    // Why it exists: the producer now delivers a whole batch in one notification. A reader
    //   that took only the first record would drop most of a busy pane's output, and one
    //   that reordered them would render bytes the pane never produced in that order.
    // Scenario: a busy pane delivers three feed records in one delivery.
    var session = Session()
    try session.reachServingStream()

    let effects = session.handle(.frameReceived(.notification(
        method: Methods.paneTapeEvent,
        params: .object([
            "subscription": .string("subscription-1"),
            "records": .array((1...3).map { sequence in
                .object([
                    "kind": .string("event"),
                    "sequence": .number(Double(sequence)),
                    "elapsedNanoseconds": .number(0),
                    "event": .object([
                        "type": .string("feed"),
                        "base64": .string(Data([UInt8(sequence)]).base64EncodedString()),
                    ]),
                ])
            }),
        ])
    )))

    let applied = effects.compactMap { effect -> UInt64? in
        guard case .applyRecord(let record) = effect, case .event(let event) = record else {
            return nil
        }
        return event.sequence
    }
    #expect(applied == [1, 2, 3])
}

@Test("A resize event with no pinned key states the pane unpinned")
func resizeWithoutPinnedKeyStatesUnpinned() throws {
    // Intent: a resize event that omits `pinned` entirely ends a confirmed standing claim,
    //   which is what reading it as unpinned means.
    // Why it exists: recordings made before pinnedness existed omit the key, and the one
    //   place that default is now stated is the event's own decode -- a bridge that turned
    //   the missing key into a decode failure, or into pinned, would silently strand the
    //   phone's claim.
    var session = Session()
    try session.reachServingStream()
    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 80, rows: 24),
        pinned: true
    )))
    let claimId = try #require(resizeRequestIds(session.handle(.claimRequested)).first)
    _ = session.handle(.frameReceived(.response(JsonRpcResponse(
        id: claimId.jsonValue,
        result: .object(["ok": .bool(true)])
    ))))

    _ = session.handle(tapeEventNotification(.object([
        "type": .string("resize"),
        "columns": .number(80),
        "rows": .number(24),
    ])))

    #expect(resizes(session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 40, rows: 60),
        pinned: false
    )))).isEmpty)
}

@Test("Typing reaches the pane the model holds, and nothing before it holds one")
func typingRoutesToTheSelectedPane() throws {
    // Intent: text goes to the selected pane, and text handled before a pane is selected
    //   produces nothing.
    // Why it exists: the model is the only owner of the selected pane, so an input event
    //   handled before a pane exists must produce nothing rather than guess one.
    var session = Session()
    #expect(session.handle(.textEntered("ls")).isEmpty)

    try session.reachServingStream()
    #expect(requests(session.handle(.textEntered("ls"))) == [
        .paneInput(pane: session.pane, input: .events([.text("ls")])),
    ])
}

@Test("Each scroll meaning has a safe answer under either replicated screen mode")
func scrollRoutesByScreenAndMeaning() throws {
    // Intent: an absolute row moves the local viewport on the primary screen and does
    //   nothing on the alternate one; whole rows become wheel events on the alternate
    //   screen and a local relative scroll on the primary one.
    // Why it exists: the chrome routes a gesture under the mode it last saw, so a screen
    //   flip mid-gesture must not turn either event category into a wrong action -- an
    //   absolute row has no meaning on a screen with no scrollback, and residual rows
    //   must never be replayed as an absolute jump.
    var session = Session()
    #expect(session.handle(.scrolledToTopRow(3)).isEmpty)
    #expect(session.handle(.scrolledByRows(-2, column: 1, row: 1)).isEmpty)

    try session.reachServingStream()
    #expect(session.handle(.scrolledByRows(3, column: 4, row: 5))
        == [.scrollViewport(.byRows(3))])

    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(isAlternateScreenActive: true)))
    #expect(session.handle(.scrolledToTopRow(3)).isEmpty)
    #expect(requests(session.handle(.scrolledByRows(2, column: 4, row: 5))) == [
        .paneInput(pane: session.pane, input: .events([
            .wheel(.down, column: 4, row: 5),
            .wheel(.down, column: 4, row: 5),
        ])),
    ])
}

@Test("Backspace reaches the selected pane as the named key")
func backspaceReachesThePane() throws {
    // Intent: a backspace from the keyboard is ordinary pane input, routed to the pane
    //   the model holds like any other keystroke.
    // Why it exists: the terminal's input responder is the only place a software
    //   backspace can be observed, and the composer it replaced dropped the key outright.
    var session = Session()
    try session.reachServingStream()
    #expect(requests(session.handle(.deleteBackwardPressed)) == [
        .paneInput(pane: session.pane, input: .events([.key(.named(.bspace), [])])),
    ])
}

@Test("An armed Ctrl latch chords the next input, clears, and redraws the projection")
func armedControlLatchIsConsumedByEveryInputCategory() throws {
    // Intent: with the latch armed, each latch-consuming event category sends the intent
    //   the latch implies (a Ctrl chord, or unchanged text for a commit that cannot be
    //   chorded), clears the projection's latch, and redraws so the bar's highlight
    //   follows without a Ctrl tap.
    // Why it exists: the button's highlight is rendered from the projection on the redraw
    //   path, so a consuming input that did not redraw would leave a lit Ctrl key over a
    //   latch that is already gone.
    var session = Session()
    try session.reachServingStream()

    let cases: [(MobileSessionEvent, IpcPaneInput)] = [
        (.textEntered("f"), .events([.key(.character("f"), .ctrl)])),
        (.textEntered("hello"), .events([.text("hello")])),
        (.pasted("hello"), .text("hello")),
        (.deleteBackwardPressed, .events([.key(.named(.bspace), .ctrl)])),
        (.accessoryKeyPressed(.tab), .events([.key(.named(.tab), .ctrl)])),
        (.hardwareKeyPressed(.enter, [.shift]), .events([.key(.named(.enter), [.shift, .ctrl])])),
        (.hardwareCharacterPressed("c", []), .events([.key(.character("c"), .ctrl)])),
    ]
    for (event, input) in cases {
        let armed = session.handle(.accessoryKeyPressed(.control))
        #expect(armed == [.redraw])
        #expect(session.model.projection(at: session.now).latchedModifiers == .ctrl)

        let effects = session.handle(event)
        #expect(requests(effects) == [.paneInput(pane: session.pane, input: input)])
        #expect(effects.contains(.redraw))
        #expect(session.model.projection(at: session.now).latchedModifiers == [])
    }
}

@Test("With the latch off every input category keeps today's intent and redraw behavior")
func unarmedInputCategoriesAreUnchanged() throws {
    // Intent: without the latch, each event category sends what it always sent, and only
    //   the accessory row -- whose taps have always redrawn -- emits a redraw.
    // Why it exists: the one-shot latch touches every input path, so each unarmed path
    //   needs its unchanged behavior pinned down beside the armed one.
    var session = Session()
    try session.reachServingStream()

    let cases: [(MobileSessionEvent, IpcPaneInput, Bool)] = [
        (.textEntered("f"), .events([.text("f")]), false),
        (.pasted("hello"), .text("hello"), false),
        (.deleteBackwardPressed, .events([.key(.named(.bspace), [])]), false),
        (.accessoryKeyPressed(.tab), .events([.key(.named(.tab), [])]), true),
        (.hardwareKeyPressed(.enter, [.shift]), .events([.key(.named(.enter), .shift)]), false),
        (.hardwareCharacterPressed("c", []), .events([.text("c")]), false),
    ]
    for (event, input, redraws) in cases {
        let effects = session.handle(event)
        #expect(requests(effects) == [.paneInput(pane: session.pane, input: input)])
        #expect(effects.contains(.redraw) == redraws)
        #expect(session.model.projection(at: session.now).latchedModifiers == [])
    }
}

@Test("Smoke input is driven into the responder rather than sent from the model")
func smokeInputEntersThroughTheResponder() throws {
    // Intent: a launch carrying smoke input answers the attached pane with the probe for
    //   the shell to drive, and sends nothing itself.
    // Why it exists: a probe the model sent straight to the pane would prove the model's
    //   own path and leave the responder -- the only thing this migration replaced --
    //   untested by the simulator run that exists to test it.
    var session = Session()
    let launched = session.handle(.launched(MobileLaunchInputs(
        environmentHost: session.target.host,
        smokeInput: "echo hi"
    )))
    #expect(launched.contains(.connect(session.target)))
    _ = session.handle(.attemptSucceeded(roster: roster(), serverVersion: "1.2.3"))

    let attached = session.handle(.paneAttached(pane: session.pane, cursor: nil))
    #expect(attached.contains(.driveSmokeInput(MobileSmokeInputScript.steps(for: "echo hi"))))
    #expect(requests(attached).contains { $0.method == .paneInput } == false)
}

@Test("A launch with no host connects to nothing and reports no problem")
func launchWithoutAHostStaysPut() {
    // Intent: a launch that names no host waits, and says nothing about the empty field
    //   the user has not filled in yet.
    // Why it exists: reporting a draft problem at launch would greet a first run with an
    //   error about a field nobody touched.
    var session = Session()
    let effects = session.model.handle(.launched(MobileLaunchInputs()), env: session.env)
    #expect(effects == [.redraw])
    #expect(session.model.projection(at: session.now).draftProblem == nil)
}

@Test("A launch target connects without becoming the saved target")
func launchTargetDoesNotPersist() {
    // Intent: a target the process was launched with is used for this run only -- it
    //   connects, and nothing is written to the store.
    // Why it exists: `just ios-app --slot N` launches the phone against a development
    //   slot. Saving that slot over the user's own Mac left the next ordinary launch
    //   dialing a slot that had already been released.
    // Scenario: the runner launches the client at slot 4's tailnet endpoint.
    var session = Session()

    let effects = session.model.handle(
        .launched(MobileLaunchInputs(environmentHost: "100.64.0.7", environmentPort: "7422")),
        env: session.env
    )

    let slot = MobileServerTarget(host: "100.64.0.7", port: 7422)
    #expect(effects.contains(.connect(slot)))
    #expect(effects.contains { effect in
        if case .storeTarget = effect { return true }
        return false
    } == false)
}

@Test("A stored launch target connects without being written back")
func storedLaunchTargetDoesNotPersist() {
    // Intent: an ordinary launch off the saved target connects and stores nothing, because
    //   the store already holds exactly that target.
    // Why it exists: persistence belongs to the Go gesture alone, so the launch path has
    //   no branch that decides when a write is worth making.
    var session = Session()

    let effects = session.model.handle(
        .launched(MobileLaunchInputs(storedHost: "mac.tailnet", storedPort: "9000")),
        env: session.env
    )

    #expect(effects.contains(.connect(MobileServerTarget(host: "mac.tailnet", port: 9000))))
    #expect(effects.contains { effect in
        if case .storeTarget = effect { return true }
        return false
    } == false)
}

@Test("A valid Go gesture saves its target")
func goGestureSavesItsTarget() {
    // Intent: the target the user submits in the app is the one later launches start from.
    // Why it exists: the Go gesture is now the only writer of the saved target, so nothing
    //   else in the model pins that the write still happens.
    var session = Session()
    _ = session.handle(.launched(MobileLaunchInputs(environmentHost: "100.64.0.7")))

    let effects = session.handle(.connectRequested(
        MobileTargetDraft(host: "mac.tailnet", port: "9000")
    ))

    #expect(effects.contains(.storeTarget(host: "mac.tailnet", port: "9000")))
}

@Test("A refused tape subscription ends the connection and a refused input does not")
func onlyTheSubscriptionRefusalEndsTheConnection() throws {
    // Intent: the subscription is what the connection is for, so its refusal ends the
    //   connection; any other refusal is the newest outcome on a stream still serving.
    // Why it exists: ending a serving connection over one refused keystroke would throw
    //   away exact replicated state the stream still holds.
    var session = Session()
    try session.reachServingStream()

    let strayId = JSONValue.string("stray")
    let stray = session.handle(.frameReceived(.response(JsonRpcResponse(
        id: strayId,
        error: JsonRpcError(code: -1, message: "no")
    ))))
    #expect(stray == [.redraw])

    let ended = session.handle(.frameReceived(.response(JsonRpcResponse(
        id: session.tapeRequestId.jsonValue,
        error: JsonRpcError(code: -1, message: "no")
    ))))
    #expect(ended.contains(.disconnect))
}

@Test("Only the exact string tape id can end the serving connection")
func onlyExactStringTapeIdMatchesTheSubscription() throws {
    // Intent: omitted, null, and foreign response ids remain ordinary unmatched replies;
    //   only the exact string id issued for the tape subscription ends the connection.
    // Why it exists: optional JSON identities let a missing stored tape id compare equal
    //   to a missing response id after teardown.
    var session = Session()
    try session.reachServingStream()

    for id: JSONValue? in [nil, .null, .string("foreign")] {
        let effects = session.handle(.frameReceived(.response(JsonRpcResponse(
            id: id,
            error: JsonRpcError(code: -1, message: "no")
        ))))
        #expect(effects == [.redraw], "\(String(describing: id))")
        #expect(session.model.projection(at: session.now).status.severity == .degraded)
    }

    let ended = session.handle(.frameReceived(.response(JsonRpcResponse(
        id: session.tapeRequestId.jsonValue,
        error: JsonRpcError(code: -1, message: "no")
    ))))
    #expect(ended.contains(.disconnect))
}

@Test("A pushed roster replaces the pane list and redraws")
func pushedRosterReplacesThePaneList() throws {
    // Intent: a `roster.event` notification makes the model's pane list exactly the list
    //   the server sent, and asks for a redraw so the sheet and the pill follow it.
    // Why it exists: the phone used to read its pane list once, at connect, so every pane
    //   opened, closed, or retitled afterwards stayed invisible until it reconnected.
    // Scenario: the user splits a pane on the Mac while the phone is attached.
    var session = Session()
    try session.reachServingStream()

    let effects = session.handle(.frameReceived(.notification(
        method: Methods.rosterEvent,
        params: roster(panes: [(201, "zsh"), (202, "vim")]).jsonValue
    )))

    #expect(effects == [.redraw])
    let projection = session.model.projection(at: session.now)
    #expect(projection.outline.groups.flatMap(\.tabs).flatMap(\.panes).map(\.paneId)
        == [paneId(201), paneId(202)])
    #expect(projection.outline.groups.flatMap(\.tabs).flatMap(\.panes).map(\.title.text)
        == ["zsh", "vim"])
}

@Test("The pane outline preserves roster order and states every row target")
func paneOutlinePreservesRosterOrderAndStatesTargets() throws {
    // Intent: the outline groups contiguous roster runs without sorting or dropping a pane,
    //   and each tab states the focused-or-first pane its row selects.
    // Why it exists: the UIKit shell has no test target, so grouping, reachability, and row
    //   targets must arrive as pure facts rather than being reconstructed by the table.
    // Scenario: two groups contain multi-pane and single-pane tabs, including one tab with
    //   no focused pane.
    var session = Session()
    try session.reachServingStream()
    let replacement = shapedRoster([
        RosterPane(group: 1, groupName: "Work", tab: 101, tabTitle: "Editor", pane: 201, paneTitle: "shell"),
        RosterPane(group: 1, groupName: "Work", tab: 101, tabTitle: "Editor", pane: 202, paneTitle: "code", isFocused: true),
        RosterPane(group: 1, groupName: "Work", tab: 102, tabTitle: "Logs", pane: 203, paneTitle: "tail"),
        RosterPane(group: 2, groupName: "Ops", tab: 103, tabTitle: "Deploy", pane: 204, paneTitle: "build"),
        RosterPane(group: 2, groupName: "Ops", tab: 103, tabTitle: "Deploy", pane: 205, paneTitle: "ship"),
    ])

    _ = session.handle(.frameReceived(.notification(
        method: Methods.rosterEvent,
        params: replacement.jsonValue
    )))

    let groups = session.model.projection(at: session.now).outline.groups
    #expect(groups.map(\.groupId) == [groupId(1), groupId(2)])
    #expect(groups.map(\.title.text) == ["Work", "Ops"])
    #expect(groups[0].tabs.map(\.tabId) == [tabId(101), tabId(102)])
    #expect(groups[1].tabs.map(\.tabId) == [tabId(103)])
    #expect(groups.flatMap(\.tabs).flatMap(\.panes).map(\.paneId)
        == [paneId(201), paneId(202), paneId(203), paneId(204), paneId(205)])
    #expect(groups[0].tabs[0].selectionPaneId == paneId(202))
    #expect(groups[0].tabs[1].selectionPaneId == paneId(203))
    #expect(groups[1].tabs[0].selectionPaneId == paneId(204))
    #expect(groups.flatMap(\.tabs).map(\.isExpandable) == [true, false, true])
}

@Test("The outline opens at the selected multi-pane tab and names it")
func paneOutlineLocatesTheSelectedPane() throws {
    var session = Session()
    try session.reachServingStream()
    let replacement = shapedRoster([
        RosterPane(group: 1, groupName: "W\u{2733}rk", tab: 101, tabTitle: "Ed\u{2733}tor", pane: 201, paneTitle: "sh\u{2733}ll", isFocused: true),
        RosterPane(group: 1, groupName: "W\u{2733}rk", tab: 101, tabTitle: "Ed\u{2733}tor", pane: 202, paneTitle: "code"),
    ])

    _ = session.handle(.frameReceived(.notification(
        method: Methods.rosterEvent,
        params: replacement.jsonValue
    )))

    let projection = session.model.projection(at: session.now)
    #expect(projection.outline.initiallyExpandedTabId == tabId(101))
    #expect(projection.selectedPaneTitle?.text == "sh\u{2733}\u{FE0E}ll")
}

@Test("The outline does not expand or name a pane it cannot locate")
func paneOutlineOmitsUnavailableLocation() throws {
    var session = Session()
    try session.reachServingStream()

    _ = session.handle(.frameReceived(.notification(
        method: Methods.rosterEvent,
        params: roster(panes: [(201, "only")]).jsonValue
    )))
    #expect(session.model.projection(at: session.now).outline.initiallyExpandedTabId == nil)

    _ = session.handle(.frameReceived(.notification(
        method: Methods.rosterEvent,
        params: roster(panes: [(202, "other"), (203, "third")]).jsonValue
    )))
    let projection = session.model.projection(at: session.now)
    #expect(projection.outline.initiallyExpandedTabId == nil)
    #expect(projection.selectedPaneTitle == nil)
}

@Test("The projection offers only prepared titles to the shell")
func projectionOffersPreparedTitles() throws {
    // Intent: every title the roster carries reaches the shell as display text, with a
    //   default-text variation base already stating its presentation and plain text intact.
    // Why it exists: the shell used to assign roster strings straight to UIKit labels, so
    //   nothing stood between a terminal-authored title and the color emoji face.
    var session = Session()
    try session.reachServingStream()

    _ = session.handle(.frameReceived(.notification(
        method: Methods.rosterEvent,
        params: roster(panes: [(201, "\u{2733} build"), (202, "vim")]).jsonValue
    )))

    let projection = session.model.projection(at: session.now)
    let panes = projection.outline.groups.flatMap(\.tabs).flatMap(\.panes)
    #expect(panes.map(\.title) == [
        MobileDisplayText(preparing: "\u{2733} build"),
        MobileDisplayText(preparing: "vim"),
    ])
    #expect(panes.map(\.title.text) == ["\u{2733}\u{FE0E} build", "vim"])
    #expect(projection.outline.groups.map(\.title) == [MobileDisplayText(preparing: "Work")])
    #expect(projection.outline.groups.flatMap(\.tabs).map(\.title)
        == [MobileDisplayText(preparing: "Tab")])
}

@Test("A roster without the selected pane changes the list only")
func rosterWithoutTheSelectedPaneLeavesTheStreamAlone() throws {
    // Intent: the pane the phone is reading disappearing from the roster changes the list
    //   and nothing else -- the selection stays and the tape stream is not torn down.
    // Why it exists: the tape stream reports its own pane's closure with an end record,
    //   and that is what drives recovery. A roster that also ended the connection would
    //   race that path and could end a stream still serving.
    var session = Session()
    try session.reachServingStream()

    let effects = session.handle(.frameReceived(.notification(
        method: Methods.rosterEvent,
        params: roster(panes: [(202, "vim")]).jsonValue
    )))

    #expect(effects == [.redraw])
    let projection = session.model.projection(at: session.now)
    #expect(projection.outline.groups.flatMap(\.tabs).flatMap(\.panes).map(\.paneId)
        == [paneId(202)])
    #expect(projection.selectedPaneId == session.pane)
}

@Test("Reconnect falls back when the preferred pane has left the roster")
func reconnectFallsBackToAnAvailablePane() throws {
    // Intent: reconnect resolves an available pane, presents it, and uses its tab for the
    //   New pane affordance when the retained preference is no longer in the roster.
    // Why it exists: a retained pane is presentation state, not permission to target a
    //   pane that the new connection did not attach.
    // Scenario: the Mac closes the preferred pane while the phone reconnects.
    var session = Session()
    try session.reachServingStream()
    _ = session.handle(.connectionEnded(.transport(.peerClosed)))
    _ = session.handle(.retryTimerFired)
    let fallback = paneId(202)

    let attached = session.handle(.attemptSucceeded(
        roster: roster(panes: [(202, "vim")]),
        serverVersion: "1.2.3"
    ))
    #expect(attached.contains(.attachPane(
        pane: fallback,
        resumesFromStoredCheckpoint: true
    )))
    _ = session.handle(.paneAttached(pane: fallback, cursor: nil))

    let projection = session.model.projection(at: session.now)
    #expect(projection.selectedPaneId == fallback)
    #expect(projection.canCreatePane)
    #expect(requests(session.handle(.newPaneRequested)) == [
        .paneSplit(target: .tab(tabId(101)), launch: nil, background: true),
    ])
}

@Test("New pane is offered only on a serving stream and permits one unanswered request")
func newPaneAvailabilityTracksServingStateAndPendingRequest() throws {
    // Intent: the affordance appears only when the phone can name its attached pane's tab,
    //   disappears while its split request is unanswered, and a second tap sends nothing.
    // Why it exists: the menu is rebuilt after it opens, so the model must prevent a stale
    //   item or a repeated tap from opening two panes.
    // Scenario: the user double-taps New pane, then the connection drops before the reply.
    var session = Session()
    #expect(session.model.projection(at: session.now).canCreatePane == false)
    try session.reachServingStream()
    #expect(session.model.projection(at: session.now).canCreatePane)

    let effects = session.handle(.newPaneRequested)
    #expect(requests(effects) == [
        .paneSplit(target: .tab(tabId(101)), launch: nil, background: true),
    ])
    #expect(session.model.projection(at: session.now).canCreatePane == false)
    #expect(session.handle(.newPaneRequested).isEmpty)

    _ = session.handle(.connectionEnded(.transport(.peerClosed)))
    #expect(session.model.projection(at: session.now).canCreatePane == false)
    _ = session.handle(.retryTimerFired)
    _ = session.handle(.attemptSucceeded(roster: roster(), serverVersion: "1.2.3"))
    _ = session.handle(.paneAttached(pane: session.pane, cursor: nil))
    #expect(session.model.projection(at: session.now).canCreatePane)

    var missingTab = Session()
    try missingTab.reachServingStream()
    _ = missingTab.handle(.frameReceived(.notification(
        method: Methods.rosterEvent,
        params: roster(panes: [(202, "vim")]).jsonValue
    )))
    #expect(missingTab.model.projection(at: missingTab.now).canCreatePane == false)
}

@Test("A refused New pane request reports the Mac reason and keeps serving")
func refusedNewPaneReoffersTheAffordance() throws {
    // Intent: a matching split refusal clears the pending request, reports its exact
    //   reason, and re-offers New pane without disconnecting the serving stream.
    // Why it exists: autosplit refusal is a local layout answer, not a connection failure.
    var session = Session()
    try session.reachServingStream()
    let requestId = try #require(sendRequestIds(session.handle(.newPaneRequested)).first)

    let effects = session.handle(.frameReceived(.response(JsonRpcResponse(
        id: requestId.jsonValue,
        error: JsonRpcError(code: -1, message: "no pane is large enough to split")
    ))))

    #expect(effects == [.redraw])
    let projection = session.model.projection(at: session.now)
    #expect(projection.status.text.contains("no pane is large enough to split"))
    #expect(projection.canCreatePane)
}

@Test("A successful New pane reply reconnects through the ordinary pane attach path")
func successfulNewPaneAttachesToTheCreatedPane() throws {
    // Intent: the pane id returned by autosplit becomes the preferred pane for the same
    //   reconnect and attach flow used by a pane picked from the list.
    // Why it exists: the split reply arrives before the phone can read the new pane, so it
    //   must reconnect instead of changing the live tape subscription in place.
    var session = Session()
    try session.reachServingStream()
    let requestId = try #require(sendRequestIds(session.handle(.newPaneRequested)).first)
    let createdPane = paneId(202)

    let replied = session.handle(.frameReceived(.response(JsonRpcResponse(
        id: requestId.jsonValue,
        result: .object(["pane": .object(["id": .string(createdPane.rawValue.uuidString)])])
    ))))
    #expect(replied.contains(.disconnect))
    #expect(replied.contains(.connect(session.target)))

    let connected = session.handle(.attemptSucceeded(
        roster: roster(panes: [(201, "zsh"), (202, "new")]),
        serverVersion: "1.2.3"
    ))
    #expect(connected.contains(.attachPane(
        pane: createdPane,
        resumesFromStoredCheckpoint: true
    )))
}

@Test("A New pane success without a readable pane reports instead of attaching")
func unreadableNewPaneReplyReoffersWithoutAttaching() throws {
    // Intent: a successful response that does not name a readable pane attaches to
    //   nothing, reports the malformed answer, and permits another request.
    // Why it exists: treating a malformed success as pane selection would reconnect with
    //   no valid destination and hide the protocol mismatch from the user.
    var session = Session()
    try session.reachServingStream()
    let requestId = try #require(sendRequestIds(session.handle(.newPaneRequested)).first)

    let effects = session.handle(.frameReceived(.response(JsonRpcResponse(
        id: requestId.jsonValue,
        result: .object(["pane": .object([:])])
    ))))

    #expect(effects == [.redraw])
    let projection = session.model.projection(at: session.now)
    #expect(projection.status.text.contains("unreadable pane"))
    #expect(projection.canCreatePane)
}

// MARK: - Driving

/// Drives one model with an explicit clock and explicit request ids.
private struct Session {
    var model = MobileSessionModel()
    var now: TimeInterval = 100
    let ids = RequestIds()
    let target = MobileServerTarget(host: "mac.tailnet", port: 7420)
    let pane = paneId(201)
    var tapeRequestId = MobileRequestId("unassigned")

    var env: MobileSessionEnv {
        MobileSessionEnv(now: now, newRequestId: ids.makeId)
    }

    mutating func handle(_ event: MobileSessionEvent) -> [MobileSessionEffect] {
        model.handle(event, env: env)
    }

    mutating func handle(_ event: MobileSessionGeometryEvent) -> [MobileSessionGeometryEffect] {
        model.handle(event, env: env)
    }

    /// Takes the model through the whole opening: launch, attempt, pane, subscription.
    mutating func reachServingStream() throws {
        let launched = handle(.launched(MobileLaunchInputs(environmentHost: target.host)))
        #expect(launched.contains(.connect(target)))
        let succeeded = handle(.attemptSucceeded(roster: roster(), serverVersion: "1.2.3"))
        #expect(succeeded.contains(.attachPane(pane: pane, resumesFromStoredCheckpoint: true)))
        let attached = handle(.paneAttached(pane: pane, cursor: nil))
        let subscription = try #require(attached.compactMap { effect -> MobileRequestId? in
            guard case .beginStream(let requestId, _) = effect else { return nil }
            return requestId
        }.first)
        tapeRequestId = subscription
    }
}

/// Hands out request ids a test can predict without the model reading any ambient source.
private final class RequestIds: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0

    func makeId() -> MobileRequestId {
        lock.withLock {
            issued += 1
            return MobileRequestId("request-\(issued)")
        }
    }
}

private extension MobileSessionEffect {
    /// Whether performing this effect is observable outside this phone: a socket write, a
    /// teardown, or a file. The rest only move pixels or arm a deadline.
    var leavesThePhone: Bool {
        switch self {
        case .connect, .disconnect, .storeTarget, .beginStream, .send, .flushCheckpoint:
            true
        case .attachPane, .applyRecord, .scrollViewport, .armRetryTimer, .cancelRetryTimer,
             .armCheckpointTimer, .driveSmokeInput, .redraw:
            false
        }
    }
}

private func resizes(_ effects: [MobileSessionGeometryEffect]) -> [IpcRequest] {
    effects.compactMap { effect in
        guard case .resizePane(_, let request) = effect else { return nil }
        return request
    }
}

private func resizeRequestIds(_ effects: [MobileSessionGeometryEffect]) -> [MobileRequestId] {
    effects.compactMap { effect in
        guard case .resizePane(let requestId, _) = effect else { return nil }
        return requestId
    }
}

/// Extracts ordinary request ids so a test can answer the exact request it caused.
private func sendRequestIds(_ effects: [MobileSessionEffect]) -> [MobileRequestId] {
    effects.compactMap { effect in
        guard case .send(let requestId, _) = effect else { return nil }
        return requestId
    }
}

/// One streamed tape record carrying the recorder's resize event, which is how the tape
/// states a pane's pinnedness mid-stream.
private func tapeResizeNotification(
    columns: Int,
    rows: Int,
    pinned: Bool
) -> MobileSessionEvent {
    tapeEventNotification(.object([
        "type": .string("resize"),
        "columns": .number(Double(columns)),
        "rows": .number(Double(rows)),
        "pinned": .bool(pinned),
    ]))
}

/// One streamed tape record carrying the given event object verbatim, so a test can state
/// the exact JSON the model's decode edge is handed.
private func tapeEventNotification(_ event: JSONValue) -> MobileSessionEvent {
    .frameReceived(.notification(
        method: Methods.paneTapeEvent,
        params: .object([
            "subscription": .string("subscription-1"),
            "records": .array([.object([
                "kind": .string("event"),
                "sequence": .number(1),
                "elapsedNanoseconds": .number(0),
                "event": event,
            ])]),
        ])
    ))
}

private func requests(_ effects: [MobileSessionEffect]) -> [IpcRequest] {
    effects.compactMap { effect in
        switch effect {
        case .send(_, let request), .beginStream(_, let request): request.request
        default: nil
        }
    }
}

private func grid(columns: Int, rows: Int) -> MobileSurfaceGrid {
    MobileSurfaceGrid(
        widthPixels: columns * 10,
        heightPixels: rows * 20,
        cellWidthPixels: 10,
        cellHeightPixels: 20
    )!
}

/// One group holding one selected tab, whose focused pane is the first of the named ones.
private func roster(panes: [(id: Int, title: String)] = [(201, "zsh")]) -> PaneRoster {
    PaneRoster(panes: panes.enumerated().map { index, pane in
        PaneRosterItem(
            groupId: GroupId(rawValue: UUID(uuidString: wireId(1))!),
            groupName: "Work",
            tabId: TabId(rawValue: UUID(uuidString: wireId(101))!),
            tabTitle: "Tab",
            paneId: paneId(pane.id),
            paneTitle: pane.title,
            chip: .terminal,
            isSelectedTab: true,
            isFocused: index == 0
        )
    })
}

/// One pane in a shaped roster fixture, with identity spelled as small stable integers.
private struct RosterPane {
    let group: Int
    let groupName: String
    let tab: Int
    let tabTitle: String
    let pane: Int
    let paneTitle: String
    var isFocused = false
}

/// Builds a roster whose order and hierarchy are explicit in the fixture list.
private func shapedRoster(_ panes: [RosterPane]) -> PaneRoster {
    PaneRoster(panes: panes.map { pane in
        PaneRosterItem(
            groupId: groupId(pane.group),
            groupName: pane.groupName,
            tabId: tabId(pane.tab),
            tabTitle: pane.tabTitle,
            paneId: paneId(pane.pane),
            paneTitle: pane.paneTitle,
            chip: .terminal,
            isSelectedTab: pane.tab == 101,
            isFocused: pane.isFocused
        )
    })
}

private func wireId(_ value: Int) -> String {
    "00000000-0000-0000-0000-" + String(format: "%012d", value)
}

private func paneId(_ value: Int) -> PaneId {
    PaneId(rawValue: UUID(uuidString: wireId(value))!)
}

/// Builds one reproducible group id in the same wire namespace as the roster fixture.
private func groupId(_ value: Int) -> GroupId {
    GroupId(rawValue: UUID(uuidString: wireId(value))!)
}

/// Builds one reproducible tab id in the same wire namespace as the roster fixture.
private func tabId(_ value: Int) -> TabId {
    TabId(rawValue: UUID(uuidString: wireId(value))!)
}
