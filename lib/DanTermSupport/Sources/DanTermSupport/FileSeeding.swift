// Tiny file-seeding side effect: "ensure this path exists, creating its parent
// directory and the file (with an optional seed) only if missing." Backs the
// app's "open config" / "save config key" flows, each of which must guarantee
// there is a file to open or edit before handing it to the editor or rewriting
// a key. Lives in DanTermSupport because it is a FileManager boundary the pure
// core deliberately does not own, and because three call sites open-coded the
// same dir+createFile dance -- collapsing them here keeps the seed behavior
// (and its no-clobber guarantee) in one tested place. Depends only on
// Foundation, never on DanTermCore.
import Foundation

/// Ensures `path` exists: creates the parent directory (if missing) and then
/// the file seeded with `seed` (if missing). A no-op when the file already
/// exists, so existing user content is never clobbered. Used to back the
/// "open config" / "save config key" flows that must open something.
public func ensureFileExists(atPath path: String, seed: Data?, fileManager: FileManager = .default) {
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent().path
    if !fileManager.fileExists(atPath: dir) {
        try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    if !fileManager.fileExists(atPath: path) {
        fileManager.createFile(atPath: path, contents: seed)
    }
}
