// The public values a frame needs from an active search. The engine builds the
// counter and highlight ranges from one match snapshot so they cannot disagree.
// It is an enum rather than a `(total, selected?)` pair so the states a counter must
// never reach -- `selected >= total`, a negative total, "matches exist but none is
// selected" -- are unrepresentable at every call site instead of merely untested.
// Their own file because they are public vocabulary shared with the render/app
// layers, not implementation details of `Terminal`.

/// Reports one search's live match count together with the selected match's index.
///
/// A `nil` status (there is no case for it here) means no search at all: never begun,
/// cleared, or an empty needle. `.empty` is the distinct "the user typed a needle that
/// currently matches nothing" state a find overlay renders as a failed search.
public enum TerminalSearchStatus: Equatable, Sendable {
    /// A non-empty needle with no occurrences in the searched history.
    case empty

    /// `selected` is zero-based with the **newest** match at index 0, so walking older
    /// matches increments it and a find overlay renders `selected + 1` of `total`.
    /// `total` is always positive and `selected` always lies in `0..<total`.
    case matched(selected: Int, total: Int)
}

/// Carries the counter and highlight ranges derived by one active-search scan.
public struct TerminalSearchReadout: Equatable, Sendable {
    /// The active search's live count and selected index.
    public let status: TerminalSearchStatus

    /// The selected occurrence, or nil when the needle has no matches.
    public let activeMatch: TerminalTextRange?

    /// The occurrences that intersect the terminal's current viewport.
    public let viewportMatches: [TerminalTextRange]

    /// Creates one coherent search value for status delivery and frame planning.
    public init(
        status: TerminalSearchStatus,
        activeMatch: TerminalTextRange?,
        viewportMatches: [TerminalTextRange]
    ) {
        self.status = status
        self.activeMatch = activeMatch
        self.viewportMatches = viewportMatches
    }
}
