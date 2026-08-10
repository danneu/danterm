// Marker-to-completion sampling policy for cumulative owner-queue fence metrics.

/// Separates benchmark block boundaries from app-only marker and artifact plumbing.
public struct TerminalPaneFenceBlockPolicy: Sendable {
    private var baseline: TerminalPaneFenceMetrics?

    /// Creates an idle policy ready to baseline its first persistent or one-shot block.
    public init() {}

    /// Baselines cumulative metrics when the start marker enters terminal state.
    public mutating func beginBlock(at metrics: TerminalPaneFenceMetrics) {
        baseline = metrics
    }

    /// Returns the open block's monotone delta and closes that sampling span.
    public mutating func completeBlock(
        at metrics: TerminalPaneFenceMetrics
    ) -> TerminalPaneFenceMetrics? {
        guard let baseline else { return nil }
        self.baseline = nil
        return metrics.subtracting(baseline)
    }

    /// Prevents a post-exit draw from completing a span whose controller was fenced away.
    public mutating func invalidateAfterApplicationExitFence() {
        baseline = nil
    }
}
