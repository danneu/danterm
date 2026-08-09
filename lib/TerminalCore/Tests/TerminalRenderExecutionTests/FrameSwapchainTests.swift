// Headless pins for the T25 surface swapchain: acquisition never targets the
// attached or in-use buffer, publishes without an acquirable buffer coalesce
// into one pending presentation that a later retry renders, and every
// presented buffer -- fresh, one generation stale, or escalated -- is
// byte-identical to a from-scratch render of its plan. The render-server half
// of the acquisition premise (free stays free) lives in the real-AppKit pins
// in tests-ui; here the in-use report is injected so every branch is
// reachable without a compositor.

import CoreGraphics
import Testing

@testable import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning

struct FrameSwapchainTests {
    private let line = "swapchain gjpqy content 0123456789 abcdefghijklmnopqrstuvwxyz"

    private var blockCursor: RenderPresentation {
        RenderPresentation(theme: .dark, isCursorVisible: true, cursorShape: .block)
    }

    private var metrics: TerminalRenderMetrics {
        get throws { try #require(TerminalRenderMetrics(displayScale: 2)) }
    }

    private func prefill(_ terminal: inout Terminal, rows: Int) {
        var bytes: [UInt8] = []
        for _ in 0..<(rows - 1) { bytes += Array((line + "\r\n").utf8) }
        bytes += Array((line + "\r").utf8)
        terminal.feed(bytes)
    }

    private func blitBitmap(
        _ store: TerminalFrameBackingStore,
        plan: RenderFramePlan,
        metrics: TerminalRenderMetrics
    ) throws -> Bitmap {
        let size = try #require(renderFrameSize(for: plan, metrics: metrics))
        let surface = try BitmapSurface(size: size, metrics: metrics)
        let context = try #require(surface.context)
        store.blit(into: context, rect: CGRect(origin: .zero, size: size.pointSize))
        return surface.bitmap()
    }

    /// A swapchain over a mutable busy predicate, so tests steer the injected
    /// in-use report per store.
    private final class BusyBox {
        var isBusy: (TerminalFrameBackingStore) -> Bool = { _ in false }
        func makeSwapchain(
            columns: Int,
            rows: Int,
            metrics: TerminalRenderMetrics,
            depth: Int = 3
        ) -> TerminalFrameSwapchain? {
            TerminalFrameSwapchain(
                columns: columns,
                rows: rows,
                metrics: metrics,
                depth: depth,
                isStoreInUse: { [weak self] store in
                    self?.isBusy(store) ?? false
                }
            )
        }
    }

    @Test("readiness requires every buffer to be reusable after the latest full publish")
    func readinessCoversEveryBuffer() throws {
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 40, rows: 10))
        prefill(&terminal, rows: 10)
        _ = terminal.drainDamage()
        let swapchain = try #require(
            BusyBox().makeSwapchain(columns: 40, rows: 10, metrics: metrics)
        )
        let plan = planFrame(for: terminal, presentation: blockCursor)

        #expect(swapchain.allBuffersHaveRenderedLatestWholeFrameDamage == false)
        _ = try #require(swapchain.publish(plan: plan, damage: .full))
        #expect(swapchain.allBuffersHaveRenderedLatestWholeFrameDamage == false)
        _ = try #require(swapchain.publish(plan: plan, damage: .none))
        #expect(swapchain.allBuffersHaveRenderedLatestWholeFrameDamage == false)
        _ = try #require(swapchain.publish(plan: plan, damage: .none))
        #expect(swapchain.allBuffersHaveRenderedLatestWholeFrameDamage)

        swapchain.requireEveryBufferToRenderAgain()
        #expect(swapchain.allBuffersHaveRenderedLatestWholeFrameDamage == false)
        _ = try #require(swapchain.publish(plan: plan, damage: .none))
        #expect(swapchain.allBuffersHaveRenderedLatestWholeFrameDamage == false)
        _ = try #require(swapchain.publish(plan: plan, damage: .none))
        #expect(swapchain.allBuffersHaveRenderedLatestWholeFrameDamage == false)
        _ = try #require(swapchain.publish(plan: plan, damage: .none))
        #expect(swapchain.allBuffersHaveRenderedLatestWholeFrameDamage)
    }

    @Test("every presented buffer equals a from-scratch render across rotation")
    func rotationStaysByteIdentical() throws {
        // Intent: streaming publishes rotate the swapchain's buffers and every
        //   presentation is byte-identical to a from-scratch render, so a
        //   reacquired buffer's composed stale damage brings it exactly
        //   current.
        // Why it exists: this is I1 at the swapchain seam -- a composition or
        //   bring-current error shows as a band of an older generation
        //   surviving in a presented frame.
        // Scenario: 20 scrolling publishes; each returned store blits equal to
        //   the direct render, and consecutive presentations use different
        //   stores (the attached buffer is never the render target).
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 60, rows: 20))
        prefill(&terminal, rows: 20)
        _ = terminal.drainDamage()
        let box = BusyBox()
        let swapchain = try #require(box.makeSwapchain(columns: 60, rows: 20, metrics: metrics))

        var previous: TerminalFrameBackingStore?
        for step in 0..<20 {
            terminal.feed(Array((line + "\r\n").utf8))
            let damage = terminal.drainDamage()
            let plan = planFrame(for: terminal, presentation: blockCursor)
            let presented = try #require(
                swapchain.publish(plan: plan, damage: damage),
                "step \(step): free swapchain refused to present"
            )
            #expect(presented !== previous, "step \(step): attached buffer was re-rendered")
            let blitted = try blitBitmap(presented, plan: plan, metrics: metrics)
            let direct = try renderBitmap(plan: plan, metrics: metrics)
            #expect(blitted.bytes == direct.bytes, "step \(step) diverged")
            previous = presented
        }
        #expect(swapchain.hasPendingPresentation == false)
    }

    @Test("full damage escalates and still presents byte-identically")
    func fullDamageEscalates() throws {
        // Intent: a publish whose damage cannot apply incrementally (.full)
        //   still presents, via the from-scratch path, byte-identically.
        // Why it exists: escalation is the safety valve for every damage the
        //   store refuses; a swapchain that only handled applicable damage
        //   would present a stale generation on the first refusal.
        // Scenario: one normal publish, then a publish carrying .full.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 40, rows: 10))
        prefill(&terminal, rows: 10)
        _ = terminal.drainDamage()
        let box = BusyBox()
        let swapchain = try #require(box.makeSwapchain(columns: 40, rows: 10, metrics: metrics))

        let first = planFrame(for: terminal, presentation: blockCursor)
        _ = try #require(swapchain.publish(plan: first, damage: .none))

        terminal.feed(Array("changed".utf8))
        _ = terminal.drainDamage()
        let plan = planFrame(for: terminal, presentation: blockCursor)
        let presented = try #require(swapchain.publish(plan: plan, damage: .full))
        let blitted = try blitBitmap(presented, plan: plan, metrics: metrics)
        let direct = try renderBitmap(plan: plan, metrics: metrics)
        #expect(blitted.bytes == direct.bytes)
    }

    @Test("an in-use buffer is never the render target; the publish coalesces")
    func inUseBuffersAreNeverWritten() throws {
        // Intent: when every detached buffer reports in use, publish renders
        //   nothing, leaves every buffer's bytes untouched, and records one
        //   pending presentation.
        // Why it exists: I3 -- writing a surface the render server still
        //   reads tears the displayed frame; coalescing is the only safe
        //   response to an unacquirable swapchain.
        // Scenario: present once, mark the two detached buffers busy, publish
        //   two more frames; both coalesce, and the attached buffer still
        //   holds the first frame byte-for-byte.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 40, rows: 10))
        prefill(&terminal, rows: 10)
        _ = terminal.drainDamage()
        let box = BusyBox()
        let swapchain = try #require(box.makeSwapchain(columns: 40, rows: 10, metrics: metrics))

        let firstPlan = planFrame(for: terminal, presentation: blockCursor)
        let attached = try #require(swapchain.publish(plan: firstPlan, damage: .none))
        box.isBusy = { $0 !== attached }

        for _ in 0..<2 {
            terminal.feed(Array((line + "\r\n").utf8))
            let damage = terminal.drainDamage()
            let plan = planFrame(for: terminal, presentation: blockCursor)
            #expect(swapchain.publish(plan: plan, damage: damage) == nil)
            #expect(swapchain.hasPendingPresentation)
        }

        let attachedBits = try blitBitmap(attached, plan: firstPlan, metrics: metrics)
        let firstDirect = try renderBitmap(plan: firstPlan, metrics: metrics)
        #expect(attachedBits.bytes == firstDirect.bytes, "attached buffer was written while displayed")
    }

    @Test("a coalesced presentation renders in full on a later retry")
    func coalescedPresentationRendersOnRetry() throws {
        // Intent: with no further publishes arriving, a retry after buffers
        //   free renders the latest coalesced plan byte-identically and
        //   clears the pending presentation.
        // Why it exists: I3's last-frame guarantee -- the final published
        //   plan must reach the screen even when output stops right after
        //   the swapchain was momentarily unacquirable.
        // Scenario: two publishes coalesce against a fully busy swapchain;
        //   the busy set clears; one retry presents the second plan; a
        //   further retry has nothing to do.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 40, rows: 10))
        prefill(&terminal, rows: 10)
        _ = terminal.drainDamage()
        let box = BusyBox()
        let swapchain = try #require(box.makeSwapchain(columns: 40, rows: 10, metrics: metrics))

        let firstPlan = planFrame(for: terminal, presentation: blockCursor)
        let attached = try #require(swapchain.publish(plan: firstPlan, damage: .none))
        box.isBusy = { $0 !== attached }

        var latestPlan = firstPlan
        for _ in 0..<2 {
            terminal.feed(Array((line + "\r\n").utf8))
            let damage = terminal.drainDamage()
            latestPlan = planFrame(for: terminal, presentation: blockCursor)
            #expect(swapchain.publish(plan: latestPlan, damage: damage) == nil)
        }

        box.isBusy = { _ in false }
        let presented = try #require(swapchain.retryPendingPresentation())
        #expect(presented !== attached)
        let blitted = try blitBitmap(presented, plan: latestPlan, metrics: metrics)
        let direct = try renderBitmap(plan: latestPlan, metrics: metrics)
        #expect(blitted.bytes == direct.bytes)
        #expect(swapchain.hasPendingPresentation == false)
        #expect(swapchain.retryPendingPresentation() == nil)
    }

    @Test("a quiet retry presents nothing")
    func quietRetryPresentsNothing() throws {
        // Intent: retry with no pending presentation is a no-op, before and
        //   after successful publishes.
        // Why it exists: I6 -- the pending presentation bounds retries; a
        //   retry that re-rendered on a quiet pane would be periodic work.
        // Scenario: retry on a fresh swapchain, then after a presented
        //   publish; both return nothing.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 40, rows: 10))
        prefill(&terminal, rows: 10)
        _ = terminal.drainDamage()
        let box = BusyBox()
        let swapchain = try #require(box.makeSwapchain(columns: 40, rows: 10, metrics: metrics))

        #expect(swapchain.retryPendingPresentation() == nil)
        let plan = planFrame(for: terminal, presentation: blockCursor)
        _ = try #require(swapchain.publish(plan: plan, damage: .none))
        #expect(swapchain.retryPendingPresentation() == nil)
    }
}
