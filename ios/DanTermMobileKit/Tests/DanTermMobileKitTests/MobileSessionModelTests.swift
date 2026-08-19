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

    session.now += 5
    #expect(session.handle(.appForegrounded).contains(.connect(session.target)))
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

    _ = session.handle(.surfaceChanged(MobileSurfaceFacts(
        nativeGrid: grid(columns: 40, rows: 12),
        pinned: true
    )))
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

    _ = session.handle(.connectionEnded(.transport(.peerClosed, phase: .established)))
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
        #expect(session.model.projection(at: session.now).isControlLatched)

        let effects = session.handle(event)
        #expect(requests(effects) == [.paneInput(pane: session.pane, input: input)])
        #expect(effects.contains(.redraw))
        #expect(session.model.projection(at: session.now).isControlLatched == false)
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
        #expect(session.model.projection(at: session.now).isControlLatched == false)
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
        id: session.tapeRequestId,
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
    #expect(projection.panes.map(\.paneId) == [paneId(201), paneId(202)])
    #expect(projection.panes.map(\.paneTitle) == ["zsh", "vim"])
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
    #expect(projection.panes.map(\.paneId) == [paneId(202)])
    #expect(projection.selectedPaneId == session.pane)
}

// MARK: - Driving

/// Drives one model with an explicit clock and explicit request ids.
private struct Session {
    var model = MobileSessionModel()
    var now: TimeInterval = 100
    let ids = RequestIds()
    let target = MobileServerTarget(host: "mac.tailnet", port: 7420)
    let pane = paneId(201)
    var tapeRequestId = JSONValue.null

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
        let subscription = try #require(attached.compactMap { effect -> JSONValue? in
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

    func makeId() -> JSONValue {
        lock.withLock {
            issued += 1
            return .string("request-\(issued)")
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
            isSelectedTab: true,
            isFocused: index == 0
        )
    })
}

private func wireId(_ value: Int) -> String {
    "00000000-0000-0000-0000-" + String(format: "%012d", value)
}

private func paneId(_ value: Int) -> PaneId {
    PaneId(rawValue: UUID(uuidString: wireId(value))!)
}
