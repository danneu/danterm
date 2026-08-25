// Tests the composed phone status line: what it says, how severe it reads, and that its
// four facts stay in their own slots.
import DanTermMobileKit
import DanTermProtocol
import Testing

private let declaredLoss = PaneTapeGapRecord.Loss.exact(
    droppedEventCount: 3,
    droppedFeedBytes: 40,
    droppedWriteBytes: 0
)

@Test("A gap on a serving connection reads as degraded, never as a connection failure")
func gapOnServingConnectionStaysServing() {
    // Intent: the stream condition decorates a connection that is still working.
    // Why it exists: the shell used to borrow the connection-lost state for a gap and then
    //   undo it with a flag, so the user was told the connection was gone while it served.
    let status = MobileStatus(
        connection: .ready,
        detail: "Connected to DanTerm 5",
        stream: .gap(.declared(declaredLoss))
    )
    let line = status.line(at: 0)
    #expect(line.severity == .degraded)
    #expect(line.text.contains("Connected to DanTerm 5"))
    #expect(line.text.contains("stream gap"))

    let repaired = MobileStatus(
        connection: .ready,
        detail: "Connected to DanTerm 5",
        stream: .exact
    ).line(at: 0)
    #expect(repaired.severity == .normal)
    #expect(repaired.text == "Connected to DanTerm 5")
}

@Test("Recovery is composed beside the causal state, not instead of it")
func recoveryComposesBesideCause() {
    let status = MobileStatus(connection: .connectionLost, recovery: .waiting(until: 12))
    let line = status.line(at: 7)
    #expect(line.text.contains("Connection lost"))
    #expect(line.text.contains("retrying in 5s"))
    #expect(line.severity == .failed)

    #expect(MobileStatus(connection: .connectionLost).line(at: 7).text == "Connection lost")
}

@Test("Every projected fact occupies its own status clause")
func factsOccupySeparateClauses() {
    // Intent: connection, stream, request outcome, and recovery each contribute one clause.
    // Why it exists: this is what makes the removed borrow -- a stream condition stored in
    //   the connection state and reversed by hand -- unspellable rather than discouraged.
    let all = MobileStatus(
        connection: .ready,
        detail: "Connected",
        recovery: .attempting,
        stream: .gap(.declared(declaredLoss)),
        requestOutcome: .refused(reason: "pane not found")
    ).line(at: 0)
    #expect(all.text.contains("Connected"))
    #expect(all.text.contains("stream gap"))
    #expect(all.text.contains("pane not found"))
    #expect(all.text.contains("reconnecting"))

}

@Test("A refused request is the latest non-tape outcome, and nothing wider")
func refusedRequestIsTheLatestOutcome() {
    // Intent: the refusal shows while it is the newest answer, is replaced by the next
    //   one, is cleared by a success, and cannot outlive the connection it describes.
    // Why it exists: the shell wrote a refused non-tape request into the connection state,
    //   where nothing ever cleared it, so a serving connection kept reading as failed.
    let refused = MobileStatus(
        connection: .ready,
        detail: "Connected",
        requestOutcome: .refused(reason: "pane not found")
    ).line(at: 0)
    #expect(refused.text.contains("pane not found"))
    #expect(refused.severity == .degraded)

    let replaced = MobileStatus(
        connection: .ready,
        detail: "Connected",
        requestOutcome: .refused(reason: "input rejected")
    ).line(at: 0)
    #expect(replaced.text.contains("input rejected"))
    #expect(replaced.text.contains("pane not found") == false)

    for outcome: MobileRequestOutcome? in [.succeeded, nil] {
        #expect(MobileStatus(
            connection: .ready,
            detail: "Connected",
            requestOutcome: outcome
        ).line(at: 0)
            == MobileStatusLine(text: "Connected", severity: .normal, isResting: true))
    }
}

@Test("Facts about a serving stream are not shown beside a connection that is not serving")
func servingFactsDoNotOutliveTheConnection() {
    let line = MobileStatus(
        connection: .connectionLost,
        stream: .gap(.declared(declaredLoss)),
        requestOutcome: .refused(reason: "pane not found")
    ).line(at: 0)
    #expect(line.text == "Connection lost")
    #expect(line.severity == .failed)
}

@Test("Severity is total over the connection vocabulary")
func severityIsTotalOverTheVocabulary() {
    // Intent: every state the user can be shown has a deliberate severity.
    // Why it exists: the shell derived severity from a `default:` arm, so a state added
    //   later would have inherited failure styling without anyone choosing it.
    let cases: [(MobileConnectionState, MobileStatusSeverity)] = [
        (.disconnected, .normal),
        (.connecting, .normal),
        (.ready, .normal),
        (.hostNotFound, .failed),
        (.serverUnreachable, .failed),
        (.refusedByMac(.notAdmitted), .failed),
        (.refusedByMac(.identityUnresolved), .failed),
        (.refusedByMac(.connectionLimit), .failed),
        (.refusedByMac(.auditUnavailable), .failed),
        (.versionMismatch(7), .failed),
        (.connectionLost, .failed),
        (.deviceSetupFailure, .failed),
        (.streamEnded("paneClosed"), .failed),
        (.requestRefused("pane not found"), .failed),
        (.streamDesynchronized, .failed),
    ]
    for (state, expected) in cases {
        let status = MobileStatus(connection: state)
        #expect(status.line(at: 0).severity == expected, "\(state)")
        #expect(status.line(at: 0).text.isEmpty == false, "\(state)")
    }
}

