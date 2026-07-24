// The public counter pair a find UI needs from an active search: how many matches
// the needle has right now, and which one the engine currently has selected. The
// engine stores no derived count -- `Terminal.searchStatus` recomputes this from the
// same live match scan navigation uses -- so this type exists purely to hand the two
// numbers across the module boundary as one atomic value, which is what keeps a
// counter from ever showing a total and an index taken from different scans.
// Its own file because it is public vocabulary shared with the render/app layers,
// not an implementation detail of `Terminal`.

/// Reports one search's live match count together with the selected match's index.
///
/// `selected` is zero-based with the **newest** match at index 0, so walking older
/// matches increments it and a find overlay renders `selected + 1` of `total`.
/// It is `nil` when no match is selected -- a needle that currently matches nothing.
public struct TerminalSearchStatus: Equatable, Sendable {
    public var total: Int
    public var selected: Int?

    public init(total: Int, selected: Int?) {
        self.total = total
        self.selected = selected
    }
}
