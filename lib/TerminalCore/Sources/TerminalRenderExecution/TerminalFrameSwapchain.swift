// The T25 surface swapchain: the coordination half of view-owned display.
// Frame stores hold pixels; this type decides which store a publish may
// write, accumulates the damage each detached store misses, and carries the
// one pending presentation for publishes that found no safe buffer. It knows
// nothing about layers or transactions -- the owning view attaches what this
// type presents, and replaces the whole swapchain on any trust-breaking
// input (geometry, backing scale, theme, window color space), so a live
// swapchain never changes shape.
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

    private var buffers: [Buffer]
    private var attachedIndex: Int?
    private var pendingPlan: RenderFramePlan?
    private var generation = 0
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
        var buffers: [Buffer] = []
        for _ in 0..<depth {
            guard let store = TerminalFrameBackingStore(
                columns: columns,
                rows: rows,
                metrics: metrics,
                colorSpace: colorSpace
            ) else { return nil }
            buffers.append(Buffer(store: store))
        }
        self.buffers = buffers
        self.isStoreInUse = isStoreInUse
    }

    /// True while the latest published plan has not reached a buffer; the
    /// owner keeps retrying on its publish-pacing tick until this clears.
    public var hasPendingPresentation: Bool {
        pendingPlan != nil
    }

    /// Accepts one published frame: every buffer accumulates the damage, and
    /// if a safe buffer exists the plan renders into it -- incrementally when
    /// the buffer's composed stale damage applies, from scratch otherwise.
    /// Returns the store to attach, or nil when the publish coalesced into
    /// the pending presentation.
    public func publish(plan: RenderFramePlan, damage: TerminalDamage) -> TerminalFrameBackingStore? {
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

    /// The least-stale buffer that is both detached and reported free --
    /// least stale so bring-current redraws the fewest exposed rows.
    private func acquireIndex() -> Int? {
        buffers.indices
            .filter { $0 != attachedIndex && isStoreInUse(buffers[$0].store) == false }
            .max { buffers[$0].lastPresented < buffers[$1].lastPresented }
    }

    private func render(_ plan: RenderFramePlan, into buffer: inout Buffer) {
        let incremental = buffer.isCurrent
            && buffer.store.apply(plan: plan, damage: buffer.staleDamage)
        if incremental == false {
            buffer.store.renderFull(plan)
        }
        buffer.isCurrent = true
        buffer.staleDamage = .none
    }
}
