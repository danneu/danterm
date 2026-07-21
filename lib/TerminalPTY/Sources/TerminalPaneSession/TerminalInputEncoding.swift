// Compatibility aliases keep pane-session callers on TerminalCore's single input vocabulary.
import TerminalCore

/// Re-exports the engine-owned semantic key vocabulary for existing session clients.
public typealias TerminalInputKey = TerminalCore.TerminalInputKey

/// Re-exports the engine-owned stable modifier set for existing session clients.
public typealias TerminalKeyModifiers = TerminalCore.TerminalKeyModifiers
