// DanTerm-specific configuration parsed from ~/.config/danterm/config.
// The config file uses the same key=value format as Ghostty. Ghostty terminal
// keys are passed through to libghostty as an overlay; DanTerm-specific keys
// (listed here) are parsed by DanTerm itself.
import Foundation

enum AlertClearMode: String, Equatable {
    case focus   // auto-clear alerts when pane gains focus (default)
    case manual  // require explicit Cmd+. (tab) or Cmd+Shift+. (pane) to clear
}

struct DanTermConfig: Equatable {
    /// Theme applied to panes during SSH/remote sessions.
    var remoteTheme: String = "Purplepeter"
    /// When alerts are cleared: on pane focus (.focus) or only via Cmd+./Cmd+Shift+. (.manual).
    var alertClearMode: AlertClearMode = .focus

    static let `default` = DanTermConfig()
}

/// Parses DanTerm-specific keys from the config file.
/// Unknown keys (including Ghostty keys) are silently ignored.
enum DanTermConfigParser {
    /// Standard config file path: ~/.config/danterm/config
    static func configFilePath() -> String {
        let home = NSHomeDirectory()
        return "\(home)/.config/danterm/config"
    }

    /// Read and parse the config file from disk.
    /// Returns .default if the file doesn't exist or can't be read.
    static func loadFromDisk() -> DanTermConfig {
        let path = configFilePath()
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return .default
        }
        return parse(content: content)
    }

    /// Parse DanTerm-specific keys from raw config file content.
    /// Format: key = value, # comments, blank lines ignored.
    static func parse(content: String) -> DanTermConfig {
        var config = DanTermConfig()
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "remote-theme":
                if !value.isEmpty { config.remoteTheme = value }
            case "alert-clear-mode":
                switch value {
                case "focus": config.alertClearMode = .focus
                case "manual": config.alertClearMode = .manual
                default: break
                }
            default:
                break  // Ghostty keys and unknown keys silently ignored
            }
        }
        return config
    }
}

/// Surgically updates a single key in config file content, preserving all other lines.
enum DanTermConfigWriter {
    /// Replace the last occurrence of `key = ...` with `key = value`, or append if absent.
    /// Comments, blank lines, and Ghostty keys are preserved verbatim.
    static func setKey(_ key: String, value: String, in content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        // Find the last non-comment line matching this key.
        var lastIndex: Int? = nil
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let lineKey = trimmed[trimmed.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            if lineKey == key { lastIndex = i }
        }
        let newLine = "\(key) = \(value)"
        if let idx = lastIndex {
            lines[idx] = newLine
        } else {
            // Append. If content doesn't end with a newline, the last split element is "".
            // Insert before that trailing empty element to avoid a double blank line.
            if content.hasSuffix("\n") {
                lines.insert(newLine, at: lines.count - 1)
            } else {
                lines.append(newLine)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Remove all occurrences of `key = ...` from config file content.
    /// Comments, blank lines, and other keys are preserved verbatim.
    static func removeKey(_ key: String, from content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return true }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { return true }
            let lineKey = trimmed[trimmed.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            return lineKey != key
        }
        return filtered.joined(separator: "\n")
    }
}
