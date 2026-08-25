// Filesystem coverage for the bounded, owner-only IPC audit JSONL writer.
import Darwin
import Foundation
import Testing

@testable import DanTermSupport

struct IpcAuditLogWriterTests {
    @Test("prepare proves the sink is writable without adding an audit event")
    func prepareCreatesPrivateEmptySink() throws {
        let directory = makeAuditDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = IpcAuditLogWriter(directory: directory)

        try writer.prepare()

        let attributes = try FileManager.default.attributesOfItem(atPath: writer.logURL.path)
        #expect((attributes[.size] as? NSNumber)?.intValue == 0)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("append writes one timestamped JSON line with mode 0600")
    func appendWritesPrivateJSONLine() throws {
        let directory = makeAuditDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let writer = IpcAuditLogWriter(directory: directory, now: { instant }, maximumBytes: 4096)

        try writer.append(.connectionRefused(
            transport: "tailnet",
            peerAddress: "100.98.63.67:49152",
            reason: "not-admitted"
        ))

        let data = try Data(contentsOf: writer.logURL)
        let lines = data.split(separator: 0x0A)
        #expect(lines.count == 1)
        let encoded = String(decoding: lines[0], as: UTF8.self)
        #expect(encoded.contains("\"timestamp\":\"2023-11-14T22:13:20Z\""))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(IpcAuditLogEntry.self, from: Data(lines[0]))
        #expect(entry.timestamp == instant)
        #expect(entry.event.kind == .connectionRefused)
        #expect(entry.event.reason == "not-admitted")
        var status = stat()
        try #require(lstat(writer.logURL.path, &status) == 0)
        #expect(status.st_mode & mode_t(0o777) == mode_t(0o600))
    }

    @Test("the same entry has deterministic key order and bytes")
    func entryEncodingIsDeterministic() throws {
        let directory = makeAuditDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let writer = IpcAuditLogWriter(directory: directory, now: { instant }, maximumBytes: 4096)
        let event = IpcAuditEvent.connectionRefused(
            transport: "tailnet",
            peerAddress: "100.98.63.67:49152",
            reason: "not-admitted"
        )

        try writer.append(event)
        try writer.append(event)

        let lines = try Data(contentsOf: writer.logURL).split(separator: 0x0A)
        #expect(lines.count == 2)
        #expect(lines[0] == lines[1])
    }

    @Test("crossing the size bound preserves one rotated log")
    func sizeBoundRotatesOnce() throws {
        let directory = makeAuditDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = IpcAuditEvent.connectionClosed(
            transport: "tailnet",
            peerAddress: "100.98.63.67:49152",
            caller: .remote(nodeId: "node", user: "user", machineName: "machine"),
            reason: .peerClosed,
            servedRequests: 3
        )
        let measuringWriter = IpcAuditLogWriter(
            directory: directory,
            now: { instant },
            maximumBytes: 4096
        )
        try measuringWriter.append(sample)
        let oneLineSize = try Data(contentsOf: measuringWriter.logURL).count
        try FileManager.default.removeItem(at: directory)

        let writer = IpcAuditLogWriter(
            directory: directory,
            now: { instant },
            maximumBytes: oneLineSize + 1
        )
        try writer.append(sample)
        try writer.append(sample)

        #expect(FileManager.default.fileExists(atPath: writer.rotatedLogURL.path))
        #expect(try Data(contentsOf: writer.rotatedLogURL).split(separator: 0x0A).count == 1)
        #expect(try Data(contentsOf: writer.logURL).split(separator: 0x0A).count == 1)
    }

    @Test("one entry larger than the bound is refused")
    func oversizedEntryIsRefused() {
        let directory = makeAuditDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = IpcAuditLogWriter(directory: directory, maximumBytes: 64)

        #expect(throws: IpcAuditLogWriter.Error.entryTooLarge) {
            try writer.append(.listenerFailed(reason: String(repeating: "x", count: 256)))
        }
        #expect(FileManager.default.fileExists(atPath: writer.logURL.path) == false)
    }

    @Test("the log, its rotated predecessor, and the directory holding them are owner-only")
    func rotationKeepsEveryArtifactPrivate() throws {
        // Intent: after a rotation, both the live log and the sibling it was renamed to carry
        //   0600, inside a 0700 directory.
        // Why it exists: the rotated file is a full copy of the log's contents under a second
        //   name, and the directory used to be the only thing standing between an audit trail
        //   of every IPC caller and any other account on the machine (I1).
        // Scenario: spec-first -- a writer bounded just above one line, appended to twice.
        let directory = makeAuditDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = IpcAuditEvent.listenerBound(endpoint: "127.0.0.1:7777")
        let sizingWriter = IpcAuditLogWriter(directory: directory, now: { instant })
        try sizingWriter.append(sample)
        let oneLineSize = try Data(contentsOf: sizingWriter.logURL).count
        try FileManager.default.removeItem(at: sizingWriter.logURL)
        let writer = IpcAuditLogWriter(
            directory: directory,
            now: { instant },
            maximumBytes: oneLineSize + 1
        )

        try writer.append(sample)
        try writer.append(sample)

        #expect(try posixMode(of: writer.logURL) == 0o600)
        #expect(try posixMode(of: writer.rotatedLogURL) == 0o600)
        #expect(try posixMode(of: directory) == 0o700)
    }

    @Test("a log and a directory left behind at 0644 are narrowed by the next append")
    func appendNarrowsWhatAPreviousBuildLeft() throws {
        // Intent: an audit log and its directory that already exist at a broader mode come out
        //   of one append at 0600 and 0700.
        // Why it exists: neither is ever recreated once it exists, so an instance upgrading
        //   from a build that made them world-readable would keep those modes forever unless
        //   the write narrows what it finds (I3).
        // Scenario: the audit directory a pre-fix build left on disk.
        let directory = makeAuditDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
        let writer = IpcAuditLogWriter(directory: directory)
        try Data("{}\n".utf8).write(to: writer.logURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: writer.logURL.path
        )

        try writer.append(.listenerBound(endpoint: "127.0.0.1:7777"))

        #expect(try posixMode(of: writer.logURL) == 0o600)
        #expect(try posixMode(of: directory) == 0o700)
    }
}

private func makeAuditDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-audit-\(UUID().uuidString)", isDirectory: true)
}
