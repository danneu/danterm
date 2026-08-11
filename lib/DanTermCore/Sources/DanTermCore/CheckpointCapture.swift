// The recovery checkpoint's capture-to-bytes stage: what the main actor must take from live
// state in one pass (`CheckpointCapture`), and the deferred work that turns it into checkpoint
// bytes (`CheckpointCapture.encoder`). Persistence.swift owns the codec itself; this file owns
// the staging that keeps the codec off the main thread. The capture holds per-pane *reads*
// rather than text, so projecting and truncating every pane happens wherever the returned
// closure runs -- the checkpoint queue, not the caller. It earns its own file because that
// deferral is the whole mechanism, and because keeping the payload in core is what makes it
// unit-testable: which pane's text lands against which model snapshot is decided here, not in
// `app/`, which keeps only the capture that must stay on the main actor.
import Foundation

/// One pane's bounded scrollback read, deferred. Handed over instead of text so the projection
/// runs wherever the encode does; `app/` closes over a copied terminal value, tests over a
/// canned string.
typealias CheckpointScrollbackRead = @Sendable (ScrollbackRetention) -> String?

/// The canonical light-checkpoint payload. Equality is the scheduling policy: any value not
/// represented in the final grafted snapshot is deliberately unable to trigger a light write.
struct LightCheckpointProjection: Equatable {
    let snapshot: AppModelSnapshot
}

/// Everything a checkpoint needs, taken from live state in a single main-actor pass. Bundling
/// the model snapshot with the per-pane reads is what makes the pairing structural: a pane's
/// text can only ever be written against the snapshot captured beside it, so two checkpoints in
/// flight cannot cross even though either may finish first. An enriched checkpoint carries one
/// read per live pane; a light one carries none.
struct CheckpointCapture {
    let snapshot: AppModelSnapshot
    let scrollbackReads: [PaneId: CheckpointScrollbackRead]
    let retention: ScrollbackRetention

    init(
        snapshot: AppModelSnapshot,
        scrollbackReads: [PaneId: CheckpointScrollbackRead],
        retention: ScrollbackRetention = .checkpoint
    ) {
        self.snapshot = snapshot
        self.scrollbackReads = scrollbackReads
        self.retention = retention
    }

    /// Build the light tier from the same named value its scheduler compares.
    init(lightProjection: LightCheckpointProjection) {
        self.init(
            snapshot: lightProjection.snapshot,
            scrollbackReads: [:]
        )
    }

    /// Work that reads, truncates, grafts, and encodes -- none of which happens here. This is
    /// the capture's only route to bytes, so a caller cannot pay the expensive half on the
    /// thread it captured from; it hands the closure to the checkpoint queue instead.
    func encoder(prettyPrinted: Bool = false) -> @Sendable () throws -> Data {
        // Bind values out so the closure does not capture the container itself.
        let snapshot = snapshot
        let reads = scrollbackReads
        let retention = retention
        return {
            let enriched = graftScrollback(
                onto: snapshot,
                scrollbackByPaneId: resolveScrollback(reads, keeping: retention)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = prettyPrinted
                ? [.prettyPrinted, .sortedKeys]
                : [.sortedKeys]
            return try encoder.encode(toInitFile(snapshot: enriched))
        }
    }
}

/// Return work for the current light projection only when it differs from the projection most
/// recently handed to the serial writer.
func lightCheckpointCapture(
    current: LightCheckpointProjection,
    baseline: LightCheckpointProjection?
) -> CheckpointCapture? {
    guard current != baseline else { return nil }
    return CheckpointCapture(lightProjection: current)
}

/// Run every captured pane's read and cut what comes back to the same budget. One
/// `ScrollbackRetention` reaches both halves by construction -- a read that stopped short of
/// what the cut keeps would store less than the pane is owed, and nothing downstream could tell.
private func resolveScrollback(
    _ reads: [PaneId: CheckpointScrollbackRead],
    keeping retention: ScrollbackRetention
) -> [PaneId: String] {
    var result: [PaneId: String] = [:]
    for (paneId, read) in reads {
        guard let rawText = read(retention),
              let scrollback = truncateScrollback(rawText, keeping: retention) else {
            continue
        }
        result[paneId] = scrollback
    }
    return result
}
