// The one value that owns every filesystem path DanTerm keys by process identity:
// the control socket, the recovery directory and its three files, the IPC audit
// log, and the scrollback replay directory. Nothing here resolves an identity or
// a root -- both are inputs, so the process resolves them once at launch and hands
// this value down. Paths keyed by the *user* rather than the instance, such as the
// config file, are DanTermConfigPaths' business and do not belong here.
import DanTermProtocol
import Foundation

/// Derives every identity-keyed path from one identity and one set of roots, so the
/// lock, the checkpoints, and the audit log co-locate by construction instead of by
/// six leaves happening to agree. It has exactly one initializer, and that
/// initializer defaults nothing: a caller that cannot name the instance and the
/// roots it means has no business writing to them.
struct DanTermInstancePaths: Sendable, Equatable {
    /// The instance every path below is namespaced by.
    let identity: DanTermInstanceIdentity
    let applicationSupportRoot: URL
    let cachesRoot: URL
    /// The process-temporary root. It is an input rather than a lookup because the
    /// characterization harness redirects it, and macOS ignores a launched app's TMPDIR.
    let temporaryRoot: URL

    init(
        identity: DanTermInstanceIdentity,
        applicationSupportRoot: URL,
        cachesRoot: URL,
        temporaryRoot: URL
    ) {
        self.identity = identity
        self.applicationSupportRoot = applicationSupportRoot
        self.cachesRoot = cachesRoot
        self.temporaryRoot = temporaryRoot
    }

    /// Holds everything that must survive a crash: both checkpoint tiers, the session
    /// lock, and the IPC audit log.
    var recoveryDirectory: URL {
        applicationSupportRoot
            .appendingPathComponent(identity.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }

    /// The frequent structural checkpoint: no scrollback, written on a fixed short window.
    var lightCheckpointFile: URL {
        recoveryDirectory.appendingPathComponent("last-light.json")
    }

    /// The periodic full checkpoint: structure plus each pane's scrollback.
    var enrichedCheckpointFile: URL {
        recoveryDirectory.appendingPathComponent("last-enriched.json")
    }

    /// Written at launch and deleted on clean exit, so its presence at the next launch
    /// means the previous exit was unclean.
    var sessionLockFile: URL {
        recoveryDirectory.appendingPathComponent("session.json")
    }

    /// The audit log lives with the recovery files on purpose: one directory holds
    /// everything this instance wrote about the run that just ended.
    var ipcAuditDirectory: URL { recoveryDirectory }

    /// The Unix socket the IPC server binds and the CLI connects to.
    var controlSocket: URL {
        controlSocketPath(identity: identity, cachesRoot: cachesRoot)
    }

    /// Isolates disposable replay files so one instance's launch cleanup cannot erase
    /// another's.
    var scrollbackReplayDirectory: URL {
        temporaryRoot
            .appendingPathComponent("danterm-scrollback", isDirectory: true)
            .appendingPathComponent(identity.bundleIdentifier, isDirectory: true)
    }

    /// Removes only this identity's abandoned replay files while other live instances
    /// keep theirs.
    func removeStaleScrollbackReplayDirectory(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: scrollbackReplayDirectory)
    }
}
