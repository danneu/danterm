// Behavioral tests for the rule that a hook may assert a wait began but only
// delivered user input ends it. Covers the pure half: generation renewal, the
// retraction guard, and the silence of a retraction. The producer of the input
// occurrence and its transport are proved in their own layers.
import Foundation
import DanTermProtocol
import Testing

@testable import DanTermCore

struct AgentWaitRetractionTests {
    /// Attaches an agent to the focused pane of a freshly created second tab and
    /// returns everything the tests below address it by.
    private func makeAttachedPane(
        kind: String = "claude",
        sessionId agentSessionId: String = "session-1"
    ) throws -> (model: AppModel, paneId: PaneId, session: SessionId, agent: AgentSession) {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let agent = try #require(AgentSession(kind: kind, sessionId: agentSessionId))
        let session = sessionId(for: paneId, in: model)
        update(&model, .sessionReport(sessionId: session, report: .agentAttached(agent)))
        return (model, paneId, session, agent)
    }

    /// The generation the pane's agent is currently waiting on, or nil when it
    /// is not waiting -- the same live read the runtime makes at input origin.
    private func currentWaitGeneration(
        _ model: AppModel,
        _ paneId: PaneId
    ) -> AgentWaitGeneration? {
        model.pane(paneId)?.session?.agent.currentWaitGeneration
    }

    /// Dispatches one `pane.input` request against `paneId`, the way the CLI does.
    private func paneInput(
        _ model: inout AppModel,
        paneId: PaneId,
        params: [String: JSONValue]
    ) throws -> [Command] {
        var params = params
        params["pane"] = .string(paneId.rawValue.uuidString)
        let request = try IpcRequest.decode(
            method: IpcRequestMethod.paneInput.rawValue,
            params: .object(params)
        )
        return update(&model, .ipcRequest(reqId: UUID(), caller: .local, request: request))
    }

    // Intent: input delivered to a waiting pane leaves its agent attached with
    //   no reported activity, so its agent mark goes quiet and its alert bit is
    //   left where it was.
    // Why it exists: dismissing an AskUserQuestion with Esc emits no hook event
    //   at all, so a pane pinned at `waiting` claimed the agent needed the user
    //   long after the user had dealt with it.
    // Scenario: Claude reports `waiting`, the user presses Escape, and the key
    //   reaches the child.
    @Test("delivered input retracts the wait it was submitted against")
    func deliveredInputRetractsTheWait() throws {
        var (model, paneId, session, agent) = try makeAttachedPane()
        update(&model, .sessionReport(
            sessionId: session,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        ))
        #expect(paneAgentMark(agent: model.pane(paneId)!.session!.agent) == .waiting)
        let generation = try #require(currentWaitGeneration(model, paneId))

        update(&model, .sessionReport(
            sessionId: session,
            report: .userInputDelivered(waitGeneration: generation)
        ))

        #expect(attachedAgent(model.pane(paneId)?.session?.agent ?? .none)?.session == agent)
        #expect(attachedAgent(model.pane(paneId)?.session?.agent ?? .none)?.activity == nil)
        #expect(paneAgentMark(agent: model.pane(paneId)!.session!.agent) == .quiet)
        // Retraction speaks for the agent alone; the pane's alert bit is not
        // its to touch.
        #expect(unreadAlertTally(for: model).byPane[paneId] == nil)
    }

    // Intent: retraction is silent -- it emits no command, raises no alert, and
    //   clears none.
    // Why it exists: input tells us the wait ended, not what the agent does
    //   next, so a retraction that spoke would be inventing agent state, and one
    //   that cleared alerts would take over a decision `alertClearMode` owns.
    @Test("retraction emits no commands and leaves unread alerts alone")
    func retractionIsSilent() throws {
        var model = makeModel()
        createTab(&model)
        let backgroundPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        createTab(&model)
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let session = sessionId(for: backgroundPaneId, in: model)
        update(&model, .sessionReport(sessionId: session, report: .agentAttached(agent)))
        update(&model, .sessionReport(
            sessionId: session,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        ))
        #expect(model.alerts.count == 1)
        let generation = try #require(currentWaitGeneration(model, backgroundPaneId))

        let commands = update(&model, .sessionReport(
            sessionId: session,
            report: .userInputDelivered(waitGeneration: generation)
        ))

        #expect(commands.isEmpty)
        #expect(model.alerts.count == 1)
    }

    // Intent: input changes no activity other than a matching wait.
    // Why it exists: typing into a pane is not evidence about what its agent is
    //   doing, so anything but the wait it answers must survive untouched.
    @Test("working, idle, and unreported activity survive delivered input")
    func otherActivitiesAreUnaffected() throws {
        for activity: AgentActivity? in [nil, .working, .idle] {
            var (model, paneId, session, agent) = try makeAttachedPane()
            if let activity {
                update(&model, .sessionReport(
                    sessionId: session,
                    report: .agentActivityChanged(session: agent, activity: activity)
                ))
            }

            let commands = update(&model, .sessionReport(
                sessionId: session,
                report: .userInputDelivered(waitGeneration: AgentWaitGeneration(rawValue: 1))
            ))

            #expect(commands.isEmpty)
            #expect(attachedAgent(model.pane(paneId)?.session?.agent ?? .none)?.activity == activity)
        }
    }

