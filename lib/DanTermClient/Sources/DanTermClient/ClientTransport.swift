// The byte stream a client conversation runs over, and nothing about how it is opened.
//
// This file names no socket kind on purpose. AF_UNIX on the Mac and a network transport
// from a phone are two conformances of the same seam, so the conversation above it is
// not rewritten when the transport changes. A conformance owns its own error type;
// the seam only promises that failures throw.
import Foundation

/// Reports that a transport operation began after its stream was cancelled.
public enum DanTermClientTransportError: Error, Equatable {
    /// The stream no longer accepts new operations because close has started.
    case cancelled
}

/// States whether streams of one transport kind live under the peer-liveness contract.
///
/// It is a property of the kind rather than of a stream, and it has no default, so every
/// conformance has to answer at compile time and no session call site gets to decide. A
/// transport that gains a liveness meaning later cannot acquire it by omission.
public enum DanTermClientLivenessPolicy: Equatable, Sendable {
    /// Peer death cannot happen without the stream closing, so no bound applies. A local
    /// socket is this: its peer is a process on the same machine, and a follow over it is
    /// idle for exactly as long as its subject is quiet.
    case exempt
    /// The peer can vanish while the stream stays open, so the server-advertised silence
    /// bound governs the stream and the client owes its ping cadence.
    case underContract
}

/// One bidirectional byte stream a DanTerm client conversation runs over. This is
/// everything `DanTermClientSession` needs from a socket, a TLS session, or a test double.
///
/// It is a class protocol because a transport owns a resource with a lifetime -- the
/// session holds one and closes it -- not because any conformance needs reference
/// semantics for its own sake.
///
/// One read and one write may be active at the same time. `close` may run concurrently
/// with either operation. A conformance must wake the read, wait for both operations to
/// release the resource, and reject every operation that starts after cancellation.
public protocol DanTermClientTransport: AnyObject {
    /// Declares whether this transport kind's streams live under the liveness contract.
    static var livenessPolicy: DanTermClientLivenessPolicy { get }

    /// Writes every byte or throws. After a throw the stream is unusable, and its session
    /// closes it instead of attempting another write.
    func send(_ bytes: Data) throws

    /// Blocks until at least one byte arrives and returns it, or returns empty at EOF.
    func receive() throws -> Data

    /// Cancels the stream and waits until active reads and writes no longer use its
    /// resource. Repeated calls have no effect after the first cancellation completes.
    func close()
}
