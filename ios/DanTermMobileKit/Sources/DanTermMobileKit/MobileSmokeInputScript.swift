// The probe a smoke run drives into the terminal's input responder.
//
// It lives here rather than in the shell for the same reason every other decision does:
// the iOS app package is an executable with no test target, and the responder is the one
// thing a smoke run exists to exercise. Naming the steps in a tested value is what keeps
// the probe from quietly losing one of them.
//
// What does not belong here: how a step is delivered. Whether `insertText` is called on a
// first responder or on a view that never took focus is the shell's business.

/// One thing the probe does to the terminal's input responder.
public enum MobileSmokeInputStep: Equatable, Sendable {
    case insertText(String)
    case deleteBackward
    case paste(String)
}

/// Turns the smoke run's input into the ordered probe that enters through the responder.
public enum MobileSmokeInputScript {
    /// What the probe pastes after the caller's own input. It opens a shell comment, so
    /// every character the probe adds -- the pasted text, and the one the backspace takes
    /// back -- is read as a comment rather than as part of the command.
    public static let pastedText = " # paste"

    /// The four entry points in the order that makes each one readable in the pane's echo:
    /// the typed text, then the paste appended to it, then the backspace that shortens the
    /// paste, then the return that runs what is left. A backspace that never reached the
    /// pane shows up as the one extra character the command line keeps.
    public static func steps(for input: String) -> [MobileSmokeInputStep] {
        [.insertText(input), .paste(pastedText), .deleteBackward, .insertText("\n")]
    }
}
