// Swift Testing suite for `CheckpointWriter` -- the serial queue that encodes and writes a
// recovery checkpoint as one work item. The claims are about scheduling, not payloads: a write
// never encodes on its caller's thread, submitted writes land in submission order, and both the
// synchronous write and `drain()` fence everything already queued. Each test supplies its own
// trivial `encode` closure, because the writer is deliberately ignorant of what it writes.
import Foundation
import Testing

@testable import DanTermSupport

/// A unique-per-test checkpoint path under the OS temp dir, so the suite stays hermetic and
/// parallel-safe. The writer creates the parent directory itself; the caller's defer removes it.
private func makeTestCheckpointDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-checkpointwriter-\(UUID().uuidString)", isDirectory: true)
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

/// Carries a completion's reported outcome back to the test body. Unchecked because the
/// semaphore the test waits on orders the write against the read.
private final class Outcome: @unchecked Sendable {
    var succeeded: Bool?
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
        let dir = makeTestCheckpointDir()
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
        let dir = makeTestCheckpointDir()
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
        let dir = makeTestCheckpointDir()
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
    func failedEncodeReportsFailure() throws {
        // Intent: an encode that throws yields `succeeded == false` and writes nothing.
        // Why it exists: the completion drives the recovery policy's retry/backoff state, so a
        //   failure reported as success would stall the policy on a checkpoint that never
        //   landed. Moving the encode inside the work item is what made encode failures visible
        //   to this path at all -- before, encoding threw on the caller's side.
        // Scenario: spec-first. The encode closure throws.
        struct EncodeFailure: Error {}
        let dir = makeTestCheckpointDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("checkpoint.json")
        // Production delivers completions to the main queue, which no test can service; the
        // defaulted seam lets this one watch the same code path from a queue it can wait on.
        let writer = CheckpointWriter(
            label: "danterm.test.checkpoint.failure",
            completionQueue: DispatchQueue(label: "danterm.test.checkpoint.failure.completion")
        )
        let outcome = Outcome()
        let reported = DispatchSemaphore(value: 0)

        writer.write(to: url, async: true, encode: {
            throw EncodeFailure()
        }, completion: { result in
            outcome.succeeded = result
            reported.signal()
        })

        #expect(reported.wait(timeout: .now() + 5) == .success, "completion should report within 5s")
        #expect(outcome.succeeded == false)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }
}
