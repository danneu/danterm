// DanTerm-specific configuration parsed from ~/.config/danterm/config.
// The config file uses the same key=value format as Ghostty. Ghostty terminal
// keys are passed through to libghostty as an overlay; DanTerm-specific keys
// (listed here) are parsed by DanTerm itself.
import Foundation

struct DanTermConfig: Equatable {
    /// Theme applied to panes during SSH/remote sessions.
    var remoteTheme: String = "Purplepeter"

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
            default:
                break  // Ghostty keys and unknown keys silently ignored
            }
        }
        return config
    }
}
