// The one claim about the CLI installer that has to move a process-wide setting: that the
// PATH directory it creates is 0755 because the installer says so, not because the app
// happened to be launched under a permissive umask. It sits apart from
// `CLIPathInstallerTests` for the reason `PrivateFileUmaskTests` sits apart from
// `PrivateFileTests` -- the serialization, the restore, and the argument that the shared
// window is safe are bookkeeping the ordinary cases do not carry.
import Foundation
import Darwin
import Testing

@testable import DanTermSupport

/// Pins that both install branches state 0755 rather than inheriting it, by installing
/// under a umask that would otherwise mask the group and other bits away.
///
/// Nothing else proves this: under the umask a gate run inherits (022), deleting the
/// unprivileged branch's post-create `chmod` or the privileged branch's `-m 755` leaves
/// every other installer case green, so either could silently disappear -- and the mode
/// this fixes was exactly that, a directory whose mode followed whoever launched the app.
///
/// `umask` is per process, not per test, so the cases are serialized and each restores what
/// it found. The window is still shared with whatever runs beside them, and that is safe
/// here for a reason worth stating: every other mode assertion in this target names a mode
/// the code states outright -- the seam's 0600/0700, or an explicit `setAttributes` -- and
/// none is umask-derived, so none can observe this one. A case that asserts a umask-derived
/// mode belongs in this suite, not beside them -- `.serialized` orders these cases against
/// each other, not against another suite running at the same time. That is measured, not
/// assumed: deleting the unprivileged branch's `chmod` makes the parallel suite's 0755 case
/// umask-derived, and it then fails on this suite's window rather than on its own subject.
@Suite(.serialized) struct CLIPathInstallerUmaskTests {
    /// Clears the group and other bits an unmoded `mkdir` would have asked for, so a
    /// directory that reaches 0755 under it can only have been moded on purpose.
    private static let maskingGroupAndOther: mode_t = 0o077

    private func withRestrictiveUmask<T>(_ body: () throws -> T) rethrows -> T {
        let previous = umask(Self.maskingGroupAndOther)
        defer { umask(previous) }
        return try body()
    }

    @Test("the unprivileged branch creates the bin directory 0755 under a restrictive umask")
    func unprivilegedBranchStatesTheMode() throws {
        // Intent: the parent the ordinary install path creates is 0755 even when the umask
        //   would mask the group and other bits away.
        // Why it exists: this is the whole reason the mode is stated instead of left to the
        //   umask. `FileManager.createDirectory` alone is umask-masked, so an app launched
        //   from a shell with `umask 077` would recreate the owner-only directory this
        //   behavior replaced.
        // Scenario: a developer launches a dev slot from a shell that sets `umask 077`.
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        let binDirectory = fixture.destinationURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: binDirectory)

        try withRestrictiveUmask {
            _ = try CLIPathInstaller(fixture.deps).install()
        }

        #expect(try posixMode(of: binDirectory) == 0o755)
    }

    @Test("the privileged branch creates the bin directory 0755 under a restrictive umask")
    func privilegedBranchStatesTheMode() throws {
        // Intent: the shell command the privileged branch hands to the administrator runner
        //   produces the same 0755 the unprivileged branch does, under the same umask.
        // Why it exists: the two branches disagreeing about this directory's mode is the
        //   defect being fixed, so one branch proving it is not enough. The command is run
        //   here for real, by `/bin/sh`, rather than matched as a string: `mkdir`'s own
        //   treatment of `-m` under `-p` is the thing being relied on. The privileged
        //   runner escalates in production, and nothing pins the umask a setuid trampoline
        //   inherits, so the mode has to be in the command rather than assumed around it.
        // Scenario: a first install on a machine where `/usr/local/bin` needs an
        //   administrator to create, launched from a shell that sets `umask 077`.
        let fixture = try makeInstallerFixture()
        defer { fixture.cleanup() }
        let binDirectory = fixture.destinationURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: binDirectory)
        // The unprivileged branch has to fail before the privileged one is reached, so the
        // directory it would create in is made unwritable. The runner restores that first,
        // which is what the real escalation buys, and then runs the command verbatim.
        #expect(chmod(fixture.root.path, 0o500) == 0)
        defer { chmod(fixture.root.path, 0o700) }
        var deps = fixture.deps
        deps.privilegedRunner = { command in
            #expect(chmod(fixture.root.path, 0o700) == 0)
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", command]
            try shell.run()
            shell.waitUntilExit()
            #expect(shell.terminationStatus == 0)
        }

        let outcome = try withRestrictiveUmask {
            try CLIPathInstaller(deps).install()
        }
        #expect(outcome.usedAdministratorPrivileges == true)

        #expect(try posixMode(of: binDirectory) == 0o755)
        #expect(fixture.symlinkTarget() == fixture.sourceURL.standardizedFileURL)
    }
}
