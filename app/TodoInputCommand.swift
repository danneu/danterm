/// Pure keyboard command classification for the todo input field.
/// Maps domain-level key actions to input decisions, decoupled from
/// ObjC selectors so the logic is fully unit-testable.

/// Domain-level key action, decoupled from ObjC selectors.
enum InputKey {
    case enter
    case shiftEnter
    case escape
    case backspace
    case tab
    case backtab
    case other
}

/// What the input field should do in response to a key action.
enum InputAction: Equatable {
    case submit
    case insertNewline
    case cancelEdit
    /// Swallow the event with no visible effect (e.g. Escape when not editing).
    case dismiss
    case moveFocusForward
    case moveFocusBackward
    case unhandled
}

/// Classify a key action into an input decision based on edit state.
func classifyInputAction(key: InputKey, isEditing: Bool, fieldEmpty: Bool) -> InputAction {
    switch key {
    case .enter:
        return .submit
    case .shiftEnter:
        return .insertNewline
    case .escape:
        return isEditing ? .cancelEdit : .dismiss
    case .backspace:
        if isEditing && fieldEmpty { return .cancelEdit }
        return .unhandled
    case .tab:
        return .moveFocusForward
    case .backtab:
        return .moveFocusBackward
    case .other:
        return .unhandled
    }
}
