// Tests which connect gesture may read the draft target fields, and what an unusable draft
// is allowed to say.
import DanTermMobileKit
import Testing

private let good = MobileServerTarget(host: "mac.example", port: 7420)

@Test("One unusable draft answers the two connect gestures differently")
func unusableDraftAnswersOnlyTheGestureThatReadsIt() {
    // Intent: the gesture that names a server validates the draft; the gesture that names a
    //   pane answers from the established episode's target and never reads the draft.
    // Why it exists: the shell ran both gestures through one route that re-read the text
    //   fields, so a half-edited host reported a form problem in answer to a pane tap.
    // Scenario: the user connects, starts editing the host field, then taps a pane row.
    var connect = MobileConnectTarget()
    #expect(connect.setTarget(from: MobileTargetDraft(host: "mac.example", port: "7420"))
        == .connect(good))

    let halfEdited = MobileTargetDraft(host: "   ", port: "7420")
    #expect(connect.setTarget(from: halfEdited) == .reportDraft(.hostMissing))
    // The gesture hands back no target, so the shell has nothing to dispatch and a retry
    // already owed to the good target stands.
    #expect(connect.established == good)

    #expect(connect.reuseTarget() == .connect(good))
}

@Test("A draft that names no usable port reports the port, not the host")
func unusablePortReportsItself() {
    var connect = MobileConnectTarget()
    #expect(connect.setTarget(from: MobileTargetDraft(host: "mac.example", port: "99999"))
        == .reportDraft(.portUnusable))
    #expect(connect.setTarget(from: MobileTargetDraft(host: "mac.example", port: nil))
        == .reportDraft(.portUnusable))
    #expect(connect.established == nil)
}

@Test("A pane gesture before any episode connects to nothing")
func paneGestureWithoutAnEpisodeIsIgnored() {
    let connect = MobileConnectTarget()
    #expect(connect.reuseTarget() == .ignore)
}

@Test("Every draft problem words itself")
func draftProblemsAreWorded() {
    // Intent: the wording of a field problem is decided in the kit, where it has a test.
    let problems: [MobileTargetDraftProblem] = [.hostMissing, .portUnusable]
    for problem in problems {
        #expect(problem.label.isEmpty == false, "\(problem)")
    }
}
