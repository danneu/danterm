// Swift Testing migration of the legacy `tests/CLIPathInstallerTests.swift`
// harness suite. Pins the injectable danterm PATH installer: writable-temp
// install, stale-symlink replacement, refusal on a non-symlink destination,
// refusal in an AppTranslocation bundle, EACCES-triggered privileged-runner
// fallback, uninstall idempotence, and isInstalled-on-mismatched-symlink.
// Each test uses a unique per-test temp dir (the InstallerFixture helper),
// so the suite is parallel-safe by construction -- no .serialized needed.
// The two `try ... ; throw TestFailure(...)` "expected error" patterns
// convert to `Issue.record + return` so the failure-site count stays exact.
import Foundation
import Darwin
import Synchronization
import Testing

@testable import DanTermSupport

@Suite struct CLIPathInstallerTests {
    @Test("install into writable temp target creates symlink")
    func installIntoWritableTempTargetCreatesSymlink() throws {
        // Intent: install on a writable temp dir creates a symlink at
        //   the destination pointing to the source binary.
        // Why it exists: pins the happy path with no privileged runner.
        // Scenario: spec-first plain install.
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        let installer = CLIPathInstaller(fixture.deps)
        let outcome = try installer.install()
        #expect(outcome.usedAdministratorPrivileges == false)
        #expect(fixture.symlinkTarget() == fixture.sourceURL.standardizedFileURL)
    }

    @Test("install replaces stale symlink")
    func installReplacesStaleSymlink() throws {
        // Intent: install replaces a pre-existing stale symlink at the
        //   destination.
        // Why it exists: pins the stale-symlink replace branch.
        // Scenario: spec-first stale replace.
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        let stale = fixture.root.appendingPathComponent("old-danterm")
        FileManager.default.createFile(atPath: stale.path, contents: Data("old".utf8))
        try FileManager.default.createSymbolicLink(at: fixture.destinationURL, withDestinationURL: stale)

        _ = try CLIPathInstaller(fixture.deps).install()
        #expect(fixture.symlinkTarget() == fixture.sourceURL.standardizedFileURL)
    }

    @Test("install refuses existing non-symlink destination")
    func installRefusesExistingNonSymlinkDestination() throws {
        // Intent: install refuses to overwrite a real file at the
        //   destination (only stale symlinks are replaceable).
        // Why it exists: pins the destinationIsNotSymlink guard.
        // Scenario: spec-first non-symlink destination.
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        FileManager.default.createFile(atPath: fixture.destinationURL.path, contents: Data("existing".utf8))
        do {
            _ = try CLIPathInstaller(fixture.deps).install()
            Issue.record("expected destinationIsNotSymlink error")
            return
        } catch CLIPathInstaller.InstallerError.destinationIsNotSymlink {
            return
        }
    }

    @Test("install refuses AppTranslocation bundle")
    func installRefusesAppTranslocationBundle() throws {
        // Intent: install refuses when the running bundle is under
        //   AppTranslocation (paths there are quarantined).
        // Why it exists: pins the appTranslocated guard.
        // Scenario: spec-first AppTranslocation bundle.
        let fixture = try makeInstallerFixture(bundlePath: "/private/var/folders/AppTranslocation/DanTerm.app")
        defer { fixture.cleanup() }
        do {
            _ = try CLIPathInstaller(fixture.deps).install()
            Issue.record("expected appTranslocated error")
            return
        } catch CLIPathInstaller.InstallerError.appTranslocated {
            return
        }
    }

    @Test("install permission error invokes privileged runner")
    func installPermissionErrorInvokesPrivilegedRunner() throws {
        // Intent: a permission error on the destination triggers the
        //   privileged runner; the install succeeds with
        //   usedAdministratorPrivileges == true.
        // Why it exists: pins the elevated install fallback contract.
        // Scenario: spec-first EACCES -> privileged.
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.destinationURL.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: fixture.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        chmod(fixture.destinationURL.deletingLastPathComponent().path, 0o500)
        defer { chmod(fixture.destinationURL.deletingLastPathComponent().path, 0o700) }

        let calls = Mutex<[String]>([])
        var deps = fixture.deps
        deps.privilegedRunner = { command in
            calls.withLock { $0.append(command) }
            chmod(fixture.destinationURL.deletingLastPathComponent().path, 0o700)
            try FileManager.default.createSymbolicLink(at: fixture.destinationURL, withDestinationURL: fixture.sourceURL)
        }

        let outcome = try CLIPathInstaller(deps).install()
        #expect(outcome.usedAdministratorPrivileges == true)
        #expect(calls.withLock { $0.count } == 1)
        #expect(fixture.symlinkTarget() == fixture.sourceURL.standardizedFileURL)
    }

    @Test("uninstall is idempotent")
    func uninstallIsIdempotent() throws {
        // Intent: uninstall on a never-installed target and a second
        //   uninstall both report removedExistingEntry == false.
        // Why it exists: pins the idempotent uninstall contract.
        // Scenario: spec-first idempotent uninstall.
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        let installer = CLIPathInstaller(fixture.deps)
        let first = try installer.uninstall()
        let second = try installer.uninstall()
        #expect(first.removedExistingEntry == false)
        #expect(second.removedExistingEntry == false)
    }

    @Test("isInstalled returns false for mismatched symlink")
    func isInstalledReturnsFalseForMismatchedSymlink() throws {
        // Intent: isInstalled returns false when the symlink at the
        //   destination points somewhere other than the bundle's
        //   helper.
        // Why it exists: pins the strict symlink-target check.
        // Scenario: spec-first mismatched-target.
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        let other = fixture.root.appendingPathComponent("other")
        FileManager.default.createFile(atPath: other.path, contents: Data("other".utf8))
        try FileManager.default.createSymbolicLink(at: fixture.destinationURL, withDestinationURL: other)
        #expect(CLIPathInstaller(fixture.deps).isInstalled() == false)
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
