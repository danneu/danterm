// The capture-to-bytes stage for everything the app writes from live state: what the main actor
// must take in one pass, and the deferred work that turns it into bytes. Persistence.swift owns
// the codecs themselves; this file owns the staging that keeps them off the main thread. A
// capture holds per-pane *reads* rather than text, so projecting and normalizing every pane
// happens wherever the returned closure runs -- the checkpoint queue, not the caller. It earns
// its own file because that deferral is the whole mechanism, and because keeping the payload in
// core is what makes it unit-testable: which pane's text lands in which file is decided here,
// not in `app/`, which keeps only the capture that must stay on the main actor.
//
// Three captures, because three files have three shapes: the session checkpoint is structure
// alone, the scrollback checkpoint is text alone, and export is one init file carrying both.
import Foundation

/// One pane's bounded scrollback read, deferred after capture has fixed its plain engine limits.
typealias CheckpointScrollbackRead = @Sendable () -> String?

/// The canonical session-checkpoint payload: the only structure the app writes to disk.
/// Equality is the scheduling policy: any value not represented in the snapshot is deliberately
/// unable to trigger a session write.
struct SessionCheckpointProjection: Equatable {
    let snapshot: AppModelSnapshot
}

/// The scrollback checkpoint's capture: per-pane reads and nothing else. It carries no snapshot
/// because the sidecar it encodes carries no structure -- the session file owns that, and the
/// load-time graft is keyed by pane id, so a sidecar written against a since-changed model
/// grafts harmlessly instead of contradicting the session on disk.
struct ScrollbackCapture {
    let scrollbackReads: [PaneId: CheckpointScrollbackRead]

    /// Work that reads, normalizes, and encodes -- none of which happens here. This is the
    /// capture's only route to bytes, so a caller cannot pay the expensive half on the thread
    /// it captured from; it hands the closure to the checkpoint queue instead.
    func encoder() -> @Sendable () throws -> Data {
        // Bind the reads out so the closure does not capture the container itself.
        let reads = scrollbackReads
        return { try encodeScrollbackSidecar(resolveScrollback(reads)) }
    }
}

/// One whole init file taken from live state: a model snapshot plus the per-pane reads grafted
/// into its leaves. This is the session checkpoint's shape without reads, and export's shape
/// with them; the scrollback checkpoint does not use it, because a sidecar is not an init file.
struct InitFileCapture {
    let snapshot: AppModelSnapshot
    let scrollbackReads: [PaneId: CheckpointScrollbackRead]

    init(
        snapshot: AppModelSnapshot,
        scrollbackReads: [PaneId: CheckpointScrollbackRead]
    ) {
        self.snapshot = snapshot
        self.scrollbackReads = scrollbackReads
    }

    /// Build the session tier from the same named value its scheduler compares.
    init(sessionProjection: SessionCheckpointProjection) {
        self.init(
            snapshot: sessionProjection.snapshot,
            scrollbackReads: [:]
        )
    }

    /// Work that reads, normalizes, grafts, and encodes -- none of which happens here, for the
    /// same reason as `ScrollbackCapture.encoder()`.
    func encoder(prettyPrinted: Bool = false) -> @Sendable () throws -> Data {
        // Bind values out so the closure does not capture the container itself.
        let snapshot = snapshot
        let reads = scrollbackReads
        return {
            let grafted = graftScrollback(
                onto: snapshot,
                scrollbackByPaneId: resolveScrollback(reads)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = prettyPrinted
                ? [.prettyPrinted, .sortedKeys]
                : [.sortedKeys]
            return try encoder.encode(toInitFile(snapshot: grafted))
        }
    }
}

/// Run every captured pane's bounded read and apply only persistence normalization.
private func resolveScrollback(
    _ reads: [PaneId: CheckpointScrollbackRead]
) -> [PaneId: String] {
    var result: [PaneId: String] = [:]
    for (paneId, read) in reads {
        guard let rawText = read(),
              let scrollback = normalizeCheckpointScrollback(rawText) else {
            continue
        }
        result[paneId] = scrollback
    }
    return result
}
