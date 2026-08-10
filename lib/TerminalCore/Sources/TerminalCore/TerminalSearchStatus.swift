// The public counter a find UI needs from an active search: how many matches the
// needle has right now, and which one the engine currently has selected. The engine
// stores no separate count -- `Terminal.searchStatus` reads this from the same ordered
// match index navigation uses -- so this type exists to hand the counter across
// the module boundary as one atomic value, which is what keeps a counter from ever
// showing a total and an index taken from different scans.
// It is an enum rather than a `(total, selected?)` pair so the states a counter must
// never reach -- `selected >= total`, a negative total, "matches exist but none is
// selected" -- are unrepresentable at every call site instead of merely untested.
// Its own file because it is public vocabulary shared with the render/app layers,
// not an implementation detail of `Terminal`.

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
