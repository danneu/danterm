// Admission of user-supplied tab and group names into the model. Terminal-reported
// titles are not admitted here -- those go through TerminalMetadataBounds.
import Foundation

extension String {
    /// Flattens a user-supplied name to one line so every surface that shows it
    /// (sidebar row, switcher, window chrome) can lay it out as a single line and
    /// truncate it. A pasted or CLI-passed name can carry newlines, runs of
    /// indentation, and -- when it was copied out of terminal output -- control
    /// characters. Returns nil when nothing survives.
    ///
    /// Admission is the model's own boundary, so it normalizes on the same
    /// primitive the display boundary uses rather than a second rule that could
    /// drift from it.
    var singleLineName: String? {
        let line = DisplayLine(self).text
        return line.isEmpty ? nil : line
    }
}
