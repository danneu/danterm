// Reads a pointer decision's selection mutation the way the terminal settles it, so a test
// states the selection it expects and not the anchor/focus pair the policy happened to name.
// Assertions on the pair itself belong in the anchor tests, which are about provenance.
import Testing

@testable import TerminalCore

/// What one pointer decision leaves selected.
///
/// Four cases because the terminal has four answers: an untouched selection, a removed one,
/// the caret a plain click settles -- present, invisible, and pivotable -- and a highlighted
/// extent.
enum SettledSelectionOutcome: Equatable {
    case unchanged
    case cleared
    case caret
    case selected(TerminalTextRange, granularity: TerminalSelectionGranularity)
}

extension TerminalPointerDecision {
    /// Orders the decision's anchored pair into the extent the terminal will highlight.
    var settledSelection: SettledSelectionOutcome {
        switch selectionMutation {
        case nil:
            return .unchanged
        case .clear:
            return .cleared
        case let .set(anchorUnit, focus, granularity):
            func precedes(_ lhs: TerminalTextPosition, _ rhs: TerminalTextPosition) -> Bool {
                lhs.row < rhs.row || (lhs.row == rhs.row && lhs.column < rhs.column)
            }
            let start = precedes(focus, anchorUnit.start) ? focus : anchorUnit.start
            let end = precedes(anchorUnit.end, focus) ? focus : anchorUnit.end
            if granularity == .character, start == end { return .caret }
            return .selected(
                TerminalTextRange(start: start, end: end),
                granularity: granularity
            )
        }
    }
}

/// Runs one pointer event and settles it, which is what the live host does with every
/// decision.
///
/// The anchor is terminal state, so a press that is never applied leaves nothing for the drag
/// or Shift press that follows to pivot on.
@discardableResult
func decideAndApply(
    _ event: TerminalPointerEvent,
    terminal: inout Terminal,
    state: inout TerminalInteractionState
) -> TerminalPointerDecision {
    let decision = decideTerminalPointer(event, terminal: terminal, state: &state)
    applyTerminalPointerDecision(decision, to: &terminal)
    return decision
}
