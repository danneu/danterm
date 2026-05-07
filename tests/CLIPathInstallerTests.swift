// Tests for the injectable danterm PATH installer.
import Foundation
import Darwin

func cliPathInstallerTests() {
    print("CLI path installer tests:")

    test("install into writable temp target creates symlink") {
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        let installer = CLIPathInstaller(fixture.deps)
        let outcome = try installer.install()
        try expectEqual(outcome.usedAdministratorPrivileges, false)
        try expectEqual(fixture.symlinkTarget(), fixture.sourceURL.standardizedFileURL)
    }

    test("install replaces stale symlink") {
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        let stale = fixture.root.appendingPathComponent("old-danterm")
        FileManager.default.createFile(atPath: stale.path, contents: Data("old".utf8))
        try FileManager.default.createSymbolicLink(at: fixture.destinationURL, withDestinationURL: stale)

        _ = try CLIPathInstaller(fixture.deps).install()
        try expectEqual(fixture.symlinkTarget(), fixture.sourceURL.standardizedFileURL)
    }

    test("install refuses existing non-symlink destination") {
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        FileManager.default.createFile(atPath: fixture.destinationURL.path, contents: Data("existing".utf8))
        do {
            _ = try CLIPathInstaller(fixture.deps).install()
            throw TestFailure(message: "expected destinationIsNotSymlink error")
        } catch CLIPathInstaller.InstallerError.destinationIsNotSymlink {
            return
        }
    }

    test("install refuses AppTranslocation bundle") {
        let fixture = try makeInstallerFixture(bundlePath: "/private/var/folders/AppTranslocation/DanTerm.app")
        defer { fixture.cleanup() }
        do {
            _ = try CLIPathInstaller(fixture.deps).install()
            throw TestFailure(message: "expected appTranslocated error")
        } catch CLIPathInstaller.InstallerError.appTranslocated {
            return
        }
    }

    test("install permission error invokes privileged runner") {
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.destinationURL.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: fixture.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        chmod(fixture.destinationURL.deletingLastPathComponent().path, 0o500)
        defer { chmod(fixture.destinationURL.deletingLastPathComponent().path, 0o700) }

        var calls: [String] = []
        var deps = fixture.deps
        deps.privilegedRunner = { command in
            calls.append(command)
            chmod(fixture.destinationURL.deletingLastPathComponent().path, 0o700)
            try FileManager.default.createSymbolicLink(at: fixture.destinationURL, withDestinationURL: fixture.sourceURL)
        }

        let outcome = try CLIPathInstaller(deps).install()
        try expectEqual(outcome.usedAdministratorPrivileges, true)
        try expectEqual(calls.count, 1)
        try expectEqual(fixture.symlinkTarget(), fixture.sourceURL.standardizedFileURL)
    }

    test("uninstall is idempotent") {
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        let installer = CLIPathInstaller(fixture.deps)
        let first = try installer.uninstall()
        let second = try installer.uninstall()
        try expectEqual(first.removedExistingEntry, false)
        try expectEqual(second.removedExistingEntry, false)
    }

    test("isInstalled returns false for mismatched symlink") {
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        let other = fixture.root.appendingPathComponent("other")
        FileManager.default.createFile(atPath: other.path, contents: Data("other".utf8))
        try FileManager.default.createSymbolicLink(at: fixture.destinationURL, withDestinationURL: other)
        try expectEqual(CLIPathInstaller(fixture.deps).isInstalled(), false)
    }
}

private struct InstallerFixture {
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

private func makeInstallerFixture(bundlePath: String? = nil) throws -> InstallerFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-installer-\(UUID().uuidString)", isDirectory: true)
    let binDir = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("DanTerm.app/Contents/MacOS/danterm")
    try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: sourceURL.path, contents: Data("cli".utf8))
    let destinationURL = binDir.appendingPathComponent("danterm")
    let deps = CLIPathInstaller.Dependencies(
        destinationURL: destinationURL,
        sourceURL: { sourceURL },
        bundleURL: { URL(fileURLWithPath: bundlePath ?? root.appendingPathComponent("DanTerm.app").path) },
        fileManager: .default,
        privilegedRunner: { _ in }
    )
    return InstallerFixture(root: root, sourceURL: sourceURL, destinationURL: destinationURL, deps: deps)
}
