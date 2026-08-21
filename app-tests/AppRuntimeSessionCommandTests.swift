// Command-interpreter coverage for terminal sessions and search scheduling.
import DanTermProtocol
import Foundation
import Testing
@testable import DanTerm

@MainActor
struct AppRuntimeSessionCommandTests {
    @Test("session creation forwards launch inputs and installs the returned session")
    func createSessionInstallsPortResult() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let sessionId = SessionId(rawValue: UUID())
        let paneId = PaneId(rawValue: UUID())

        runtime.perform(.createSession(
            sessionId: sessionId,
            paneId: paneId,
            cwd: "/tmp/worktree",
            command: "printf ready",
            launchCommand: "codex"
        ))

        let request = try #require(fixture.sessionRequests.first)
        #expect(fixture.sessionRequests.count == 1)
        #expect(request.workingDirectory == "/tmp/worktree")
        #expect(request.command == "printf ready")
        #expect(request.launchCommand == "codex")
        #expect(request.waitAfterCommand)
        #expect(request.environment.contains { key, value in
            key == EnvVars.pane && value == paneId.rawValue.uuidString
        })
        let host = try #require(runtime.paneHosts[paneId])
        #expect(host.session === fixture.session)
        #expect(host.wrapper.terminalSession === fixture.session)
        #expect(fixture.session.renderingAvailableValues == [true])
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.subscription] == 1)
    }

    @Test("launch input completion preserves the PTY rejection reason in the model")
    func launchInputCompletionPreservesReason() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let groupId = try #require(runtime.model.groups.first?.id)

        runtime.send(.createTab(
            inGroupId: groupId,
            position: .atGroupEnd,
            launch: LaunchSpec(cmd: "printf ready", cwd: nil, title: nil),
            background: false
        ))

        let completion = try #require(fixture.sessionRequests.first?.onLaunchInputCompletion)
        let paneId = try #require(selectedTab(in: runtime.model)?.paneTree.focusedPaneId)
        let sessionId = try #require(runtime.model.pane(paneId)?.session?.id)
        #expect(runtime.model.pane(owning: sessionId)?.session?.launchInput == .pending)

        completion(.rejected(.canonicalModeTimeout))

        #expect(runtime.model.pane(owning: sessionId)?.session?.launchInput == .rejected(
            .canonicalModeTimeout
        ))
    }

    @Test("a restored pane's session request carries the grid it was claimed at")
    func restoredPaneRequestsItsClaimedGrid() throws {
        // Intent: the grid a restored pane is claimed at rides its session request,
        //   so the child is spawned at that grid instead of being resized into it.
        // Why it exists: a request without it would launch the child at the shared
        //   default and only then submit the claim, which the child sees as a real
        //   winsize and the pane's tape records as a resize.
        // Scenario: spec-first -- the app restarts with a pane the phone claimed.
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let claimed = PaneId(rawValue: UUID())
        let unclaimed = PaneId(rawValue: UUID())

        runtime.bootstrapFromSnapshot(makeCommandSnapshot(
            paneId: claimed,
            splitWith: unclaimed,
            gridOverride: PaneGridOverrideSnapshot(columns: 60, rows: 30)
        ))

        #expect(fixture.sessionRequests.count == 2)
        #expect(fixture.sessionRequests[0].gridOverride == PaneGridOverride(columns: 60, rows: 30))
        #expect(fixture.sessionRequests[1].gridOverride == nil)
    }

    @Test("claiming and taking back a pane's grid both reach its live session")
    func gridOverrideReachesTheLiveSession() throws {
        // Intent: a claim written to the model reaches the pane already on screen,
        //   and a take-back reaches it as an explicit clear.
        // Why it exists: the override rides the per-pane config diff, which pushes
        //   only keys that changed. A claim the projection or the reconcile pass
        //   dropped would leave the pane running at its rectangle's grid with the
        //   model insisting otherwise.
        // Scenario: spec-first -- the phone claims a live pane, the user takes it back.
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.bootstrapFromSnapshot(makeCommandSnapshot(paneId: paneId))

        runtime.send(.setPaneGridOverride(
            paneId: paneId,
            grid: PaneGridOverride(columns: 60, rows: 30)!
        ))

        #expect(fixture.session.gridOverrides.last == PaneGridOverride(columns: 60, rows: 30))

        runtime.send(.clearPaneGridOverride(paneId: paneId))

        #expect(fixture.session.gridOverrides.last == .some(nil))
    }

    @Test("session input, focus, and immediate search commands reach the selected session")
    func sessionCommandsReachSession() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.installTerminalSession(fixture.session, paneId: paneId)

        runtime.perform(.sendText(paneId: paneId, text: "pasted"))
        runtime.perform(.sendInputText(paneId: paneId, text: "typed"))
        runtime.perform(.sendInputKey(
            paneId: paneId,
            key: .named(.up),
            mods: [.ctrl, .shift]
        ))
        runtime.perform(.sendInputWheel(
            paneId: paneId,
            direction: .up,
            column: 4,
            row: 2
        ))
        runtime.perform(.focusSession(paneId: paneId, focused: true))
        runtime.perform(.sendSearchNeedle(paneId: paneId, needle: "find"))
        runtime.perform(.sendSearchNavigate(paneId: paneId, direction: .previous))

        #expect(fixture.session.sentText == ["pasted"])
        #expect(fixture.session.sentInputText == ["typed"])
        let key = try #require(fixture.session.sentInputKeys.first)
        #expect(fixture.session.sentInputKeys.count == 1)
        #expect(key.key == .named(.up))
        #expect(key.modifiers == [.ctrl, .shift])
        let wheel = try #require(fixture.session.sentInputWheels.first)
        #expect(fixture.session.sentInputWheels.count == 1)
        #expect(wheel.direction == .up)
        #expect(wheel.column == 4)
        #expect(wheel.row == 2)
        #expect(fixture.session.focusedValues == [true])
        #expect(fixture.session.searchNeedles == ["find"])
        #expect(fixture.session.searchDirections.count == 1)
        if case .previous = fixture.session.searchDirections[0] {
        } else {
            Issue.record("expected previous search navigation")
        }
    }

    @Test("ending search cancels a pending short-needle delivery")
    func endSearchCancelsPendingNeedle() {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.installTerminalSession(fixture.session, paneId: paneId)

        runtime.perform(.sendSearchNeedle(paneId: paneId, needle: "go"))

        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == 1)
        #expect(fixture.session.searchNeedles.isEmpty)

        runtime.perform(.sendEndSearch(paneId: paneId))

        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == nil)
        #expect(fixture.session.searchNeedles.isEmpty)
        #expect(fixture.session.endSearchCount == 1)
    }

    // Intent: a burst of short needles holds one debounce and delivers only the last one.
    // Why it exists: this trailing-edge coalescing used to be the Debouncer's own
    // coverage; it belongs to the search needle, which is the only thing that promises it.
    // Scenario: a user types three one- and two-character needles inside the 300 ms window.
    @Test("a burst of short needles delivers only the last needle, once")
    func shortNeedleBurstDeliversOnlyTheLastNeedle() async {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.installTerminalSession(fixture.session, paneId: paneId)

        for needle in ["g", "go", "gp"] {
            runtime.perform(.sendSearchNeedle(paneId: paneId, needle: needle))
            #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == 1)
        }
        #expect(fixture.session.searchNeedles.isEmpty)

        // This sleep is meant to expire: it is well past the 300 ms window, so every
        // delivery that was ever going to happen has happened when the expectations run.
        try? await Task.sleep(for: .milliseconds(600))

        #expect(fixture.session.searchNeedles == ["gp"])
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == nil)
    }

    // Intent: clearing the needle delivers at once and retires the pending short needle.
    // Why it exists: an empty needle leaves search mode showing every match again, so a
    // superseded short needle arriving after it would re-filter a pane the user cleared.
    @Test("an empty needle delivers at once and drops a pending short needle")
    func emptyNeedleSupersedesPendingShortNeedle() async {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.installTerminalSession(fixture.session, paneId: paneId)

        runtime.perform(.sendSearchNeedle(paneId: paneId, needle: "go"))
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == 1)

        runtime.perform(.sendSearchNeedle(paneId: paneId, needle: ""))

        #expect(fixture.session.searchNeedles == [""])
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == nil)

        // Meant to expire: past the window the retired "go" would have fired in.
        try? await Task.sleep(for: .milliseconds(600))

        #expect(fixture.session.searchNeedles == [""])
    }

    // Intent: a needle of three or more characters delivers at once and retires the
    // pending short needle it grew out of.
    // Why it exists: the short needle is a prefix of the long one, so a late delivery
    // would leave the pane matching fewer characters than the user has typed.
    @Test("a long needle delivers at once and drops the short needle it grew from")
    func longNeedleSupersedesPendingShortNeedle() async {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.installTerminalSession(fixture.session, paneId: paneId)

        runtime.perform(.sendSearchNeedle(paneId: paneId, needle: "go"))
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == 1)

        runtime.perform(.sendSearchNeedle(paneId: paneId, needle: "goo"))

        #expect(fixture.session.searchNeedles == ["goo"])
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == nil)

        // Meant to expire: past the window the retired "go" would have fired in.
        try? await Task.sleep(for: .milliseconds(600))

        #expect(fixture.session.searchNeedles == ["goo"])
    }

    // Intent: a pane's session and its chrome enter and leave the runtime together.
    // Why it exists: they used to live in two tables written by different call sites,
    // so one could survive the other.
    // Scenario: create a pane through the command interpreter, then tear it down.
    @Test("pane teardown drops the session and the pane chrome together")
    func tearDownRemovesSessionAndChrome() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())

        runtime.perform(.createSession(
            sessionId: SessionId(rawValue: UUID()),
            paneId: paneId,
            cwd: nil,
            command: nil,
            launchCommand: nil
        ))

        #expect(runtime.paneSession(for: paneId) === fixture.session)
        #expect(runtime.findPaneWrapper(for: paneId) != nil)

        runtime.tearDownSession(paneId)

        #expect(runtime.paneSession(for: paneId) == nil)
        #expect(runtime.findPaneWrapper(for: paneId) == nil)
        #expect(runtime.paneHosts[paneId] == nil)
    }

    // Intent: the reconcile pass destroys a pane the model no longer has.
    // Why it exists: the reconciler selects panes from the runtime's live table, and
    // that table is now the pane records rather than a separate session map.
    @Test("reconcile tears down a pane that left the model")
    func reconcileTearsDownAbsentPane() {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.installTerminalSession(fixture.session, paneId: paneId)

        runtime.reconcileSessionExistence()

        #expect(runtime.paneHosts[paneId] == nil)
    }

    // Intent: replacing the whole session tears every live pane down through the same
    // body the per-pane path uses -- record, replay file, and scheduled search work.
    // Why it exists: the whole-session path used to repeat that body inline and omit
    // the search debouncer, so a restore during a short needle's debounce left an armed
    // owner alive past the session it belonged to.
    // Scenario: a restored pane is mid-debounce on a two-character needle when a second
    // restore lands.
    @Test("a whole-session restore tears down every live pane and its scheduled work")
    func wholeSessionRestoreTearsDownLivePanes() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let livePaneId = PaneId(rawValue: UUID())
        let replacementPaneId = PaneId(rawValue: UUID())

        runtime.bootstrapFromSnapshot(
            makeCommandSnapshot(paneId: livePaneId, scrollback: "restored history\n")
        )
        let replayPath = try #require(fixture.sessionRequests.first?.environment.first {
            $0.0 == "DANTERM_RESTORE_SCROLLBACK_FILE"
        }?.1)
        #expect(FileManager.default.fileExists(atPath: replayPath))
        runtime.perform(.sendSearchNeedle(paneId: livePaneId, needle: "go"))
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == 1)

        runtime.bootstrapFromSnapshot(makeCommandSnapshot(paneId: replacementPaneId))

        #expect(runtime.paneHosts[livePaneId] == nil)
        #expect(runtime.paneHosts[replacementPaneId] != nil)
        #expect(FileManager.default.fileExists(atPath: replayPath) == false)
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == nil)
        #expect(fixture.session.searchNeedles.isEmpty)
    }

    // Intent: search work exists only for a pane that exists.
    // Why it exists: the debouncer and its scheduling token used to live in runtime
    // tables keyed by pane id, so a needle addressed to no live pane armed an owner
    // that no teardown would ever reach.
    @Test("a short needle for a pane that is not installed arms no scheduled work")
    func shortNeedleForAbsentPaneArmsNothing() {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }

        runtime.perform(.sendSearchNeedle(paneId: PaneId(rawValue: UUID()), needle: "go"))

        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == nil)
        #expect(fixture.session.searchNeedles.isEmpty)
    }

    // Intent: a debounced needle reaches the pane it was typed into, and only that pane.
    // Why it exists: the pending closure used to re-read the pane's session from a table
    // when it fired, and restore reuses pane ids, so a needle armed by a discarded pane
    // could be delivered into the session that replaced it.
    // Scenario: a short needle is still debouncing when a restore replaces the pane under
    // the same pane id, and the replacement pane then gets a short needle of its own.
    @Test("a needle pending on a discarded pane never reaches the pane that reuses its id")
    func pendingNeedleNeverReachesReusedPaneId() async {
        let discarded = RecordingTerminalSession()
        let replacement = RecordingTerminalSession()
        let fixture = RecordingAppRuntimePorts()
        fixture.queuedSessions = [discarded, replacement]
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())

        runtime.bootstrapFromSnapshot(makeCommandSnapshot(paneId: paneId))
        runtime.perform(.sendSearchNeedle(paneId: paneId, needle: "go"))
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == 1)

        runtime.bootstrapFromSnapshot(makeCommandSnapshot(paneId: paneId))
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == nil)
        runtime.perform(.sendSearchNeedle(paneId: paneId, needle: "up"))

        // Past the 300ms short-needle debounce, so a delivery that was going to happen
        // has happened. The replacement's own needle arriving is what proves the wait
        // is long enough for the discarded one to have arrived too.
        try? await Task.sleep(for: .milliseconds(600))

        #expect(replacement.searchNeedles == ["up"])
        #expect(discarded.searchNeedles.isEmpty)
    }

    // Intent: a restore that fails while it builds its panes changes nothing about the
    // panes that were live before it, and leaves no staged replay file behind.
    // Why it exists: staging builds whole pane records now, and a discarded record can
    // carry the same pane id as a live pane. Destroying one through the live per-pane path
    // would reach into that live pane and end its tape-follow streams.
    // Scenario: a pane is live with an open follow stream when a two-pane restore stages a
    // record under that same pane id and then runs out of sessions on its second pane.
    @Test("a restore that fails while building leaves live panes and their follow streams alone")
    func failedRestoreLeavesLivePanesUntouched() async throws {
        let live = RecordingTerminalSession()
        let stagedSession = RecordingTerminalSession()
        live.tapeOpening = makeEmptyPaneTapeOpening()
        let fixture = RecordingAppRuntimePorts()
        fixture.queuedSessions = [live, stagedSession]
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.bootstrapFromSnapshot(makeCommandSnapshot(paneId: paneId))

        let follow = try CommandIpcConnectionFixture()
        defer {
            follow.connection.close()
            follow.closePeer()
        }
        let followId = UUID()
        follow.remember(reqId: followId, rpcId: .number(1))
        runtime.registerIpcConnection(follow.connection, for: followId)
        runtime.perform(.streamPaneTape(
            reqId: followId,
            paneId: paneId,
            capture: .follow,
            start: .now,
            policy: .raw
        ))
        _ = try follow.readResponse()
        // The stream is registered only once the start reply's completion hops back to the
        // main queue, so the restore below must not run before that has happened.
        try await Task.sleep(for: .milliseconds(200))

        // One more session, so the restore stages its first pane and then fails on its second.
        let stagedRequestIndex = fixture.sessionRequests.count
        fixture.sessionsBeforeFailure = stagedRequestIndex + 1
        runtime.bootstrapFromSnapshot(makeCommandSnapshot(
            paneId: paneId,
            scrollback: "staged history\n",
            splitWith: PaneId(rawValue: UUID())
        ))

        let stagedReplayPath = try #require(
            fixture.sessionRequests[stagedRequestIndex].environment.first {
                $0.0 == "DANTERM_RESTORE_SCROLLBACK_FILE"
            }?.1
        )
        #expect(stagedSession.tearDownCount == 1, "the staged record must be destroyed")
        #expect(FileManager.default.fileExists(atPath: stagedReplayPath) == false)
        #expect(runtime.paneHosts[paneId]?.session === live)
        runtime.perform(.sendText(paneId: paneId, text: "still usable"))
        #expect(live.sentText == ["still usable"])
        #expect(
            follow.hasReadableData() == false,
            "discarding a staged record must not end a live pane's follow stream"
        )
        #expect(live.cancelledTapeNotices == 0)
    }

    // Intent: a pane installed under a reused pane id gets the visibility push its own
    // state calls for.
    // Why it exists: the last pushed visibility used to live in a runtime table that pane
    // teardown left behind, so the predecessor's entry suppressed the successor's push and
    // the new session never learned it was visible.
    @Test("a pane installed under a reused id receives its own visibility push")
    func reusedPaneIdReceivesVisibilityPush() {
        let restored = RecordingTerminalSession()
        let replacement = RecordingTerminalSession()
        let fixture = RecordingAppRuntimePorts()
        fixture.queuedSessions = [restored]
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())

        runtime.bootstrapFromSnapshot(makeCommandSnapshot(paneId: paneId))
        #expect(restored.visibleValues == [true])

        runtime.tearDownSession(paneId)
        runtime.installTerminalSession(replacement, paneId: paneId)
        runtime.syncPaneVisibility()

        #expect(replacement.visibleValues == [true])
    }
}
