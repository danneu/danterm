// The `danterm doctor` config-font fact, composed here because the CLI is the
// only place both halves are in scope: reading and decoding `config.json` needs
// DanTermCore's document type, and asking whether a family is installed needs
// DanTermSupport's CoreText probe, and those two modules must never see each
// other. Doctor stays local-only and app-independent -- this reads the same file
// the app reads, without asking the app anything.
import Foundation
import DanTermProtocol

/// Resolves the configured `font.family` into the verdict doctor reports. An
/// unreadable or undecodable file is a fact, not a failure: doctor's job is to
/// describe config health, so every outcome here is a reportable state.
func gatherConfigFontFacts(
    path: String = DanTermConfigPaths.configFilePath(),
    fileManager: FileManager = .default
) -> DoctorFacts.ConfigFont {
    guard fileManager.fileExists(atPath: path) else { return .unset }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let document = DanTermConfigDocument.decode(data)
    else { return .unreadableConfig }
    guard let requested = document.config.fontFamily else { return .unset }
    return resolveInstalledFontFamily(named: requested) == nil
        ? .notInstalled(requested: requested)
        : .installed
}
