// Location of DanTerm's versioned JSON config file. It lives in Support rather
// than in the app so the app and the `danterm` CLI (which compiles this module
// through its own symlink, and needs the path for `doctor`) resolve exactly the
// same file instead of each keeping a copy of the layout. Path resolution only --
// reading, seeding, and the atomic save transaction stay with the app-side store,
// which needs the core's config type.
import Foundation

/// Resolver for DanTerm's config file location, shared by the app and the CLI.
enum DanTermConfigPaths {
    /// Standard config file path: ~/.config/danterm/config.json
    static func configFilePath() -> String {
        "\(NSHomeDirectory())/.config/danterm/config.json"
    }
}
