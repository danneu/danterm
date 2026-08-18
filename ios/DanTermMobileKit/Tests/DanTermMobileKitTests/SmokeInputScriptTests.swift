// Pins the order of the probe a smoke run drives into the terminal's input responder.
import DanTermMobileKit
import Testing

@Test("The smoke probe types, pastes, backspaces, and then returns")
func smokeProbeExercisesEveryEntryPoint() {
    // Intent: the probe drives all four ways text reaches the pane, in the order that
    //   makes each one readable in the pane's own echo.
    // Why it exists: the iOS app package has no test target, so the responder that
    //   replaced the composer is only ever proved by a simulator run. A probe that
    //   skipped an entry point would let that entry point ship unexercised.
    // Scenario: `DANTERM_IOS_SMOKE_INPUT='echo hi' scripts/ios-app.sh simulator`.
    #expect(MobileSmokeInputScript.steps(for: "echo hi") == [
        .insertText("echo hi"),
        .paste(MobileSmokeInputScript.pastedText),
        .deleteBackward,
        .insertText("\n"),
    ])
}

@Test("The probe's own characters cannot change what the command does")
func smokeProbeKeepsItsCharactersInert() {
    // The pasted text opens a shell comment, so everything the probe adds after the
    // caller's input -- the paste, and the character the backspace takes back -- is read
    // by the shell as a comment rather than as part of the command.
    #expect(MobileSmokeInputScript.pastedText.hasPrefix(" #"))
}
