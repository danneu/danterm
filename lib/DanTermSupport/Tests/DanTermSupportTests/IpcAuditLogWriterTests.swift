// Filesystem coverage for the bounded, owner-only IPC audit JSONL writer.
import Darwin
import Foundation
import Testing

@testable import DanTermSupport

struct IpcAuditLogWriterTests {
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
        let entry = try JSONDecoder().decode(IpcAuditLogEntry.self, from: Data(lines[0]))
        #expect(entry.timestamp == instant)
        #expect(entry.event.kind == .connectionRefused)
        #expect(entry.event.reason == "not-admitted")
        var status = stat()
        try #require(lstat(writer.logURL.path, &status) == 0)
        #expect(status.st_mode & mode_t(0o777) == mode_t(0o600))
    }

    @Test("crossing the size bound preserves one rotated log")
    func sizeBoundRotatesOnce() throws {
        let directory = makeAuditDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = IpcAuditEvent.connectionClosed(
            transport: "tailnet",
            peerAddress: "100.98.63.67:49152",
            caller: .remote(nodeId: "node", user: "user", machineName: "machine")
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
}

private func makeAuditDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-audit-\(UUID().uuidString)", isDirectory: true)
}
