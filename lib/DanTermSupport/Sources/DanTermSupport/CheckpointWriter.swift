// The recovery checkpoint's write queue: one serial queue that encodes and atomically writes a
// checkpoint as a single work item. It belongs here rather than in `app/` for two reasons. It is
// portable IO -- the same FileManager/Data boundary RecoveryStore already owns on this side of
// the split -- and the ordering guarantee it exists for is a behaviour, so it needs somewhere it
// can be tested. It takes the encode as deferred work rather than finished bytes, which is what
// keeps the expensive half of a checkpoint off the caller's thread. It knows nothing about what
// it writes: DanTermCore owns the payload, and support must never depend on core.
import Foundation

/// Serializes checkpoint writes so a checkpoint captured earlier can never overwrite one
/// captured later: one serial queue, one work item per checkpoint, encoding included. Splitting
/// encode and write across queues would reorder them under load while still producing correct
/// bytes, which is why the encode is a parameter here rather than something the caller does
/// first. `completionQueue` is defaulted to the main queue, where the app keeps the recovery
/// state a completion feeds; tests point it at a queue they can wait on.
final class CheckpointWriter: Sendable {
    private let queue: DispatchQueue
    private let completionQueue: DispatchQueue

    init(
        label: String = "danterm.checkpoint.io",
        qos: DispatchQoS = .utility,
        completionQueue: DispatchQueue = .main
    ) {
        queue = DispatchQueue(label: label, qos: qos)
        self.completionQueue = completionQueue
    }

    /// Encode and atomically write, as one work item. `async: false` also fences every write
    /// already queued, which is what the quit checkpoint stands on: it must leave nothing in
    /// flight, because the process exits as soon as it returns. Both closures are `@Sendable`
    /// because both genuinely change threads: `encode` runs on the writer's queue, and
    /// `completion` on `completionQueue`, never on the thread that called `write`.
    func write(
        to url: URL,
        async: Bool,
        encode: @escaping @Sendable () throws -> Data,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        let completionQueue = completionQueue
        let work = DispatchWorkItem {
            let succeeded: Bool
            do {
                let data = try encode()
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
                succeeded = true
            } catch {
                succeeded = false
            }
            guard let completion else { return }
            completionQueue.async { completion(succeeded) }
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
