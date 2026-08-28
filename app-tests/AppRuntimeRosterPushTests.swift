// Runtime coverage for the pushed pane roster over real sockets: which reconcile
// paths deliver a roster, which model changes deliver none, and how a subscription
// begins and ends.
//
// The roster's own shape and the model projection behind it are proved in the
// protocol and core suites; this file is only about delivery.
import Darwin
import DanTermProtocol
import Foundation
import Testing
@testable import DanTerm

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppRuntimeRosterPushTests {
    @Test("an inline reconcile pushes the roster and a non-roster change pushes nothing")
    func inlineReconcilePushesOnlyRosterChanges() async throws {
        // Intent: the inline reconcile arm is a delivery path, and the comparison it
        //   makes is over roster state alone.
        // Why it exists: the pure projection stays green whether or not the runtime
        //   ever calls it, so only a socket can say the hook is wired -- and a runtime
        //   that pushed on every reconcile would flood a phone with identical rosters.
        // Scenario: a phone subscribes, a tab is created, and a todo is added.
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        subscribe(wire, rpcId: .number(1), runtime: runtime)
        #expect(try await wire.readResponseAsync().result == PaneRoster(panes: []).jsonValue)

        runtime.send(.createTabInSelectedGroup())

        let created = try requireRoster(await wire.readNotificationAsync())
        #expect(created.panes.count == 1)

        // A todo is not roster state, so the next roster on this wire must be the one
        // the following split produces -- not a repeat of the roster above.
        let tabId = try #require(runtime.model.groups.first?.tabs.first?.id)
        runtime.send(.addTodo(owner: .tab(tabId), text: TodoText("ship it")!))
        #expect(wire.hasReadableData() == false, "a todo must not move the roster")

        let paneId = try #require(created.panes.first?.paneId)
        runtime.send(.splitPane(paneId: paneId, direction: .horizontal))

        #expect(try requireRoster(await wire.readNotificationAsync()).panes.count == 2)
    }

    @Test("a coalesced title burst arrives as one roster")
    func coalescedTitleBurstPushesOnce() async throws {
        // Intent: the coalescing sweep is the second delivery path, and a burst that
        //   one sweep collapses produces exactly one push.
        // Why it exists: a shell rewrites its title on every prompt, so a push per
        //   report would put the roster stream at the mercy of the noisiest pane.
        // Scenario: a pane reports two titles inside one reconcile window.
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        subscribe(wire, rpcId: .number(1), runtime: runtime)
        _ = try await wire.readResponseAsync()
        runtime.send(.createTabInSelectedGroup())
        let created = try requireRoster(await wire.readNotificationAsync())
        let paneId = try #require(created.panes.first?.paneId)
        let sessionId = try #require(runtime.model.pane(paneId)?.session?.id)

        runtime.send(.sessionReport(sessionId: sessionId, report: .title("building")))
        runtime.send(.sessionReport(sessionId: sessionId, report: .title("vim")))
        #expect(wire.hasReadableData() == false, "a title report defers its sweep")

        let swept = try requireRoster(await wire.readNotificationAsync())
        #expect(swept.panes.map(\.paneTitle) == ["vim"])

        // The burst's second push, if there were one, would arrive here instead of the
        // split's roster.
        runtime.send(.splitPane(paneId: paneId, direction: .horizontal))
        #expect(try requireRoster(await wire.readNotificationAsync()).panes.count == 2)
    }

    @Test("attaching an agent pushes a roster and its activity alone pushes none")
    func agentAttachPushesRosterAndActivityDoesNot() async throws {
        // Intent: an agent arriving on a pane reaches a subscriber as a new roster,
        //   and the activity that agent then reports reaches nobody.
        // Why it exists: the chip is what a phone draws to say which agent a pane is
        //   running, so a silent attach leaves the phone showing a plain terminal for
        //   as long as nothing else moves -- while a push per activity report would
        //   put the roster stream back at the mercy of a busy agent.
        // Scenario: a phone subscribes, an agent attaches to the one pane, and the
        //   agent then reports that it is waiting.
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        subscribe(wire, rpcId: .number(1), runtime: runtime)
        _ = try await wire.readResponseAsync()
        runtime.send(.createTabInSelectedGroup())
        let created = try requireRoster(await wire.readNotificationAsync())
        #expect(created.panes.map(\.chip) == [.terminal])
        let paneId = try #require(created.panes.first?.paneId)
        let sessionId = try #require(runtime.model.pane(paneId)?.session?.id)
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))

        runtime.send(.sessionReport(sessionId: sessionId, report: .agentAttached(agent)))

        #expect(try requireRoster(await wire.readNotificationAsync()).panes.map(\.chip) == [.claude])

        runtime.send(.sessionReport(
            sessionId: sessionId,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        ))
        // An activity report defers its sweep, so this wait is meant to expire: it is
        // far longer than the coalesce window, and a roster the sweep pushed would be
        // readable by the time it ends.
        try await Task.sleep(for: .milliseconds(500))
        #expect(wire.hasReadableData() == false, "agent activity must not move the roster")

        runtime.send(.sessionReport(sessionId: sessionId, report: .agentDetached(agent)))

        #expect(try requireRoster(await wire.readNotificationAsync()).panes.map(\.chip) == [.terminal])
    }

    @Test("committing a restore pushes the restored roster")
    func restoreCommitPushesRoster() async throws {
        // Intent: the restore commit is the third delivery path.
        // Why it exists: a restore replaces the whole model without going through
        //   update(), so a subscriber would otherwise keep rendering panes that the
        //   Mac no longer has.
        // Scenario: a recovered session is committed while a phone is subscribed.
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let wire = try CommandIpcConnectionFixture()
        defer {
            wire.connection.close()
            wire.closePeer()
        }
        subscribe(wire, rpcId: .number(1), runtime: runtime)
        _ = try await wire.readResponseAsync()
        let paneId = PaneId(rawValue: UUID())

        runtime.bootstrapFromTestSnapshot(makeCommandSnapshot(paneId: paneId))

        let restored = try requireRoster(await wire.readNotificationAsync())
        #expect(restored.panes.map(\.paneId) == [paneId])
        let tabId = try #require(runtime.model.selectedTabId)
        runtime.send(.addTodo(owner: .tab(tabId), text: TodoText("no roster change")!))
        #expect(wire.hasReadableData() == false, "restore must push its changed roster once")
    }

    @Test("a closed connection retires only its own subscription")
    func closedConnectionRetiresOnlyItsOwnSubscription() async throws {
        // Intent: retiring one subscriber leaves every sibling receiving.
        // Why it exists: one phone dropping off the tailnet must not silence the
        //   roster for the others still holding sockets.
        // Scenario: two subscribers, one of which loses its connection.
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let leaving = try CommandIpcConnectionFixture()
        let staying = try CommandIpcConnectionFixture()
        defer {
            for fixture in [leaving, staying] {
                fixture.connection.close()
                fixture.closePeer()
            }
        }
        subscribe(leaving, rpcId: .number(1), runtime: runtime)
        subscribe(staying, rpcId: .number(2), runtime: runtime)
        _ = try await leaving.readResponseAsync()
        _ = try await staying.readResponseAsync()
        let subscribed = runtime.schedulingLifecycle.captureOwnerCensus()[.subscription] ?? 0

        runtime.ipcConnectionClosed(leaving.connection.id)
        // Read before the tab exists: creating one arms a pane's own subscription and
        // would hide the one this close was supposed to retire.
        let remaining = runtime.schedulingLifecycle.captureOwnerCensus()[.subscription] ?? 0
        runtime.send(.createTabInSelectedGroup())

        #expect(try requireRoster(await staying.readNotificationAsync()).panes.count == 1)
        #expect(leaving.hasReadableData() == false, "a retired subscriber gets no roster")
        #expect(remaining == subscribed - 1)
    }

    @Test("a repeat subscribe resets only that connection's delivery baseline")
    func repeatSubscribeResetsOnlyItsOwnBaseline() async throws {
        // Intent: a connection holds at most one subscription however many times it
        //   asks, and each repeat still answers with the current roster.
        // Why it exists: the wire carries no subscription id, so nothing but this
        //   idempotence stops a client that re-sends its bootstrap from doubling every
        //   later roster it receives.
        // Scenario: a phone re-sends its subscribe while a title sweep is pending.
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let observer = try CommandIpcConnectionFixture()
        let wire = try CommandIpcConnectionFixture()
        defer {
            for fixture in [observer, wire] {
                fixture.connection.close()
                fixture.closePeer()
            }
        }
        subscribe(observer, rpcId: .number(0), runtime: runtime)
        subscribe(wire, rpcId: .number(1), runtime: runtime)
        _ = try await observer.readResponseAsync()
        #expect(try await wire.readResponseAsync().id == .number(1))
        runtime.send(.createTabInSelectedGroup())
        _ = try await observer.readNotificationAsync()
        let created = try requireRoster(await wire.readNotificationAsync())
        let paneId = try #require(created.panes.first?.paneId)
        let sessionId = try #require(runtime.model.pane(paneId)?.session?.id)

        runtime.send(.sessionReport(sessionId: sessionId, report: .title("vim")))
        subscribe(wire, rpcId: .number(2), runtime: runtime)
        let repeated = try requireRoster(await wire.readResponseAsync().result)
        #expect(repeated.panes.map(\.paneTitle) == ["vim"])

        // The observer proves the pending sweep finished before a later roster is
        // produced. If the repeat reply did not reset this connection's baseline, its
        // duplicate title roster will be read below instead of the split roster.
        _ = try requireRoster(await observer.readNotificationAsync())
        runtime.send(.splitPane(paneId: paneId, direction: .horizontal))

        #expect(try requireRoster(await wire.readNotificationAsync()).panes.count == 2)
    }

    @Test("a new subscriber's bootstrap does not swallow a pending change")
    func bootstrapDoesNotSwallowPendingChange() async throws {
        // Intent: the baseline is the last reconciled roster, so answering a newcomer
        //   leaves the change a pending sweep still owes the existing subscribers.
        // Why it exists: a baseline advanced at subscribe time would make the roster a
        //   subscriber holds silently wrong for as long as nothing else changed.
        // Scenario: a second phone connects inside the reconcile window opened by a
        //   title report the first phone has not been told about yet.
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let first = try CommandIpcConnectionFixture()
        let second = try CommandIpcConnectionFixture()
        defer {
            for fixture in [first, second] {
                fixture.connection.close()
                fixture.closePeer()
            }
        }
        subscribe(first, rpcId: .number(1), runtime: runtime)
        _ = try await first.readResponseAsync()
        runtime.send(.createTabInSelectedGroup())
        let created = try requireRoster(await first.readNotificationAsync())
        let paneId = try #require(created.panes.first?.paneId)
        let sessionId = try #require(runtime.model.pane(paneId)?.session?.id)

        runtime.send(.sessionReport(sessionId: sessionId, report: .title("vim")))
        subscribe(second, rpcId: .number(2), runtime: runtime)
        #expect(try requireRoster(await second.readResponseAsync().result).panes.map(\.paneTitle) == ["vim"])

        #expect(try requireRoster(await first.readNotificationAsync()).panes.map(\.paneTitle) == ["vim"])
        runtime.send(.splitPane(paneId: paneId, direction: .horizontal))

        #expect(try requireRoster(await second.readNotificationAsync()).panes.count == 2)
    }
}

/// Registers one fixture's socket and performs the subscribe command against it, which
/// is the pair the IPC server does for a `roster` request.
@MainActor
private func subscribe(
    _ fixture: CommandIpcConnectionFixture,
    rpcId: JSONValue,
    runtime: AppRuntime
) {
    let reqId = UUID()
    fixture.remember(reqId: reqId, rpcId: rpcId)
    runtime.registerIpcConnection(fixture.connection, for: reqId)
    runtime.perform(.subscribeRoster(reqId: reqId, roster: paneRoster(in: runtime.model)))
}

private func requireRoster(_ notification: JsonRpcRequest) throws -> PaneRoster {
    #expect(notification.method == Methods.rosterEvent)
    return try #require(PaneRoster(jsonValue: notification.params ?? .null))
}

private func requireRoster(_ result: JSONValue?) throws -> PaneRoster {
    try #require(PaneRoster(jsonValue: result ?? .null))
}
