// The T25 surface swapchain: the coordination half of view-owned display.
// Frame stores hold pixels; this type decides which store a publish may
// write, accumulates the damage each detached store misses, and carries the
// one pending presentation for publishes that found no safe buffer. It knows
// nothing about layers or transactions -- the owning view attaches what this
// type presents, and replaces the whole swapchain on any trust-breaking
// input (geometry, backing scale, theme, window color space), so a live
// swapchain never changes shape. It remembers what it was built from and
// answers `matches` for it, so the owner asks the buffers rather than keeping
// a second copy of their inputs that could drift.
import CoreGraphics
import IOSurface
import TerminalCore
import TerminalRenderPlanning

/// Rotates a fixed set of IOSurface-backed frame stores so every publish
/// renders into a buffer that is detached from the layer and confirmed free,
/// never the one the render server may still read.
///
/// Main-thread only. The in-use report is trusted per the real-AppKit pins in
/// `tests-ui/IOSurfaceLayerContentsTests.swift`: a detached surface reported
/// free stays free. The owner must have committed the transaction that
/// detached a buffer before calling back in -- in practice one publish or
/// retry per display-refresh tick, with the attach committed in between.
public final class TerminalFrameSwapchain {
    /// Three buffers, not two: freeing is presentation-driven, and a cold
    /// render pipeline has been observed holding a detached surface across
    /// several subsequent presentations. With only two buffers that hold can
    /// wedge the swapchain -- a retry that cannot acquire presents nothing,
    /// so nothing flushes the pipeline that is holding the only detached
    /// buffer.
    public static let defaultDepth = 3

    private struct Buffer {
        let store: TerminalFrameBackingStore
        /// True once the store has ever held a complete rendered frame;
        /// a fresh buffer's pixels are untrusted and force a full render.
        var isCurrent = false
        /// Damage composed (per `TerminalDamage.formUnion`) over every
        /// publish since this buffer last held the presented frame.
        var staleDamage = TerminalDamage.none
        /// Publish generation at which this buffer last presented, so
        /// acquisition can prefer the least-stale candidate.
        var lastPresented = -1
    }

    private let columns: Int
    private let rows: Int
    private let metrics: TerminalRenderMetrics
    /// Kept exactly as passed, never substituted for a default: the stand-in
    /// for an absent space is the backing store's private business, and
    /// normalizing here would report a match to a caller that asked for
    /// something else.
    private let colorSpace: CGColorSpace?

    private var buffers: [Buffer]
    private var attachedIndex: Int?
    private var pendingPlan: RenderFramePlan?
    private var generation = 0
    /// The publish generation every buffer must have rendered at or after before
    /// an old whole-frame setup can no longer surface on later acquisition.
    private var latestWholeFrameDamageGeneration = 0
    private let isStoreInUse: (TerminalFrameBackingStore) -> Bool

    /// Fails when any store allocation fails. `isStoreInUse` exists for the
    /// headless tests; live callers keep the IOSurface default.
    public init?(
        columns: Int,
        rows: Int,
        metrics: TerminalRenderMetrics,
        colorSpace: CGColorSpace? = nil,
        depth: Int = TerminalFrameSwapchain.defaultDepth,
        isStoreInUse: @escaping (TerminalFrameBackingStore) -> Bool = { $0.ioSurface.isInUse }
    ) {
        precondition(depth >= 2, "a swapchain needs a buffer to write while one displays")
        // One cache for every buffer. The swapchain is replaced whenever the metrics
        // change, so its lifetime is exactly the font set the shapings are valid for,
        // and a cluster shaped while one buffer rendered is reused when the next one does.
        let shapedClusters = ShapedClusterCache(metrics: metrics)
        var buffers: [Buffer] = []
        for _ in 0..<depth {
            guard let store = TerminalFrameBackingStore(
                columns: columns,
                rows: rows,
                metrics: metrics,
                colorSpace: colorSpace,
                shapedClusters: shapedClusters
            ) else { return nil }
            buffers.append(Buffer(store: store))
        }
        self.columns = columns
        self.rows = rows
        self.metrics = metrics
        self.colorSpace = colorSpace
        self.buffers = buffers
        self.isStoreInUse = isStoreInUse
    }

    /// True when these pixels were rendered under exactly these inputs, so the
    /// owner may keep this swapchain instead of building a fresh one. Any
    /// inequality is a trust break (research/33 T25 I3), and the answer to that
    /// is always replacement -- a live swapchain never changes shape.
    public func matches(
        columns: Int,
        rows: Int,
        metrics: TerminalRenderMetrics,
        colorSpace: CGColorSpace?
    ) -> Bool {
        self.columns == columns && self.rows == rows
            && matches(metrics: metrics, colorSpace: colorSpace)
    }

