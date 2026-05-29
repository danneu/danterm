// Installs or removes the bundled danterm CLI symlink in the user's PATH.
import Foundation

final class CLIPathInstaller {
    struct InstallOutcome {
        let usedAdministratorPrivileges: Bool
        let destinationURL: URL
        let sourceURL: URL
    }

    struct UninstallOutcome {
        let usedAdministratorPrivileges: Bool
        let destinationURL: URL
        let removedExistingEntry: Bool
    }

    struct Dependencies {
        var destinationURL: URL
        var sourceURL: () -> URL
        var bundleURL: () -> URL
        var fileManager: FileManager
        var privilegedRunner: (String) throws -> Void

        static var `default`: Dependencies {
            Dependencies(
                destinationURL: URL(fileURLWithPath: "/usr/local/bin/danterm"),
                sourceURL: {
                    return Bundle.main.bundleURL
                        .appendingPathComponent("Contents/Helpers/danterm", isDirectory: false)
                },
                bundleURL: { Bundle.main.bundleURL },
                fileManager: .default,
                privilegedRunner: Self.runPrivilegedShellCommand(_:)
            )
        }

        private static func runPrivilegedShellCommand(_ command: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e", "on run argv",
                "-e", "do shell script (item 1 of argv) with administrator privileges",
                "-e", "end run",
                command,
            ]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw InstallerError.privilegedCommandFailed(
                    message: "osascript exited with status \(process.terminationStatus)"
                )
            }
        }
    }

    enum InstallerError: LocalizedError, Equatable {
        case appTranslocated
        case bundledCLIMissing(expectedPath: String)
        case destinationParentNotDirectory(path: String)
        case destinationIsDirectory(path: String)
        case destinationIsNotSymlink(path: String)
        case installVerificationFailed(path: String)
        case uninstallVerificationFailed(path: String)
        case privilegedCommandFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .appTranslocated:
                return "Move DanTerm to /Applications before installing the danterm command."
            case .bundledCLIMissing(let expectedPath):
                return "Bundled danterm CLI was not found at \(expectedPath)."
            case .destinationParentNotDirectory(let path):
                return "Expected \(path) to be a directory."
            case .destinationIsDirectory(let path):
                return "\(path) is a directory. Remove or rename it and try again."
            case .destinationIsNotSymlink(let path):
                return "\(path) already exists and is not a symlink. Remove or rename it and try again."
            case .installVerificationFailed(let path):
                return "Installed symlink at \(path) did not point to the bundled danterm CLI."
            case .uninstallVerificationFailed(let path):
                return "Failed to remove \(path)."
            case .privilegedCommandFailed(let message):
                return "Administrator action failed: \(message)"
            }
        }
    }

    static let `default` = CLIPathInstaller()

    let deps: Dependencies

    init(_ deps: Dependencies = .default) {
        self.deps = deps
    }

    func install() throws -> InstallOutcome {
        guard !deps.bundleURL().path.contains("/AppTranslocation/") else {
            throw InstallerError.appTranslocated
        }

        let sourceURL = try resolveSourceURL()
        do {
            try installWithoutAdministratorPrivileges(sourceURL: sourceURL)
            return InstallOutcome(
                usedAdministratorPrivileges: false,
                destinationURL: deps.destinationURL,
                sourceURL: sourceURL
            )
        } catch {
            guard Self.isPermissionDenied(error) else { throw error }
            try ensureDestinationCanBeReplaced()
            try deps.privilegedRunner(installCommand(sourceURL: sourceURL))
            try verifyInstalledSymlinkTarget(sourceURL: sourceURL)
            return InstallOutcome(
                usedAdministratorPrivileges: true,
                destinationURL: deps.destinationURL,
                sourceURL: sourceURL
            )
        }
    }

    func uninstall() throws -> UninstallOutcome {
        do {
            let removed = try uninstallWithoutAdministratorPrivileges()
            return UninstallOutcome(
                usedAdministratorPrivileges: false,
                destinationURL: deps.destinationURL,
                removedExistingEntry: removed
            )
        } catch {
            guard Self.isPermissionDenied(error) else { throw error }
            try ensureDestinationCanBeReplaced()
            let removed = destinationEntryExists()
            try deps.privilegedRunner(uninstallCommand())
            if destinationEntryExists() {
                throw InstallerError.uninstallVerificationFailed(path: deps.destinationURL.path)
            }
            return UninstallOutcome(
                usedAdministratorPrivileges: true,
                destinationURL: deps.destinationURL,
                removedExistingEntry: removed
            )
        }
    }

    func isInstalled() -> Bool {
        guard let installedTargetURL = symlinkDestinationURL() else { return false }
        return installedTargetURL == deps.sourceURL().standardizedFileURL
    }

    private func resolveSourceURL() throws -> URL {
        let sourceURL = deps.sourceURL().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard deps.fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw InstallerError.bundledCLIMissing(expectedPath: sourceURL.path)
        }
        return sourceURL
    }

    private func installWithoutAdministratorPrivileges(sourceURL: URL) throws {
        try ensureDestinationParentDirectoryExists()
        try ensureDestinationCanBeReplaced()
        if destinationEntryExists() {
            try deps.fileManager.removeItem(at: deps.destinationURL)
        }
        try deps.fileManager.createSymbolicLink(at: deps.destinationURL, withDestinationURL: sourceURL)
        try verifyInstalledSymlinkTarget(sourceURL: sourceURL)
    }

    @discardableResult
    private func uninstallWithoutAdministratorPrivileges() throws -> Bool {
        try ensureDestinationCanBeReplaced()
        let existed = destinationEntryExists()
        if existed {
            try deps.fileManager.removeItem(at: deps.destinationURL)
        }
        if destinationEntryExists() {
            throw InstallerError.uninstallVerificationFailed(path: deps.destinationURL.path)
        }
        return existed
    }

    private func ensureDestinationParentDirectoryExists() throws {
        let parentURL = deps.destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if deps.fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw InstallerError.destinationParentNotDirectory(path: parentURL.path)
            }
            return
        }
        try deps.fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    }

    private func ensureDestinationCanBeReplaced() throws {
        guard let values = try resourceValuesIfFileExists(
            at: deps.destinationURL,
            keys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return
        }
        if values.isDirectory == true, values.isSymbolicLink != true {
            throw InstallerError.destinationIsDirectory(path: deps.destinationURL.path)
        }
        if values.isSymbolicLink != true {
            throw InstallerError.destinationIsNotSymlink(path: deps.destinationURL.path)
        }
    }

    private func verifyInstalledSymlinkTarget(sourceURL: URL) throws {
        guard symlinkDestinationURL() == sourceURL.standardizedFileURL else {
            throw InstallerError.installVerificationFailed(path: deps.destinationURL.path)
        }
    }

    /// Check for any filesystem entry, including dangling symlinks.
    private func destinationEntryExists() -> Bool {
        (try? deps.fileManager.attributesOfItem(atPath: deps.destinationURL.path)) != nil
    }

    private func symlinkDestinationURL() -> URL? {
        guard destinationEntryExists(),
              let destinationPath = try? deps.fileManager.destinationOfSymbolicLink(atPath: deps.destinationURL.path)
        else {
            return nil
        }
        return URL(
            fileURLWithPath: destinationPath,
            relativeTo: deps.destinationURL.deletingLastPathComponent()
        ).standardizedFileURL
    }

    private func resourceValuesIfFileExists(
        at url: URL,
        keys: Set<URLResourceKey>
    ) throws -> URLResourceValues? {
        do {
            return try url.resourceValues(forKeys: keys)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                return nil
            }
            if nsError.domain == NSPOSIXErrorDomain,
               POSIXErrorCode(rawValue: Int32(nsError.code)) == .ENOENT {
                return nil
            }
            throw error
        }
    }

    private func installCommand(sourceURL: URL) -> String {
        let destinationPath = deps.destinationURL.path
        let parentPath = deps.destinationURL.deletingLastPathComponent().path
        return "/bin/mkdir -p \(Self.shellQuoted(parentPath)) && " +
            "/bin/rm -f \(Self.shellQuoted(destinationPath)) && " +
            "/bin/ln -s \(Self.shellQuoted(sourceURL.path)) \(Self.shellQuoted(destinationPath))"
    }

    private func uninstallCommand() -> String {
        "/bin/rm -f \(Self.shellQuoted(deps.destinationURL.path))"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        isPermissionDenied(error as NSError)
    }

    private static func isPermissionDenied(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(error.code)),
           code == .EACCES || code == .EPERM || code == .EROFS {
            return true
        }

        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError:
                return true
            default:
                break
            }
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDenied(underlying)
        }
        return false
    }
}
