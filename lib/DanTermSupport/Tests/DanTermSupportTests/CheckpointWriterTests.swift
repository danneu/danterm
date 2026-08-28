// Swift Testing suite for `CheckpointWriter` -- the serial queue that encodes and writes a
// recovery checkpoint as one work item. The claims are about scheduling, not payloads: a write
// never encodes on its caller's thread, submitted writes land in submission order, and both the
// synchronous write and `drain()` fence everything already queued. Each test supplies its own
// trivial `encode` closure, because the writer is deliberately ignorant of what it writes.
import Foundation
import Testing

@testable import DanTermSupport

/// A unique-per-test checkpoint directory under the OS temp dir, so the suite stays hermetic and
/// parallel-safe. The test creates it, because the writer creates no directory: in the app the
/// recovery directory comes from `writeSessionLockFile` and the export destination from the user.
/// The caller's defer removes it.
private func makeTestCheckpointDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-checkpointwriter-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Records what a write's encode closure observed, from whichever thread ran it.
private final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [ObjectIdentifier] = []

    func recordCurrentThread() {
        let id = ObjectIdentifier(Thread.current)
        lock.lock()
        threads.append(id)
        lock.unlock()
    }

    var recorded: [ObjectIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        return threads
    }
}

@Suite struct CheckpointWriterTests {
    @Test("an async write encodes off the calling thread")
    func asyncWriteEncodesOffTheCallingThread() throws {
        // Intent: the encode closure handed to an async write runs on the writer's queue, never
        //   on the thread that submitted it.
        // Why it exists: periodic checkpoint projection, truncation, and encoding must stay off
        //   the main thread. A capture that defers its reads buys nothing if the caller turns
        //   around and runs the deferred work itself. Taking the encode as a parameter rather
        //   than bytes is what forecloses that, and this proves the writer honours it.
        // Scenario: spec-first. One async write; the encode reports which thread ran it.
        let dir = try makeTestCheckpointDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = CheckpointWriter(label: "danterm.test.checkpoint.off-thread")
        let observations = Observations()

        writer.write(to: dir.appendingPathComponent("checkpoint.json"), async: true) {
            observations.recordCurrentThread()
            return Data("payload".utf8)
        }
        writer.drain()

        let caller = ObjectIdentifier(Thread.current)
        #expect(observations.recorded.count == 1)
        #expect(observations.recorded.first != caller, "the encode must not run on the submitting thread")
    }

    @Test("writes land in submission order")
    func writesLandInSubmissionOrder() throws {
        // Intent: of two writes to the same path, the one submitted second is the one left on
        //   disk -- even when the first is still encoding as the second arrives.
        // Why it exists: enriched checkpoint writes must land in capture order so an earlier
        //   capture can never overwrite a later one. The failure is silent: an earlier capture
        //   finishing last leaves stale recovery state. One serial queue with encode and write
        //   in the same work item prevents it; splitting the stages across queues would not.
        // Scenario: spec-first. Write A's encode blocks until write B has been submitted, so B
        //   is queued and ready while A is mid-flight.
        let dir = try makeTestCheckpointDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("checkpoint.json")
        let writer = CheckpointWriter(label: "danterm.test.checkpoint.order")
        let secondSubmitted = DispatchSemaphore(value: 0)

        writer.write(to: url, async: true) {
            secondSubmitted.wait()
            return Data("A".utf8)
        }
        writer.write(to: url, async: true) { Data("B".utf8) }
        secondSubmitted.signal()
        writer.drain()

        #expect(try String(decoding: Data(contentsOf: url), as: UTF8.self) == "B")
    }

