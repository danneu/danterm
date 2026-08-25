// The recovery checkpoint's write queue: one serial queue that encodes and atomically writes a
// checkpoint as a single work item. It belongs here rather than in `app/` for two reasons. It is
// portable IO -- the same FileManager/Data boundary RecoveryStore already owns on this side of
// the split -- and the ordering guarantee it exists for is a behaviour, so it needs somewhere it
// can be tested. It takes the encode as deferred work rather than finished bytes, which is what
// keeps the expensive half of a checkpoint off the caller's thread. It knows nothing about what
// it writes: DanTermCore owns the payload, and support must never depend on core.
import Foundation
import PrivateFile

/// Serializes checkpoint writes so a checkpoint captured earlier can never overwrite one
/// captured later: one serial queue, one work item per checkpoint, encoding included. Splitting
/// encode and write across queues would reorder them under load while still producing correct
/// bytes, which is why the encode is a parameter here rather than something the caller does
/// first. Completions are delivered on the main queue, unconditionally: the recovery state a
/// completion feeds lives on the main actor, and no caller has a reason to want them elsewhere.
/// What one write reported back. It carries the failure text rather than a bare flag because
/// state export shows the reason to the user, and "it failed" is not something a person can act
/// on -- a full disk and a read-only folder need different responses. The recovery policy, which
/// only retries, reads `isSucceeded` and ignores the rest.
enum CheckpointWriteOutcome: Sendable {
    case succeeded
    case failed(description: String)

    var isSucceeded: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

final class CheckpointWriter: Sendable {
    private let queue: DispatchQueue

    init(
        label: String = "danterm.checkpoint.io",
        qos: DispatchQoS = .utility
    ) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    /// Encode and atomically write, as one work item. `async: false` also fences every write
    /// already queued, which is what the quit checkpoint stands on: it must leave nothing in
    /// flight, because the process exits as soon as it returns.
    ///
    /// `encode` is `@Sendable` because it genuinely changes threads: it runs on the writer's
    /// queue, never on the thread that called `write`. `completion` is `@MainActor` for the same
    /// reason the delivery queue is hard-wired: the guarantee and the code that leans on it are
    /// stated together, so a completion touches main-actor state directly instead of hopping
    /// again and re-promising the guarantee per call site. It is `@Sendable` as well, because
    /// the closure itself travels to the writer's queue before it is called back on the main one.
    func write(
        to url: URL,
        async: Bool,
        encode: @escaping @Sendable () throws -> Data,
        completion: (@MainActor @Sendable (CheckpointWriteOutcome) -> Void)? = nil
    ) {
        let work = DispatchWorkItem {
            let outcome: CheckpointWriteOutcome
            do {
                let data = try encode()
                try PrivateFile.createDirectory(at: url.deletingLastPathComponent())
                try PrivateFile.writeAtomically(data, to: url)
                outcome = .succeeded
            } catch {
                outcome = .failed(description: error.localizedDescription)
            }
            guard let completion else { return }
            DispatchQueue.main.async {
                // `assumeIsolated` reads back the guarantee the line above just made, rather
                // than hopping a second time through `Task { @MainActor }` -- which would also
                // give up the FIFO order this queue exists to keep.
                MainActor.assumeIsolated { completion(outcome) }
            }
        }

        if async {
            queue.async(execute: work)
        } else {
            queue.sync(execute: work)
        }
    }

    /// Block until every write submitted so far has finished. The flush path uses this when it
    /// has nothing new to write but still must not leave earlier work in flight.
    func drain() {
        queue.sync {}
    }
}
