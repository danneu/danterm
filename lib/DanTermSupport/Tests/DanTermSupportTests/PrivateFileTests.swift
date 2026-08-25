// Swift Testing suite for `PrivateFile`, the one seam that creates a file or a directory for
// the running product. The claims here are about modes and about what is left on disk, never
// about payloads: what gets written is each caller's business. It also owns `posixMode`, the
// mode reader the rest of this target's suites use.
import Darwin
import Foundation
import Testing

@testable import DanTermSupport

/// Reads the permission bits an artifact actually carries, without following a symlink.
/// Shared across this target's suites because "what mode is it" is now asked in several
/// places, and `FileManager` attribute dictionaries answer it far less directly.
func posixMode(of url: URL) throws -> mode_t {
    var status = stat()
    try #require(lstat(url.path, &status) == 0, "\(url.path) should exist")
    return status.st_mode & 0o777
}

/// A unique directory under the OS temp root, so every case is hermetic and parallel-safe.
private func makeTestRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-privatefile-\(UUID().uuidString)", isDirectory: true)
}

@Suite struct PrivateFileTests {
    @Test("a created directory and its missing parents are owner-only")
    func createdDirectoriesAreOwnerOnly() throws {
        let root = makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let leaf = root.appendingPathComponent("a/b/c", isDirectory: true)

        try PrivateFile.createDirectory(at: leaf)

        #expect(try posixMode(of: leaf) == 0o700)
        #expect(try posixMode(of: root.appendingPathComponent("a")) == 0o700)
    }

    @Test("creating a directory that already exists narrows it")
    func createDirectoryNarrowsAnExistingDirectory() throws {
        // Intent: an existing 0755 directory comes out of `createDirectory` at 0700.
        // Why it exists: the recovery directory is never recreated once it exists, so an
        //   instance upgrading from a build that made it 0755 would keep that mode for the
        //   rest of the directory's life if the seam only moded what it created (I3).
        // Scenario: the recovery directory a pre-fix build left behind.
        let root = makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )

        try PrivateFile.createDirectory(at: root)

        #expect(try posixMode(of: root) == 0o700)
    }

    @Test("creating a directory over a regular file fails instead of writing into it")
    func createDirectoryRefusesARegularFile() throws {
        let root = makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFile.createDirectory(at: root)
        let occupied = root.appendingPathComponent("occupied")
        try PrivateFile.createFile(Data("file".utf8), at: occupied)

        #expect(throws: (any Error).self) {
            try PrivateFile.createDirectory(at: occupied)
        }
    }

    @Test("a newly created file is owner-only and holds exactly what was written")
    func createdFilesAreOwnerOnly() throws {
        // Intent: `createFile` is the staging primitive an atomic write goes through, so its
        //   mode is the mode the temporary sibling carries for its whole life.
        // Why it exists: `Data.write(options: .atomic)` renames a sibling into place, so a
        //   mode applied after the write leaves the content nameable at the umask default
        //   twice over -- at the sibling's path, and at the final path (I2).
        // Scenario: spec-first staging of one checkpoint's bytes.
        let root = makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFile.createDirectory(at: root)
        let url = root.appendingPathComponent("staged")

        try PrivateFile.createFile(Data("scrollback".utf8), at: url)

        #expect(try posixMode(of: url) == 0o600)
        #expect(try String(decoding: Data(contentsOf: url), as: UTF8.self) == "scrollback")
    }

    @Test("creating a file that already exists fails and leaves the existing one alone")
    func createFileRefusesAnExistingPath() throws {
        let root = makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFile.createDirectory(at: root)
        let url = root.appendingPathComponent("staged")
        try PrivateFile.createFile(Data("first".utf8), at: url)

        #expect(throws: (any Error).self) {
            try PrivateFile.createFile(Data("second".utf8), at: url)
        }
        #expect(try String(decoding: Data(contentsOf: url), as: UTF8.self) == "first")
    }

    @Test("an atomic write replaces a world-readable file with an owner-only one")
    func atomicWriteNarrowsWhatItReplaces() throws {
        let root = makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFile.createDirectory(at: root)
        let url = root.appendingPathComponent("state.json")
        try Data("stale".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: url.path
        )

        try PrivateFile.writeAtomically(Data("fresh".utf8), to: url)

        #expect(try posixMode(of: url) == 0o600)
        #expect(try String(decoding: Data(contentsOf: url), as: UTF8.self) == "fresh")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["state.json"])
    }

    @Test("a failed atomic write keeps the previous file and removes its sibling")
    func failedAtomicWriteLeavesNothingBehind() throws {
        // Intent: when the rename cannot happen, the reader still sees the previous complete
        //   file and the directory holds no leftover staging file.
        // Why it exists: the staged sibling holds the same scrollback as the final path. One
        //   that outlived a failure would sit there until the next launch cleanup, which for
        //   the recovery directory never comes (I7).
        // Scenario: a destination path occupied by a non-empty directory, which no rename can
        //   replace.
        let root = makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("state.json", isDirectory: true)
        try PrivateFile.createDirectory(at: destination)
        try PrivateFile.createFile(Data("blocker".utf8), at: destination.appendingPathComponent("x"))

        #expect(throws: (any Error).self) {
            try PrivateFile.writeAtomically(Data("fresh".utf8), to: destination)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["state.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["x"])
    }
}
