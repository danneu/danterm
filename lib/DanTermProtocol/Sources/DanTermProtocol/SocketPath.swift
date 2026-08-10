// Shared control-socket path resolution for the DanTerm IPC protocol.
import Foundation

/// Resolves the identity-keyed Unix socket used by the CLI and application server.
public func controlSocketPath(
    identity: DanTermInstanceIdentity = DanTermInstanceIdentity()
) -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(identity.bundleIdentifier, isDirectory: true)
        .appendingPathComponent("control.sock", isDirectory: false)
}
