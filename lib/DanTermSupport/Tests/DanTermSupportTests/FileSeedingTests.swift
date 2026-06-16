// Swift Testing suite for DanTermSupport's ensureFileExists -- the seed-if-missing
// helper that backs the "open config" / "save config key" flows. Covers the three
// behaviors that matter at the call sites: it creates a missing file (and its
// missing parent dir) with the given seed, it never clobbers an existing file, and
// a nil seed yields an empty file. Each test runs under a unique per-test temp dir
// that its defer removes, so the suite is hermetic and parallel-safe.
import Foundation
import Testing

@testable import DanTermSupport

/// Build a unique-per-test scratch directory under the OS temp dir. The caller's
/// defer removes it, so the suite remains hermetic.
private func makeTestDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-fileseeding-\(UUID().uuidString)", isDirectory: true)
}

@Suite struct FileSeedingTests {
    @Test("ensureFileExists creates a missing file and its missing parent dir with the seed")
    func createsMissingFileAndParentDir() throws {
        let base = makeTestDir()
        defer { try? FileManager.default.removeItem(at: base) }
        // A nested dir that does not exist yet, so the parent-dir branch runs.
        let path = base.appendingPathComponent("nested/config.txt").path
        let seed = "# seed contents\n"

        ensureFileExists(atPath: path, seed: Data(seed.utf8))

        #expect(FileManager.default.fileExists(atPath: path),
            "ensureFileExists should create the missing file under a missing parent dir")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents == seed, "the created file should hold exactly the given seed")
    }

    @Test("ensureFileExists is a no-op on an existing file and never clobbers its contents")
    func noOpOnExistingFile() throws {
        let base = makeTestDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let path = base.appendingPathComponent("config.txt").path
        let original = "user wrote this\n"
        try original.write(toFile: path, atomically: true, encoding: .utf8)

        ensureFileExists(atPath: path, seed: Data("# different seed\n".utf8))

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents == original,
            "ensureFileExists must not overwrite existing user content")
    }

    @Test("ensureFileExists with a nil seed creates an empty file")
    func nilSeedCreatesEmptyFile() throws {
        let base = makeTestDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("empty.txt").path

        ensureFileExists(atPath: path, seed: nil)

        #expect(FileManager.default.fileExists(atPath: path),
            "ensureFileExists should create the file even with a nil seed")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.isEmpty, "a nil seed should produce an empty file")
    }
}
