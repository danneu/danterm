// The pane-kind chip vocabulary: which mark a client draws beside a pane.
//
// It lives at the protocol boundary because the server decides a pane's chip
// and every client renders that decision verbatim -- so the four spellings are
// wire vocabulary and there is no second classification on the client side.
//
// Not here: how a chip is decided from a pane's agent (a pure DanTermCore
// projection), and what a chip looks like (the ChipArtwork package).

/// The chip that identifies what a pane is running.
///
/// Closed over the artwork DanTerm ships (`icon/chips`). `.terminal` means no
/// agent at all, and `.agent` means one DanTerm has no mark for -- keeping those
/// apart is what lets the toolbar decide whether the chip already names the
/// agent or the label still has to.
/// `CaseIterable` so the tests that must cover every kind -- each one painting
/// distinct pixels, above all -- iterate the enum instead of a hand-written list
/// that a new kind would quietly fall off.
public enum ChipKind: String, Equatable, CaseIterable, Sendable {
    case terminal
    case claude
    case codex
    case agent
}
