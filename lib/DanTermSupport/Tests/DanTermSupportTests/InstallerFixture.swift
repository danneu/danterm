// The temp-directory fixture the CLI installer suites share. It lives apart from
// `CLIPathInstallerTests` because a second suite needs it: the umask cases have to be
// serialized, so they cannot sit in the parallel suite, and a fixture private to one
// file would have to be written twice.
import Foundation
import Darwin

@testable import DanTermSupport

/// A throwaway `bin` directory, a stand-in bundle, and the injected dependencies that
/// point the installer at both, so no case touches the real `/usr/local/bin`.
struct InstallerFixture {
    let root: URL
    let sourceURL: URL
    let destinationURL: URL
    let deps: CLIPathInstaller.Dependencies

    func cleanup() {
        chmod(destinationURL.deletingLastPathComponent().path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }

    func symlinkTarget() -> URL? {
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: destinationURL.path) else {
            return nil
        }
        return URL(fileURLWithPath: path, relativeTo: destinationURL.deletingLastPathComponent()).standardizedFileURL
    }
}

func makeInstallerFixture(bundlePath: String? = nil) throws -> InstallerFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-installer-\(UUID().uuidString)", isDirectory: true)
    let binDir = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("DanTerm.app/Contents/Helpers/danterm")
    try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: sourceURL.path, contents: Data("cli".utf8))
    let destinationURL = binDir.appendingPathComponent("danterm")
    let deps = CLIPathInstaller.Dependencies(
        destinationURL: destinationURL,
        sourceURL: { sourceURL },
        bundleURL: { URL(fileURLWithPath: bundlePath ?? root.appendingPathComponent("DanTerm.app").path) },
        privilegedRunner: { _ in }
    )
    return InstallerFixture(root: root, sourceURL: sourceURL, destinationURL: destinationURL, deps: deps)
}