    /// The same test with this swapchain's own geometry held fixed, for the
    /// owner's re-render check. A grid resize republishes through the
    /// controller, so presenting the current plan under a grid the plan does not
    /// have would render a stale frame; only the non-geometry inputs decide
    /// whether the frame on screen must be redrawn.
    public func matches(metrics: TerminalRenderMetrics, colorSpace: CGColorSpace?) -> Bool {
        self.metrics == metrics && self.colorSpace == colorSpace
    }

    /// True while the latest published plan has not reached a buffer; the
    /// owner keeps retrying on its publish-pacing tick until this clears.
    public var hasPendingPresentation: Bool {
        pendingPlan != nil
    }

    /// Reports when no buffer can surface work from before the latest explicit
    /// convergence barrier or whole-frame render.
    ///
    /// The benchmark producer uses this to keep settling frames outside its
    /// measured sequence. Production presentation does not wait on it.
    public var allBuffersHaveRenderedLatestWholeFrameDamage: Bool {
        buffers.allSatisfy {
            $0.lastPresented >= latestWholeFrameDamageGeneration
        }
    }

    /// Installs a convergence barrier at the next generation boundary.
    ///
    /// The currently attached buffer must cycle through again too. This proves
    /// every member of the swapchain observed state no older than the caller's
    /// request, rather than assuming the buffer attached at that instant already
    /// contains the block's complete setup.
    public func requireEveryBufferToRenderAgain() {
        latestWholeFrameDamageGeneration = generation
    }

    /// What the most recent presentation actually rendered: `.full` when the
    /// acquired buffer needed a from-scratch render, otherwise the composed
    /// stale damage it applied. The owner's benchmark bracket reports it, so
    /// the recorded damage topology is the render's own, not the publish's.
    /// Nil until the first presentation.
    public private(set) var lastRenderedDamage: TerminalDamage?

    /// Accepts one published frame: every buffer accumulates the damage, and
    /// if a safe buffer exists the plan renders into it -- incrementally when
    /// the buffer's composed stale damage applies, from scratch otherwise.
    /// Returns the store to attach, or nil when the publish coalesced into
    /// the pending presentation.
    public func publish(plan: RenderFramePlan, damage: TerminalDamage) -> TerminalFrameBackingStore? {
        if damage.coversViewportFoldingShift(rowCount: plan.rowCount) {
            latestWholeFrameDamageGeneration = generation
        }
        for index in buffers.indices {
            buffers[index].staleDamage.formUnion(damage)
        }
        pendingPlan = plan
        return presentPending()
    }

    /// Retries the pending presentation without new damage. Returns nil when
    /// nothing is pending or no buffer is acquirable yet.
    public func retryPendingPresentation() -> TerminalFrameBackingStore? {
        presentPending()
    }

    private func presentPending() -> TerminalFrameBackingStore? {
        guard let plan = pendingPlan else { return nil }
        guard let index = acquireIndex() else { return nil }
        render(plan, into: &buffers[index])
        buffers[index].lastPresented = generation
        generation += 1
        attachedIndex = index
        pendingPlan = nil
        return buffers[index].store
    }

    /// A buffer predating the latest whole-frame damage first, then the
    /// least-stale current buffer that is detached and reported free. Catching
    /// every buffer up eagerly prevents an arbitrary later publish from paying
    /// old setup damage when the compositor exposes a long-cold buffer.
    private func acquireIndex() -> Int? {
        let candidates = buffers.indices
            .filter { $0 != attachedIndex && isStoreInUse(buffers[$0].store) == false }
        if let outdated = candidates.first(where: {
            buffers[$0].lastPresented < latestWholeFrameDamageGeneration
        }) {
            return outdated
        }
        return candidates
            .max { buffers[$0].lastPresented < buffers[$1].lastPresented }
    }

    private func render(_ plan: RenderFramePlan, into buffer: inout Buffer) {
        let incremental = buffer.isCurrent
            && buffer.store.apply(plan: plan, damage: buffer.staleDamage)
        if incremental == false {
            buffer.store.renderFull(plan)
        }
        lastRenderedDamage = incremental ? buffer.staleDamage : .full
        buffer.isCurrent = true
        buffer.staleDamage = .none
    }
}
