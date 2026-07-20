// Cursor appearance and synchronized-output state projected by the pure terminal core.

/// Separates application-selected cursor geometry from renderer-specific drawing policy.
public enum TerminalCursorShape: Equatable, Sendable {
    case block
    case underline
    case bar
}

/// Carries terminal-controlled presentation state to consumers without exposing core storage.
public struct TerminalPresentation: Equatable, Sendable {
    /// Whether a frame consumer should include the terminal cursor.
    public let isCursorVisible: Bool

    /// The application-selected cursor geometry for renderers that support it.
    public let cursorShape: TerminalCursorShape

    /// Whether the application requested periodic cursor blinking.
    public let isCursorBlinking: Bool

    /// Whether frame consumers should suppress intermediate terminal states.
    public let isSynchronizedOutputActive: Bool

    /// Creates one complete projection from the terminal's stored presentation modes.
    public init(
        isCursorVisible: Bool,
        cursorShape: TerminalCursorShape,
        isCursorBlinking: Bool,
        isSynchronizedOutputActive: Bool
    ) {
        self.isCursorVisible = isCursorVisible
        self.cursorShape = cursorShape
        self.isCursorBlinking = isCursorBlinking
        self.isSynchronizedOutputActive = isSynchronizedOutputActive
    }
}
