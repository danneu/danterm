// Resource lookup for `danterm skill`, which must find the version-matched
// app bundle without relying on Bundle.main, the working directory, or IPC.
import Foundation

/// Collapses bundle-shape and read failures into the command's stable error.
enum SkillCommandError: Error, Equatable {
    case resourceUnavailable
}

/// Loads the canonical skill bytes beside the resolved CLI executable.
func loadBundledSkill(
    argv0: String,
    environment: [String: String],
    fileManager: FileManager
) throws -> Data {
    guard let executable = resolvedExecutableURL(
        argv0: argv0,
        environment: environment,
        fileManager: fileManager
    ), let appBundle = enclosingAppBundle(for: executable)
    else {
        throw SkillCommandError.resourceUnavailable
    }

    let resource = appBundle
        .appendingPathComponent("Contents/Resources/danterm/SKILL.md", isDirectory: false)
    guard fileManager.isReadableFile(atPath: resource.path),
          let data = try? Data(contentsOf: resource)
    else {
        throw SkillCommandError.resourceUnavailable
    }
    return data
}

/// Resolves argv0 through either its explicit path or PATH, then follows every symlink.
private func resolvedExecutableURL(
    argv0: String,
    environment: [String: String],
    fileManager: FileManager
) -> URL? {
    guard argv0.isEmpty == false else { return nil }
    if argv0.contains("/") {
        let url = argv0.hasPrefix("/")
            ? URL(fileURLWithPath: argv0)
            : URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(argv0)
        return url.resolvingSymlinksInPath()
    }

    for directory in (environment["PATH"] ?? "").split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
            .appendingPathComponent(argv0, isDirectory: false)
        if fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate.resolvingSymlinksInPath()
        }
    }
    return nil
}

/// Walks upward from a helper executable to the app bundle that owns it.
private func enclosingAppBundle(for executable: URL) -> URL? {
    var candidate = executable
    while candidate.path != "/" {
        if candidate.pathExtension == "app" {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    return nil
}
