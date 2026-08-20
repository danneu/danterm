// The one place pane-tape records reach a connection. It holds only that hand-off: the
// records themselves are built by the pure policy in DanTermCore, and the framing, queueing,
// and splitting belong to DanTermSupport's IpcConnection. Nothing that decides what to send
// belongs here.
import Foundation
import DanTermProtocol

/// The single site that puts tape records on the wire, for dumps, batches, and terminators.
///
/// Each call enqueues straight onto the connection's serial write queue, which both encodes
/// and writes, so records reach the socket in the order they were handed over. Routing one
/// write kind through a concurrent queue instead would let a terminator overtake a batch
/// prepared before it, and a stream's last record would not be its last.
///
/// The records handed over here go out as one notification, because they are one delivery:
/// the subscription is stated once and the whole group costs one encode and one queued line.
/// The connection splits that line only when it would pass the framing bound the reader
/// enforces, which a group of sync records can. The optional completion reports the flush of
/// the whole group, however many lines it took.
func writePaneTapeRecords<Event: Encodable & Sendable>(
    _ records: [PaneTapeOutgoingRecord<Event>],
    connection: IpcConnection,
    subscriptionId: UUID,
    completion: (@MainActor @Sendable (Bool) -> Void)? = nil
) {
    precondition(records.isEmpty == false)
    let subscription = subscriptionId.uuidString
    connection.writeBatchedNotification(
        method: Methods.paneTapeEvent,
        batch: records,
        params: { group in
            PaneTapeEventNotification(subscription: subscription, records: Array(group))
        },
        completion: completion
    )
}
