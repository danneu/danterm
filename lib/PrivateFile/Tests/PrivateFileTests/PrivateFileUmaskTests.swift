// The one claim in this target that has to move a process-wide setting: that the mode an
// artifact is born with is a property of the seam and not of the environment the process
// was launched in. It sits apart from `PrivateFileTests` because everything about it --
// the serialization, the restore, the reason the window is safe -- is bookkeeping the
// ordinary mode cases do not carry.
import Darwin
import Foundation
import Testing

import PrivateFile

/// Pins that the seam states its modes rather than inheriting them, by creating under a
/// umask that would otherwise mask the owner bits away.
///
/// Nothing else proves this: under the umask a gate run inherits, deleting the seam's
/// post-create `fchmod` / `chmod` leaves every other case in this target green, so the
/// second step of each create would be free to disappear.
///
/// `umask` is per process, not per test, so the cases are serialized and each one restores
/// what it found. The window is still shared with whatever runs beside them, and that is
/// safe here for a reason worth stating: every other artifact this target creates is made
/// either through the seam, which states its mode outright, or by a `write` the case
/// follows with an explicit `setAttributes`. Neither reads the umask, so neither can see
/// this one.
@Suite(.serialized) struct PrivateFileUmaskTests {
    /// A mask that would clear every permission bit an `open` or `mkdir` asked for, so an
    /// artifact that reaches 0600 or 0700 under it can only have been moded afterwards.
    private static let maskingEverything: mode_t = 0o777

    private func withMaskingUmask<T>(_ body: () throws -> T) rethrows -> T {
        let previous = umask(Self.maskingEverything)
        defer { umask(previous) }
        return try body()
    }

    @Test("a file created under an owner-masking umask still carries exactly 0600")
    func createdFileIgnoresTheUmask() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-umask-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFile.createDirectory(at: root)
        let url = root.appendingPathComponent("staged")

        try withMaskingUmask { try PrivateFile.createFile(Data("scrollback".utf8), at: url) }

        #expect(try posixMode(of: url) == 0o600)
    }

    @Test("a directory created under an owner-masking umask still carries exactly 0700")
    func createdDirectoryIgnoresTheUmask() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-umask-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let leaf = root.appendingPathComponent("a/b", isDirectory: true)

        try withMaskingUmask { try PrivateFile.createDirectory(at: leaf) }

        #expect(try posixMode(of: leaf) == 0o700)
        #expect(try posixMode(of: root.appendingPathComponent("a")) == 0o700)
    }
}