@Test("Every causal state composes with every recovery phase")
func causeAndRecoveryCompose() {
    // Intent: the composed text of each reachable cause-and-recovery pair, including that
    //   rest after give-up shows the plain terminal state with no recovery clause.
    // Why it exists: the composition used to live in the shell, which has no tests, so the
    //   one rule that both halves are always shown together had no proof anywhere.
    let causes: [(MobileConnectionState, String)] = [
        (.connectionLost, "Connection lost"),
        (.serverUnreachable, "Server unreachable"),
        (.streamDesynchronized, "Stream out of step with the Mac"),
        (.streamEnded("paneClosed"), "Stream ended: paneClosed"),
    ]
    let phases: [(MobileRecoveryPhase, String?)] = [
        (.none, nil),
        (.attempting, "reconnecting"),
        (.waiting(until: 30), "retrying in 5s"),
        (.waitingForNetwork, "waiting for network"),
    ]
    for (state, causeText) in causes {
        for (phase, recoveryText) in phases {
            let status = MobileStatus(connection: state, recovery: phase)
            let expected = [causeText, recoveryText].compactMap(\.self).joined(separator: " - ")
            #expect(status.line(at: 25).text == expected, "\(state) \(phase)")
        }
    }
}

@Test("Every stream condition words a claim that is true while it is shown")
func streamConditionWording() {
    let status = MobileStatus(
        connection: .ready,
        detail: "Connected",
        stream: .awaitingSynchronization
    )
    #expect(status.line(at: 0).text == "Connected - waiting for exact state")

    let detected = MobileStatus(
        connection: .ready,
        detail: "Connected",
        stream: .gap(.detected)
    ).line(at: 0)
    #expect(detected.text == "Connected - stream out of step with the Mac")
    #expect(detected.severity == .degraded)

    #expect(MobileStatus(connection: .ready, detail: "Connected").line(at: 0).text
        == "Connected")
}

@Test("The status rests only on a serving connection with nothing further to report")
func statusRestsOnlyWhenServingWithNothingToAdd() {
    // Intent: the single fact the shell reads to decide whether any status is drawn over
    //   the grid at all -- true for a healthy connection, false for everything else.
    // Why it exists: severity cannot decide it. `connecting` and `disconnected` are
    //   `.normal` severity and still carry words the user needs, so a shell that hid the
    //   status by severity would go silent exactly while the connection was away.
    #expect(MobileStatus(connection: .ready, detail: "Connected").line(at: 0).isResting)

    let restless: [MobileStatus] = [
        MobileStatus(connection: .disconnected),
        MobileStatus(connection: .connecting),
        MobileStatus(connection: .hostNotFound),
        MobileStatus(connection: .serverUnreachable),
        MobileStatus(connection: .refusedByMac(.notAdmitted)),
        MobileStatus(connection: .refusedByMac(.identityUnresolved)),
        MobileStatus(connection: .refusedByMac(.connectionLimit)),
        MobileStatus(connection: .refusedByMac(.auditUnavailable)),
        MobileStatus(connection: .versionMismatch(7)),
        MobileStatus(connection: .connectionLost),
        MobileStatus(connection: .deviceSetupFailure),
        MobileStatus(connection: .streamEnded("paneClosed")),
        MobileStatus(connection: .requestRefused("pane not found")),
        MobileStatus(connection: .streamDesynchronized),
        // A connection that is serving, and still has a clause of its own to report.
        MobileStatus(connection: .ready, detail: "Connected", stream: .awaitingSynchronization),
        MobileStatus(connection: .ready, detail: "Connected", stream: .gap(.declared(declaredLoss))),
        MobileStatus(connection: .ready, detail: "Connected", stream: .gap(.detected)),
        MobileStatus(
            connection: .ready,
            detail: "Connected",
            requestOutcome: .refused(reason: "pane not found")
        ),
        MobileStatus(connection: .ready, detail: "Connected", recovery: .attempting),
        MobileStatus(connection: .ready, detail: "Connected", recovery: .waiting(until: 30)),
        MobileStatus(connection: .ready, detail: "Connected", recovery: .waitingForNetwork),
    ]
    for status in restless {
        #expect(status.line(at: 0).isResting == false, "\(status.connection)")
    }
}
