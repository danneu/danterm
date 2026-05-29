// App-side filesystem access for DanTerm's own config file: the home-relative
// path resolver (`DanTermConfigPaths.configFilePath`) and the disk loader
// (`DanTermConfigParser.loadFromDisk`, kept here as an extension so its AppRuntime
// call sites retain the name). Both read ambient state -- NSHomeDirectory and
// FileManager -- which is exactly what the pure core may not do, so they live in
// app/ beside the runtime rather than in DanTermCore. The pure pieces they wrap
// (`DanTermConfigParser.parse(content:)` and `DanTermConfigWriter`) stay in core.
// Earns its own file as the single app-side home for DanTerm config-file IO.
import Foundation

/// App-level resolver for DanTerm's config file location. Lives in app/, not the
/// pure core, because it reads the ambient home via `NSHomeDirectory()`.
enum DanTermConfigPaths {
    /// Standard config file path: ~/.config/danterm/config
    static func configFilePath() -> String {
        let home = NSHomeDirectory()
        return "\(home)/.config/danterm/config"
    }
}

extension DanTermConfigParser {
    /// Read and parse the config file from disk; `.default` if it doesn't exist or
    /// can't be read. App-side because it touches the filesystem (FileManager); the
    /// parsing it delegates to (`parse(content:)`) stays pure in DanTermCore.
    static func loadFromDisk() -> DanTermConfig {
        let path = DanTermConfigPaths.configFilePath()
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return .default
        }
        return parse(content: content)
    }
}