    // Intent: retraction is session-scoped -- input addressed to one pane cannot
    //   end another pane's wait.
    // Why it exists: the occurrence travels keyed by session id, and nothing
    //   below the reducer re-derives which pane the user typed into.
    @Test("input to one pane leaves another pane's wait standing")
    func retractionDoesNotCrossPanes() throws {
        var model = makeModel()
        createTab(&model)
        let otherPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        createTab(&model)
        let typedPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        for paneId in [otherPaneId, typedPaneId] {
            let session = sessionId(for: paneId, in: model)
            update(&model, .sessionReport(sessionId: session, report: .agentAttached(agent)))
            update(&model, .sessionReport(
                sessionId: session,
                report: .agentActivityChanged(session: agent, activity: .waiting)
            ))
        }
        let generation = try #require(currentWaitGeneration(model, typedPaneId))

        update(&model, .sessionReport(
            sessionId: sessionId(for: typedPaneId, in: model),
            report: .userInputDelivered(waitGeneration: generation)
        ))

        #expect(currentWaitGeneration(model, typedPaneId) == nil)
        #expect(currentWaitGeneration(model, otherPaneId) != nil)
    }

    // Intent: an agent that replaced the one the user answered keeps its own
    //   wait, whatever generation the older input carries.
    // Why it exists: attaching resets activity, so a stale occurrence arriving
    //   after a relaunch must not speak for the new session.
    @Test("a replaced agent session keeps its wait")
    func retractionDoesNotReachAReplacedSession() throws {
        var (model, paneId, session, agent) = try makeAttachedPane()
        update(&model, .sessionReport(
            sessionId: session,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        ))
        let staleGeneration = try #require(currentWaitGeneration(model, paneId))

        let replacement = try #require(AgentSession(kind: "claude", sessionId: "session-2"))
        update(&model, .sessionReport(sessionId: session, report: .agentAttached(replacement)))
        update(&model, .sessionReport(
            sessionId: session,
            report: .agentActivityChanged(session: replacement, activity: .waiting)
        ))

        update(&model, .sessionReport(
            sessionId: session,
            report: .userInputDelivered(waitGeneration: staleGeneration)
        ))

        #expect(currentWaitGeneration(model, paneId) != nil)
        #expect(attachedAgent(model.pane(paneId)?.session?.agent ?? .none)?.session == replacement)
    }

    // Intent: a wait raised while an input was already on its way survives that
    //   input's later delivery.
    // Why it exists: descriptor completion can reach the model after the child's
    //   next hook has raised a new wait, so an unqualified late occurrence would
    //   erase a question the user has not even seen.
    // Scenario: the user answers one question, and Claude asks the next one
    //   before the answering keystroke finishes crossing the PTY.
    @Test("a wait raised after the input began is not retracted by it")
    func aLaterWaitOutlivesAnEarlierInput() throws {
        var (model, paneId, session, agent) = try makeAttachedPane()
        update(&model, .sessionReport(
            sessionId: session,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        ))
        let originGeneration = try #require(currentWaitGeneration(model, paneId))

        update(&model, .sessionReport(
            sessionId: session,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        ))
        let renewedGeneration = try #require(currentWaitGeneration(model, paneId))
        #expect(renewedGeneration != originGeneration)

        update(&model, .sessionReport(
            sessionId: session,
            report: .userInputDelivered(waitGeneration: originGeneration)
        ))

        #expect(currentWaitGeneration(model, paneId) == renewedGeneration)
    }

    // Intent: renewing a wait that is already visible raises no second alert.
    // Why it exists: every admitted wait mints a fresh generation, so the model
    //   now differs on a report that changes nothing the user can see. The alert
    //   has to follow the visible transition, not the model diff.
    @Test("renewing an already visible wait emits no second alert")
    func renewalRaisesNoSecondAlert() throws {
        var model = makeModel()
        createTab(&model)
        let backgroundPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        createTab(&model)
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let session = sessionId(for: backgroundPaneId, in: model)
        update(&model, .sessionReport(sessionId: session, report: .agentAttached(agent)))
        let first = update(&model, .sessionReport(
            sessionId: session,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        ))
        #expect(first.isEmpty == false)

        let renewal = update(&model, .sessionReport(
            sessionId: session,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        ))

        #expect(renewal.isEmpty)
        #expect(model.alerts.count == 1)
    }

