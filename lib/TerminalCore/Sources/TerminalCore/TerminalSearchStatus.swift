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

/// One active search's coherent value for the current viewport: a needle that matches
/// nothing, or a counter that always comes with the occurrence it counts.
///
/// Two shapes rather than a status beside an optional highlight, so "matches exist but
/// none is selected" is unrepresentable here as it already is in `TerminalSearchStatus`.
/// `status` is derived, not stored: `TerminalPaneSession` keys its emission on it, and
/// eviction that renumbers the active range must not republish an unchanged counter.
public enum TerminalSearchReadout: Equatable, Sendable {
    /// A non-empty needle with no occurrences in the searched history.
    case empty

    /// The needle matches; the payload names the selected occurrence and the viewport's.
    case matched(TerminalSearchMatches)

    /// The counter a find overlay renders and the session's change key.
    public var status: TerminalSearchStatus {
        switch self {
        case .empty: .empty
        case .matched(let matches): .matched(selected: matches.selected, total: matches.total)
        }
    }

    /// The selected occurrence, present exactly when the readout is `.matched`.
    public var activeMatch: TerminalTextRange? {
        if case .matched(let matches) = self { matches.activeMatch } else { nil }
    }

    /// The occurrences that intersect the terminal's current viewport, ascending by start.
    /// The frame planner walks them with one forward cursor and depends on that order.
    public var viewportMatches: [TerminalTextRange] {
        if case .matched(let matches) = self { matches.viewportMatches } else { [] }
    }
}

/// The matched shape of a readout: the counter's numbers, the occurrence they select,
/// and the occurrences the viewport shows, derived by one active-search scan.
public struct TerminalSearchMatches: Equatable, Sendable {
    /// Zero-based with the **newest** match at index 0; always in `0..<total`.
    public let selected: Int
    /// Always positive.
    public let total: Int
    /// The selected occurrence, in current-stream coordinates; on screen or not.
    public let activeMatch: TerminalTextRange
    /// The occurrences that intersect the viewport, ascending by start.
    public let viewportMatches: [TerminalTextRange]

    public init(
        selected: Int,
        total: Int,
        activeMatch: TerminalTextRange,
        viewportMatches: [TerminalTextRange]
    ) {
        self.selected = selected
        self.total = total
        self.activeMatch = activeMatch
        self.viewportMatches = viewportMatches
    }
}
