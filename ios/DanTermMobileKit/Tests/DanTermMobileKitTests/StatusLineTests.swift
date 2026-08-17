// Tests the composed phone status line: what it says, how severe it reads, and that its
// four facts stay in their own slots.
import DanTermClient
import DanTermMobileKit
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
    var status = MobileStatus()
    status.noteConnection(.ready, detail: "Connected to DanTerm 5")
    status.noteStream(.gap(.declared(declaredLoss)))
    let line = status.line(at: 0)
    #expect(line.severity == .degraded)
    #expect(line.text.contains("Connected to DanTerm 5"))
    #expect(line.text.contains("stream gap"))

    status.noteStream(.exact)
    let repaired = status.line(at: 0)
    #expect(repaired.severity == .normal)
    #expect(repaired.text == "Connected to DanTerm 5")
}

@Test("Recovery is composed beside the causal state, not instead of it")
func recoveryComposesBesideCause() {
    var status = MobileStatus()
    status.noteConnection(.connectionLost)
    status.noteRecovery(.waiting(until: 12))
    let line = status.line(at: 7)
    #expect(line.text.contains("Connection lost"))
    #expect(line.text.contains("retrying in 5s"))
    #expect(line.severity == .failed)

    status.noteRecovery(.none)
    #expect(status.line(at: 7).text == "Connection lost")
}

@Test("Writing one fact leaves the other three alone")
func factsOccupySeparateSlots() {
    // Intent: no fact can be written through another's slot, in either write order.
    // Why it exists: this is what makes the removed borrow -- a stream condition stored in
    //   the connection state and reversed by hand -- unspellable rather than discouraged.
    var written = MobileStatus()
    written.noteConnection(.ready, detail: "Connected")
    written.noteStream(.gap(.declared(declaredLoss)))
    written.noteRequestOutcome(.refused(reason: "pane not found"))
    written.noteRecovery(.attempting)

    var reordered = MobileStatus()
    reordered.noteRecovery(.attempting)
    reordered.noteRequestOutcome(.refused(reason: "pane not found"))
    reordered.noteStream(.gap(.declared(declaredLoss)))
    reordered.noteConnection(.ready, detail: "Connected")
    #expect(written == reordered)

    let all = written.line(at: 0)
    #expect(all.text.contains("Connected"))
    #expect(all.text.contains("stream gap"))
    #expect(all.text.contains("pane not found"))
    #expect(all.text.contains("reconnecting"))

    // Rewriting the stream fact with the same value changes nothing else.
    written.noteStream(.gap(.declared(declaredLoss)))
    #expect(written.line(at: 0) == all)
}

@Test("A refused request is the latest non-tape outcome, and nothing wider")
func refusedRequestIsTheLatestOutcome() {
    // Intent: the refusal shows while it is the newest answer, is replaced by the next
    //   one, is cleared by a success, and cannot outlive the connection it describes.
    // Why it exists: the shell wrote a refused non-tape request into the connection state,
    //   where nothing ever cleared it, so a serving connection kept reading as failed.
    var status = MobileStatus()
    status.noteConnection(.ready, detail: "Connected")
    status.noteRequestOutcome(.refused(reason: "pane not found"))
    #expect(status.line(at: 0).text.contains("pane not found"))
    #expect(status.line(at: 0).severity == .degraded)

    status.noteRequestOutcome(.refused(reason: "input rejected"))
    #expect(status.line(at: 0).text.contains("input rejected"))
    #expect(status.line(at: 0).text.contains("pane not found") == false)

    status.noteRequestOutcome(.succeeded)
    #expect(status.line(at: 0) == MobileStatusLine(text: "Connected", severity: .normal))

    status.noteRequestOutcome(.refused(reason: "pane not found"))
    status.noteRequestOutcome(nil)
    #expect(status.line(at: 0).text.contains("pane not found") == false)
}

@Test("Facts about a serving stream are not shown beside a connection that is not serving")
func servingFactsDoNotOutliveTheConnection() {
    var status = MobileStatus()
    status.noteConnection(.ready, detail: "Connected")
    status.noteStream(.gap(.declared(declaredLoss)))
    status.noteRequestOutcome(.refused(reason: "pane not found"))

    status.noteConnection(.connectionLost)
    let line = status.line(at: 0)
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
        (.listingPanes, .normal),
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
        var status = MobileStatus()
        status.noteConnection(state)
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
            var status = MobileStatus()
            status.noteConnection(state)
            status.noteRecovery(phase)
            let expected = [causeText, recoveryText].compactMap(\.self).joined(separator: " - ")
            #expect(status.line(at: 25).text == expected, "\(state) \(phase)")
        }
    }
}

@Test("Every stream condition words a claim that is true while it is shown")
func streamConditionWording() {
    var status = MobileStatus()
    status.noteConnection(.ready, detail: "Connected")
    status.noteStream(.awaitingSynchronization)
    #expect(status.line(at: 0).text == "Connected - waiting for exact state")

    status.noteStream(.gap(.detected))
    #expect(status.line(at: 0).text == "Connected - stream out of step with the Mac")
    #expect(status.line(at: 0).severity == .degraded)

    status.noteStream(nil)
    #expect(status.line(at: 0).text == "Connected")
}
