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

/// Domain-level key action for row/list mode, decoupled from AppKit events.
enum ListKey: Equatable {
    case h
    case j
    case k
    case l
    case downArrow
    case upArrow
    case tab
    case backtab
    case enter
    case space
    case backspace
    case n
    case other
}

/// Modifier flags used by pure keyboard classifiers.
struct KeyModifiers: OptionSet, Equatable {
    let rawValue: Int

    static let command = KeyModifiers(rawValue: 1 << 0)
    static let shift = KeyModifiers(rawValue: 1 << 1)
}

/// Resolved command for a row-mode keystroke.
enum ListAction: Equatable {
    case moveSelection(delta: Int)
    case enterEdit
    case toggleDone
    case deleteRow
    case reorder(delta: Int)
    case moveBucket(delta: Int)
    case focusInput
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
        return isEditing ? .submit : .moveFocusForward
    case .backtab:
        return isEditing ? .cancelEdit : .unhandled
    case .other:
        return .unhandled
    }
}

/// Classify a row-mode key into a list action.
func classifyListAction(key: ListKey, modifiers: KeyModifiers) -> ListAction {
    if modifiers.contains(.command) {
        guard modifiers == [.command] else { return .unhandled }
        switch key {
        case .backspace:
            return .deleteRow
        case .n:
            return .focusInput
        default:
            return .unhandled
        }
    }

    if modifiers.contains(.shift) {
        switch key {
        case .j:
            return .reorder(delta: 1)
        case .k:
            return .reorder(delta: -1)
        case .h:
            return .moveBucket(delta: -1)
        case .l:
            return .moveBucket(delta: 1)
        case .tab, .backtab:
            return .focusInput
        default:
            return .unhandled
        }
    }

    switch key {
    case .j, .downArrow:
        return .moveSelection(delta: 1)
    case .k, .upArrow:
        return .moveSelection(delta: -1)
    case .tab, .enter:
        return .enterEdit
    case .space:
        return .toggleDone
    default:
        return .unhandled
    }
}

/// First selectable row index in `rows`, or nil if there is none.
func firstSelectableRow<R>(in rows: [R], canSelect: (R) -> Bool) -> Int? {
    rows.indices.first { canSelect(rows[$0]) }
}

/// Next selectable row from `from`, moving by `delta` without wrapping.
func nextSelectableRow<R>(in rows: [R], from: Int, delta: Int, canSelect: (R) -> Bool) -> Int? {
    guard delta != 0 else { return nil }
    let step = delta > 0 ? 1 : -1
    var index = from + step
    while rows.indices.contains(index) {
        if canSelect(rows[index]) { return index }
        index += step
    }
    return nil
}

/// Index of a row within its enclosing section, or nil for headers.
func sectionLocalIndex<R>(
    rows: [R],
    at row: Int,
    isHeader: (R) -> Bool,
    sectionId: (R) -> AnyHashable?
) -> Int? {
    guard rows.indices.contains(row), !isHeader(rows[row]) else { return nil }
    let targetSection = sectionId(rows[row])
    var localIndex = 0
    for index in rows.indices {
        guard !isHeader(rows[index]), sectionId(rows[index]) == targetSection else { continue }
        if index == row { return localIndex }
        localIndex += 1
    }
    return nil
}