    @Test("a synchronous write drains the writes queued before it")
    func synchronousWriteDrainsEarlierWrites() throws {
        // Intent: a synchronous write returns only after every write submitted before it has
        //   finished, and leaves its own payload on disk.
        // Why it exists: this is what the quit checkpoint stands on. `applicationWillTerminate`
        //   runs the last checkpoint synchronously and the process exits immediately after; an
        //   async write still in flight at that moment either loses its own payload or lands
        //   after the final one. The quit checkpoint must drain all in-flight work before
        //   returning, and nothing else enforces that fence.
        // Scenario: spec-first. An async write is queued, then a synchronous write follows.
        let dir = try makeTestCheckpointDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("checkpoint.json")
        let earlier = dir.appendingPathComponent("earlier.json")
        let writer = CheckpointWriter(label: "danterm.test.checkpoint.sync")

        writer.write(to: earlier, async: true) { Data("earlier".utf8) }
        writer.write(to: url, async: false) { Data("final".utf8) }

        #expect(FileManager.default.fileExists(atPath: earlier.path),
                "the queued write must have completed before the synchronous one returned")
        #expect(try String(decoding: Data(contentsOf: url), as: UTF8.self) == "final")
    }

    @Test("a failed encode reports failure and leaves no file")
    func failedEncodeReportsFailure() async throws {
        // Intent: an encode that throws reports a failure carrying the error's text, and
        //   writes nothing.
        // Why it exists: the completion drives the recovery policy's retry/backoff state, so a
        //   failure reported as success would stall the policy on a checkpoint that never
        //   landed. Moving the encode inside the work item is what made encode failures visible
        //   to this path at all -- before, encoding threw on the caller's side. The description
        //   matters too: state export puts it in front of the user, who needs the reason.
        // Scenario: spec-first. The encode closure throws.
        struct EncodeFailure: Error {}
        let dir = try makeTestCheckpointDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("checkpoint.json")
        let writer = CheckpointWriter(label: "danterm.test.checkpoint.failure")

        // The test awaits rather than blocking, so the main queue keeps running and can deliver
        // the completion. A semaphore here would deadlock against the writer's own delivery.
        let outcome: CheckpointWriteOutcome = await withCheckedContinuation { continuation in
            writer.write(to: url, async: true, encode: {
                throw EncodeFailure()
            }, completion: { result in
                continuation.resume(returning: result)
            })
        }

        #expect(outcome.isSucceeded == false)
        guard case .failed(let description) = outcome else {
            Issue.record("expected a failure outcome, got \(outcome)")
            return
        }
        #expect(description.isEmpty == false, "a failure must say why, not just that it failed")
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test("a completion is delivered on the main thread")
    func completionIsDeliveredOnTheMainThread() async throws {
        // Intent: the writer calls a completion on the main thread, whoever built the writer.
        // Why it exists: the completion is typed `@MainActor`, and `MainActor.assumeIsolated`
        //   inside the writer is what lets it be. That trades a compiler check for a runtime
        //   one: if the delivery queue ever stops being the main queue, the annotation becomes
        //   a lie and every completion trips an isolation trap instead of failing to build.
        //   This is the test that would catch that, so it pins the delivery thread by name.
        // Scenario: spec-first. One successful async write reports which thread called back.
        let dir = try makeTestCheckpointDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = CheckpointWriter(label: "danterm.test.checkpoint.main-delivery")

        let onMainThread: Bool = await withCheckedContinuation { continuation in
            writer.write(to: dir.appendingPathComponent("checkpoint.json"), async: true, encode: {
                Data("payload".utf8)
            }, completion: { _ in
                continuation.resume(returning: Thread.isMainThread)
            })
        }

        #expect(onMainThread, "completions must land on the main thread the @MainActor type claims")
    }
}

@Suite struct CheckpointWriterPrivacyTests {
    @Test("a written checkpoint is reachable only by its owner")
    func checkpointIsPrivate() throws {
        // Intent: a written checkpoint holds 0600.
        // Why it exists: the enriched tier holds every pane's scrollback and was written at
        //   the umask default (DT-SEC-03), which on a shared machine let any local user read
        //   the terminal history of every pane.
        // Scenario: the incident Ghostty shipped as GHSA-hfg5-8q2c-crhc, spelled out here.
        let dir = try makeTestCheckpointDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("checkpoint.json")
        let writer = CheckpointWriter(label: "danterm.test.checkpoint.private")

        writer.write(to: url, async: false) { Data("scrollback".utf8) }

        #expect(try posixMode(of: url) == 0o600)
    }

    @Test("a checkpoint write narrows the file it finds and leaves its directory alone")
    func checkpointNarrowsWhatItFinds() throws {
        // Intent: an existing 0644 checkpoint comes out at 0600, and the 0755 directory
        //   holding it keeps 0755.
        // Why it exists: an upgraded instance meets the files its previous build left, and
        //   those are the ones already holding scrollback. The directory is a different
        //   matter: a state export writes into a folder the user picked, so narrowing it
        //   would change the mode of a directory the app does not own -- and would fail
        //   outright on a folder the user can write but does not own.
        // Scenario: a recovery directory left behind by a pre-fix build.
        let dir = try makeTestCheckpointDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("checkpoint.json")
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: dir.path
        )
        try Data("stale".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: url.path
        )
        let writer = CheckpointWriter(label: "danterm.test.checkpoint.narrow")

        writer.write(to: url, async: false) { Data("scrollback".utf8) }

        #expect(try posixMode(of: url) == 0o600)
        #expect(try posixMode(of: dir) == 0o755)
        #expect(try String(decoding: Data(contentsOf: url), as: UTF8.self) == "scrollback")
    }

    @Test("a checkpoint write leaves no temporary sibling behind")
    func checkpointLeavesNoSibling() throws {
        // Intent: after a successful write and after a failed one, the directory holds the
        //   checkpoint and nothing else.
        // Why it exists: the write stages a private temp file and renames it. A sibling that
        //   survived would hold the same scrollback under a name nothing ever cleans up.
        // Scenario: spec-first success, then an encode that throws.
        struct EncodeFailure: Error {}
        let dir = try makeTestCheckpointDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("checkpoint.json")
        let writer = CheckpointWriter(label: "danterm.test.checkpoint.sibling")

        writer.write(to: url, async: false) { Data("first".utf8) }
        writer.write(to: url, async: false) { throw EncodeFailure() }

        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(entries == ["checkpoint.json"])
        #expect(try String(decoding: Data(contentsOf: url), as: UTF8.self) == "first",
                "a failed write must leave the previous checkpoint intact")
    }
}
