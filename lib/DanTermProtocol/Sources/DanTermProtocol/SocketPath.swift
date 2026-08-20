// Shared control-socket path resolution for the DanTerm IPC protocol.
import Foundation

/// Derives the identity-keyed Unix socket from explicit inputs, so one layout serves
/// every caller: the app composes it with its launch-resolved caches root, and bare
/// executables compose it through `userControlSocketPath` below.
public func controlSocketPath(identity: DanTermInstanceIdentity, cachesRoot: URL) -> URL {
    cachesRoot
        .appendingPathComponent(identity.bundleIdentifier, isDirectory: true)
        .appendingPathComponent("control.sock", isDirectory: false)
}

/// Composes the socket layout with the user's real caches directory, for the bare
/// executables -- the `danterm` CLI and the identity tool -- that hold no
/// launch-resolved paths value of their own. The identity stays explicit: a bare
/// executable has no bundle identifier to read, so the caller must name the
/// instance it means to reach.
public func userControlSocketPath(identity: DanTermInstanceIdentity) -> URL {
    controlSocketPath(
        identity: identity,
        cachesRoot: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    )
}
