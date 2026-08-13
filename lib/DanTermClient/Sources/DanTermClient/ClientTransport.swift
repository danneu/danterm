// The byte stream a client conversation runs over, and nothing about how it is opened.
//
// This file names no socket kind on purpose. AF_UNIX on the Mac and a network transport
// from a phone are two conformances of the same seam, so the conversation above it is
// not rewritten when the transport changes. A conformance owns its own error type;
// the seam only promises that failures throw.
import Foundation

/// One bidirectional byte stream a DanTerm client conversation runs over. This is
/// everything `DanTermClientSession` needs from a socket, a TLS session, or a test double.
///
/// It is a class protocol because a transport owns a resource with a lifetime -- the
/// session holds one and closes it -- not because any conformance needs reference
/// semantics for its own sake.
public protocol DanTermClientTransport: AnyObject {
    /// Writes every byte, or throws. A partial write is the transport's problem to retry.
    func send(_ bytes: Data) throws

    /// Blocks until at least one byte arrives and returns it, or returns empty at EOF.
    func receive() throws -> Data

    func close()
}
