// The vocabulary of the pane's one ordered semantic channel: the terminal's own
// meanings, plus the facts only the pane's input owner can state. Terminal
// meanings keep their own type in TerminalCore -- the parser produces those, and
// nothing here is something a parser can see.

// The UI harness compiles TerminalCore's sources into its own module, so it has the
// terminal vocabulary already and no module to import (see test-ui.sh).
#if !DANTERM_UI_TEST
import TerminalCore
#endif

/// Names one wait a pane's agent has reported, so an input that ends a wait can
/// say which wait it ended.
///
/// Opaque here on purpose: the host neither mints these nor reads meaning from
/// one. A caller hands the value it holds to an input operation, and the host
/// hands the same value back once that operation's bytes have crossed the PTY.
public struct PaneInputWaitGeneration: Equatable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// One complete pane semantic, ordered with every other semantic the pane emits.
///
/// It exists because the input half of a pane has semantics too, and they have to
/// stay in order with the output half rather than race it on a second callback.
public enum PaneSemanticEvent: Equatable, Sendable {
    /// A meaning the terminal parsed out of the child's output.
    case terminal(TerminalSemanticEvent)
    /// Every byte of one user-directed input operation crossed the PTY, carrying
    /// the wait generation the caller held when it submitted the operation.
    ///
    /// The input owner is the only party that can state this: it alone knows what
    /// bytes an operation encodes to, whether that encoding was empty, and whether
    /// the write completed or the submission was rejected. Focus reports and the
    /// terminal's own replies to the child are not user-directed and never appear
    /// here. `nil` means the caller held no wait when it submitted.
    case userInputDelivered(waitGeneration: PaneInputWaitGeneration?)
}
