// Converts pasteboard values into shell-safe drag-and-drop input.

import Foundation

enum DragDropInput {
    /// Shell-quote a string using single quotes with '\'' for embedded quotes.
    static func shellQuote(_ str: String) -> String {
        "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Build drag content from pasteboard values.
    /// Priority: non-empty file paths (shell-quoted) → urlString (shell-quoted) → plainString (as-is) → nil.
    static func buildContent(filePaths: [String], urlString: String?, plainString: String?) -> String? {
        let validPaths = filePaths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !validPaths.isEmpty {
            return validPaths.map { shellQuote($0) }.joined(separator: " ")
        }
        if let url = urlString, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return shellQuote(url)
        }
        if let str = plainString, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return str
        }
        return nil
    }
}