    // Intent: a `working` report after a retraction attaches normally, and a
    //   repeated input retracts nothing further.
    // Why it exists: retraction returns the agent to "attached, nothing
    //   reported" rather than latching a DanTerm-owned state, so the next
    //   genuine hook report is the one that re-establishes truth.
    @Test("the next hook report lands normally and repeated input is idempotent")
    func retractionIsNotSticky() throws {
        var (model, paneId, session, agent) = try makeAttachedPane()
        update(&model, .sessionReport(
            sessionId: session,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        ))
        let generation = try #require(currentWaitGeneration(model, paneId))
        update(&model, .sessionReport(
            sessionId: session,
            report: .userInputDelivered(waitGeneration: generation)
        ))

        let repeated = update(&model, .sessionReport(
            sessionId: session,
            report: .userInputDelivered(waitGeneration: generation)
        ))
        #expect(repeated.isEmpty)
        #expect(attachedAgent(model.pane(paneId)?.session?.agent ?? .none)?.activity == nil)

        update(&model, .sessionReport(
            sessionId: session,
            report: .agentActivityChanged(session: agent, activity: .working)
        ))
        #expect(attachedAgent(model.pane(paneId)?.session?.agent ?? .none)?.activity == .working)
    }

    // Intent: the predicate the runtime may use as a pre-`update()` fast path
    //   agrees with the reducer on every case, so removing that fast path can
    //   change nothing observable.
    // Why it exists: a gate with a second rule of its own would be behavior
    //   hiding outside the pure core.
    @Test("the retraction predicate decides exactly what the reducer does")
    func predicateAndReducerAgree() throws {
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        var waiting = SessionModel(id: SessionId())
        reduceSession(&waiting, report: .agentAttached(agent))
        reduceSession(
            &waiting,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        )
        let live = try #require({ () -> AgentWaitGeneration? in
            guard case .attached(_, .waiting(let generation)) = waiting.agent else { return nil }
            return generation
        }())
        let stale = AgentWaitGeneration(rawValue: live.rawValue &+ 1)

        var attachedIdle = SessionModel(id: SessionId())
        reduceSession(&attachedIdle, report: .agentAttached(agent))

        let cases: [(AgentLifecycle, AgentWaitGeneration?)] = [
            (waiting.agent, live),
            (waiting.agent, stale),
            (waiting.agent, nil),
            (attachedIdle.agent, live),
            (.none, live),
        ]
        for (lifecycle, generation) in cases {
            var subject = SessionModel(id: SessionId(), agent: lifecycle)
            let before = subject.agent
            reduceSession(&subject, report: .userInputDelivered(waitGeneration: generation))
            #expect(
                lifecycle.retractsWait(carrying: generation) == (subject.agent != before),
                "predicate disagreed with the reducer for \(lifecycle) and \(String(describing: generation))"
            )
        }
    }

    // Intent: `pane.input` stamps its commands with the wait the pane holds at
    //   dispatch, so scripted input ends a wait the way typing does.
    // Why it exists: the snapshot has to be taken where the model is read. A
    //   command that carried no wait would leave every scripted Escape unable to
    //   retract, and the CLI is how the whole path is exercised.
    // Scenario: an agent reports `waiting` and `danterm pane input -- Escape`
    //   answers it.
    @Test("scripted pane input carries the wait its pane holds at dispatch")
    func scriptedInputCarriesTheCurrentWait() throws {
        var (model, paneId, session, agent) = try makeAttachedPane()
        update(&model, .sessionReport(
            sessionId: session,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        ))
        let generation = try #require(currentWaitGeneration(model, paneId))

        let commands = try paneInput(
            &model,
            paneId: paneId,
            params: [
                "input": .array([
                    .object(["key": .string("Escape")]),
                ])
            ]
        )

        var stamps: [AgentWaitGeneration?] = []
        for command in commands {
            if case .submitPaneInput(_, .key, _, let waitGeneration) = command {
                stamps.append(waitGeneration)
            }
        }
        #expect(stamps == [generation])

        update(&model, .sessionReport(
            sessionId: session,
            report: .userInputDelivered(waitGeneration: generation)
        ))
        #expect(attachedAgent(model.pane(paneId)?.session?.agent ?? .none)?.activity == nil)
    }

    // Intent: `pane.input` into a pane with no wait stamps its commands with no
    //   wait, so their later delivery retracts nothing.
    // Why it exists: an occurrence that named some wait it did not answer could
    //   erase a question raised while the input was in flight.
    @Test("scripted pane input carries no wait when the pane holds none")
    func scriptedInputCarriesNoWaitWhenNoneIsHeld() throws {
        var (model, paneId, session, agent) = try makeAttachedPane()
        update(&model, .sessionReport(
            sessionId: session,
            report: .agentActivityChanged(session: agent, activity: .working)
        ))

        let commands = try paneInput(
            &model,
            paneId: paneId,
            params: ["text": .string("y\n")]
        )

        var stamps: [AgentWaitGeneration?] = []
        for command in commands {
            if case .submitPaneInput(_, .paste, _, let waitGeneration) = command {
                stamps.append(waitGeneration)
            }
        }
        #expect(stamps == [nil])
    }
}
