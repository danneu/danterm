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
    /// Writes every byte, or throws. A partial write is the transport's problem to retry.
    func send(_ bytes: Data) throws

    /// Blocks until at least one byte arrives and returns it, or returns empty at EOF.
    func receive() throws -> Data

    /// Cancels the stream and waits until active reads and writes no longer use its
    /// resource. Repeated calls have no effect after the first cancellation completes.
    func close()
}
