// Location of DanTerm's versioned JSON config file. It lives in Support so the
// app and the importable support target used by `danterm doctor` resolve exactly
// the same file instead of each keeping a copy of the layout. Path resolution only --
// reading, seeding, and the atomic save transaction stay with the app-side store,
// which uses the shared protocol config type.
import Foundation

/// Resolver for DanTerm's config file location, shared by the app and the CLI.
enum DanTermConfigPaths {
    /// Standard config file path: ~/.config/danterm/config.json
    static func configFilePath() -> String {
        "\(NSHomeDirectory())/.config/danterm/config.json"
    }
}
