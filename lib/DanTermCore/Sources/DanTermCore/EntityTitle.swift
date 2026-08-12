// Admission of user-supplied tab and group names into the model. Terminal-reported
// titles are not admitted here -- those go through TerminalMetadataBounds.
import Foundation

extension String {
    /// Flattens a user-supplied name to one line so every surface that shows it
    /// (sidebar row, switcher, window chrome) can lay it out as a single line and
    /// truncate it. A pasted or CLI-passed name can carry newlines and runs of
    /// indentation; a multi-line label wraps instead, and truncates each of its
    /// lines. Returns nil when nothing but whitespace is left.
    var singleLineName: String? {
        let collapsed = split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
