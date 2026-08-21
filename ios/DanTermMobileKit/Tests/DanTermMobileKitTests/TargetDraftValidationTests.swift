// Tests stateless draft validation and what an unusable draft is allowed to say.
import DanTermMobileKit
import Testing

private let good = MobileServerTarget(host: "mac.example", port: 7420)

@Test("Draft validation returns a target or its own problem without storing either")
func draftValidationIsStateless() {
    #expect(MobileTargetDraft(host: "mac.example", port: "7420").validate() == .valid(good))

    let halfEdited = MobileTargetDraft(host: "   ", port: "7420")
    #expect(halfEdited.validate() == .reportDraft(.hostMissing))
}

@Test("A draft that names no usable port reports the port, not the host")
func unusablePortReportsItself() {
    #expect(MobileTargetDraft(host: "mac.example", port: "99999").validate()
        == .reportDraft(.portUnusable))
    #expect(MobileTargetDraft(host: "mac.example", port: nil).validate()
        == .reportDraft(.portUnusable))
}

@Test("Every draft problem words itself")
func draftProblemsAreWorded() {
    // Intent: the wording of a field problem is decided in the kit, where it has a test.
    let problems: [MobileTargetDraftProblem] = [.hostMissing, .portUnusable]
    for problem in problems {
        #expect(problem.label.isEmpty == false, "\(problem)")
    }
}
