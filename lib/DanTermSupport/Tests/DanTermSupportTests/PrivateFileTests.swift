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

/// A unique directory directly under `/tmp`, because a `sockaddr_un` path is capped at 104
/// bytes and the OS temp root spends most of that before a test name is added.
private func makeShortTestRoot() -> URL {
    URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("dt-pf-\(UUID().uuidString)", isDirectory: true)
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

    @Test("an appended-to file is owner-only, whether it was created or found")
    func appendTargetsAreOwnerOnly() throws {
        // Intent: `openForAppending` creates its file at 0600 and narrows one that already
        //   exists at a broader mode, keeping the bytes that were there.
        // Why it exists: the audit log and the harness samplers keep a descriptor open across
        //   many writes, so the mode is stated once at open and never again. A found file left
        //   as it was would carry a pre-fix build's mode for the rest of its life (I1, I3).
        // Scenario: spec-first, plus the upgrade case an existing 0644 log presents.
        let root = makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFile.createDirectory(at: root)
        let created = root.appendingPathComponent("fresh.jsonl")
        let found = root.appendingPathComponent("stale.jsonl")
        try Data("old\n".utf8).write(to: found)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: found.path
        )

        let createdDescriptor = try PrivateFile.openForAppending(at: created)
        Darwin.close(createdDescriptor)
        let foundDescriptor = try PrivateFile.openForAppending(at: found)
        Darwin.close(foundDescriptor)

        #expect(try posixMode(of: created) == 0o600)
        #expect(try posixMode(of: found) == 0o600)
        #expect(try String(decoding: Data(contentsOf: found), as: UTF8.self) == "old\n")
    }

    @Test("a lock file is owner-only and keeps its identity across opens")
    func lockFilesAreOwnerOnly() throws {
        // Intent: `openForLocking` creates its file at 0600 and reopens the same inode.
        // Why it exists: the socket replacement lock is what serializes two instances racing
        //   for one socket path. A lock file that a second opener replaced rather than reopened
        //   would let both sides hold "the" lock at once.
        // Scenario: spec-first, two sequential opens of one lock path.
        let root = makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFile.createDirectory(at: root)
        let url = root.appendingPathComponent("control.sock.lock")

        let first = try PrivateFile.openForLocking(at: url)
        let firstIdentity = try inode(of: first)
        Darwin.close(first)
        let second = try PrivateFile.openForLocking(at: url)
        let secondIdentity = try inode(of: second)
        Darwin.close(second)

        #expect(try posixMode(of: url) == 0o600)
        #expect(firstIdentity == secondIdentity)
    }

    @Test("an empty marker file is owner-only, and narrows one left behind at 0644")
    func markerFilesAreOwnerOnly() throws {
        let root = makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFile.createDirectory(at: root)
        let created = root.appendingPathComponent("start.ack")
        let found = root.appendingPathComponent("draw.ack")
        try Data().write(to: found)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: found.path
        )

        try PrivateFile.createEmptyFile(atPath: created.path)
        try PrivateFile.createEmptyFile(atPath: found.path)

        #expect(try posixMode(of: created) == 0o600)
        #expect(try posixMode(of: found) == 0o600)
    }

    @Test("the bound socket the seam returns already carries 0600")
    func boundSocketIsOwnerOnlyBeforeItListens() throws {
        // Intent: the node carries 0600 the moment `bindSocket` returns, which is before any
        //   caller has had the chance to listen on it.
        // Why it exists: the control socket used to be chmod'd after `listen()`, so it spent
        //   the window between the two calls accepting connections at `0777 & ~umask`
        //   (DT-SEC-15). Reading the mode after `ControlSocketListener.open` has finished
        //   passes under either ordering, which is how that window survived (I5, PO6). This
        //   reads it at the seam's boundary instead, and pins that a peer cannot yet connect.
        // Scenario: the DT-SEC-15 report, stopped at the moment the caller first has the fd.
        let root = makeShortTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFile.createDirectory(at: root)
        let url = root.appendingPathComponent("control.sock")

        let descriptor = try PrivateFile.bindSocket(at: url)
        defer { Darwin.close(descriptor) }

        var status = stat()
        try #require(lstat(url.path, &status) == 0)
        #expect(status.st_mode & 0o777 == 0o600)
        #expect(status.st_mode & S_IFMT == S_IFSOCK)
        #expect(connectionRefused(at: url), "the returned socket must not be listening yet")
    }

    @Test("binding a socket over an occupied path fails and leaves that path alone")
    func bindSocketRefusesAnOccupiedPath() throws {
        let root = makeShortTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateFile.createDirectory(at: root)
        let url = root.appendingPathComponent("control.sock")
        try PrivateFile.createFile(Data("occupied".utf8), at: url)

        #expect(throws: (any Error).self) {
            let descriptor = try PrivateFile.bindSocket(at: url)
            Darwin.close(descriptor)
        }
        #expect(try String(decoding: Data(contentsOf: url), as: UTF8.self) == "occupied")
    }
}

/// Reports whether a peer's connect is refused, which for a bound path means nothing has
/// called `listen` on it yet.
private func connectionRefused(at url: URL) -> Bool {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    guard var address = try? unixSocketAddress(for: url) else { return false }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    return result != 0 && errno == ECONNREFUSED
}

/// Reads the inode a descriptor names, so a test can say two opens found the same file.
private func inode(of descriptor: Int32) throws -> ino_t {
    var status = stat()
    try #require(fstat(descriptor, &status) == 0)
    return status.st_ino
}
