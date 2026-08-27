// Swift Testing migration of the legacy `tests/CLIPathInstallerTests.swift`
// harness suite. Pins the injectable danterm PATH installer: writable-temp
// install, stale-symlink replacement, refusal on a non-symlink destination,
// refusal in an AppTranslocation bundle, EACCES-triggered privileged-runner
// fallback, uninstall idempotence, and isInstalled-on-mismatched-symlink.
// Each test uses a unique per-test temp dir (the InstallerFixture helper),
// so the suite is parallel-safe by construction -- no .serialized needed.
// The one claim that cannot be made this way, that the created PATH directory
// is 0755 because the installer says so rather than because of the launching
// umask, lives in `CLIPathInstallerUmaskTests`: `umask` is per process, so
// those cases are serialized and no case here may assert a umask-derived mode.
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

    @Test("a bin directory the installer has to create is traversable by everyone")
    func createdDestinationParentIsWorldTraversable() throws {
        // Intent: when the destination's parent directory does not exist, the installer
        //   creates it 0755 -- the conventional mode of a directory on the PATH, stated
        //   rather than inherited, so the umask of whoever launched the app cannot
        //   change it.
        // Why it exists: the parent is a PATH directory holding one symlink to an
        //   executable, so it belongs to the same umask-default class as the symlink and
        //   the config directory, not to the private class the seam creates. It used to
        //   be 0700, which left an owner-only directory on a PATH other accounts and
        //   installers traverse, and made the mode depend on which install branch ran
        //   first: the privileged branch's root `mkdir -p` has always produced 0755.
        // Scenario: a first install on a machine with no personal bin directory yet.
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        let binDirectory = fixture.destinationURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: binDirectory)

        _ = try CLIPathInstaller(fixture.deps).install()

        #expect(try posixMode(of: binDirectory) == 0o755)
        #expect(fixture.symlinkTarget() == fixture.sourceURL.standardizedFileURL)
    }

    @Test("an existing bin directory keeps the mode it already had")
    func existingDestinationParentModeIsUntouched() throws {
        // Intent: the installer does not change the mode of a parent directory that
        //   already exists, in either direction.
        // Why it exists: the parent is usually the user's own `/usr/local/bin`, made by
        //   Homebrew or by hand. Stating a mode for a directory this process creates is
        //   not a licence to restate it for one it found, and `ensureDestinationParent-
        //   DirectoryExists` returns early precisely so that stays true.
        // Scenario: installing into a `/usr/local/bin` that Homebrew created.
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        let binDirectory = fixture.destinationURL.deletingLastPathComponent()
        #expect(chmod(binDirectory.path, 0o700) == 0)

        _ = try CLIPathInstaller(fixture.deps).install()

        #expect(try posixMode(of: binDirectory) == 0o700)
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
