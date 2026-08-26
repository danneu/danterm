// The one place the standard per-user config path is spelled. It lives in Support so
// the app's launch resolver and the `danterm` CLI reach the same layout instead of
// each keeping a copy. Path layout only -- reading, seeding, and the atomic save
// transaction stay with the app-side store, which uses the shared protocol config
// type. Nothing here resolves a home directory: the caller names one, because which
// config file a process owns is a launch decision, not an ambient fact.
import Foundation

/// Spells DanTerm's standard config layout under a caller-named home directory.
///
/// It is reached only from a launch seam -- the app resolves the file it owns once
/// at launch and hands it down -- so a leaf never answers "which config file is
/// this?" for itself.
enum DanTermConfigPaths {
    /// Standard config file path under `home`: <home>/.config/danterm/config.json
    static func standardConfigFilePath(home: String) -> String {
        "\(home)/.config/danterm/config.json"
    }
}
