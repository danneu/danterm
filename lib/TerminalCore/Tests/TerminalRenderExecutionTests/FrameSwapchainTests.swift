// Headless pins for the T25 surface swapchain: acquisition never targets the
// attached or in-use buffer, publishes without an acquirable buffer coalesce
// into one pending presentation that a later retry renders, and every
// presented buffer -- fresh, one generation stale, or escalated -- is
// byte-identical to a from-scratch render of its plan. The render-server half
// of the acquisition premise (free stays free) lives in the real-AppKit pins
// in tests-ui; here the in-use report is injected so every branch is
// reachable without a compositor. The `matches` pins live here too: a
// swapchain remembers what it was built from, and the owner asks it rather
// than mirroring the inputs.

import CoreGraphics
import IOSurface
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

    /// A swapchain over a mutable busy predicate and a stand-in kernel for
    /// purgeability, so tests steer the injected in-use report per store and can
    /// reach the discarded outcome, which needs real memory pressure on a
    /// machine.
    private final class BusyBox {
        var isBusy: (TerminalFrameBackingStore) -> Bool = { _ in false }
        /// What the stand-in kernel currently holds for each store. Absent means
        /// non-volatile, which is what a fresh surface is.
        private var states: [ObjectIdentifier: IOSurfacePurgeabilityState] = [:]
        /// Stores whose `setPurgeable` the stand-in kernel refuses outright.
        var refusing: (TerminalFrameBackingStore) -> Bool = { _ in false }
        /// Stores whose volatile pages the stand-in kernel has taken, so the
        /// next reclaim reports `Empty`.
        var discarding: (TerminalFrameBackingStore) -> Bool = { _ in false }

        func state(of store: TerminalFrameBackingStore) -> IOSurfacePurgeabilityState {
            states[ObjectIdentifier(store)] ?? IOSurfacePurgeabilityState([])
        }

        private func setPurgeable(
            _ store: TerminalFrameBackingStore,
            _ newState: IOSurfacePurgeabilityState
        ) -> IOSurfacePurgeabilityState? {
            guard refusing(store) == false else { return nil }
            let key = ObjectIdentifier(store)
            var oldState = states[key] ?? IOSurfacePurgeabilityState([])
            if oldState == .purgeableVolatile, discarding(store) {
                oldState = .purgeableEmpty
            }
            if newState != .purgeableKeepCurrent {
                states[key] = newState
            }
            return oldState
        }

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
                },
                setStorePurgeable: { [weak self] store, newState in
                    guard let self else { return IOSurfacePurgeabilityState([]) }
                    return setPurgeable(store, newState)
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

    @Test("a shift covering the viewport installs the barrier; a partial one does not")
    func viewportWideShiftInstallsTheBarrier() throws {
        // Intent: the whole-frame convergence barrier goes in exactly when the
        //   published damage, with its shift folded in, covers every viewport row.
        // Why it exists: a shift-carrying publish damages few rows outright, so a
        //   rows-only reading of coverage would skip the barrier on every scroll and
        //   leave a long-cold buffer able to surface pre-scroll setup later.
        // Scenario: a settled swapchain takes a whole-viewport scroll (barrier), then
        //   a DECSTBM region scroll that shifts only rows 2..<10 (no barrier).
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 40, rows: 12))
        prefill(&terminal, rows: 12)
        _ = terminal.drainDamage()
        let swapchain = try #require(
            BusyBox().makeSwapchain(columns: 40, rows: 12, metrics: metrics)
        )

        func settle() throws {
            for _ in 0..<3 {
                let plan = planFrame(for: terminal, presentation: blockCursor)
                _ = try #require(swapchain.publish(plan: plan, damage: .none))
            }
        }
        try settle()
        #expect(swapchain.allBuffersHaveRenderedLatestWholeFrameDamage)

        terminal.feed(Array((line + "\r\n").utf8))
        let scrolled = terminal.drainDamage()
        #expect(scrolled.shift?.region == 0..<12)
        #expect(scrolled.damagedRowCount < 12)
        _ = try #require(swapchain.publish(
            plan: planFrame(for: terminal, presentation: blockCursor),
            damage: scrolled
        ))
        #expect(swapchain.allBuffersHaveRenderedLatestWholeFrameDamage == false)
        for _ in 0..<2 {
            let plan = planFrame(for: terminal, presentation: blockCursor)
            _ = try #require(swapchain.publish(plan: plan, damage: .none))
        }
        #expect(swapchain.allBuffersHaveRenderedLatestWholeFrameDamage)

        terminal.feed(Array("\u{1B}[3;10r\u{1B}[10;1H".utf8))
        _ = terminal.drainDamage()
        try settle()
        terminal.feed(Array((line + "\r\n").utf8))
        let regional = terminal.drainDamage()
        #expect(regional.shift?.region == 2..<10)
        _ = try #require(swapchain.publish(
            plan: planFrame(for: terminal, presentation: blockCursor),
            damage: regional
        ))
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
            expectBitmap(blitted, matches: direct, "step \(step) diverged")
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
        expectBitmap(blitted, matches: direct)
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
        expectBitmap(attachedBits, matches: firstDirect, "attached buffer was written while displayed")
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
        expectBitmap(blitted, matches: direct)
        #expect(swapchain.hasPendingPresentation == false)
        #expect(swapchain.retryPendingPresentation() == nil)
    }

    @Test("releasing pixels marks exactly the buffers the render server has let go of")
    func releasePixelsMarksOnlyFreeBuffers() throws {
        // Intent: `releasePixels` marks volatile every buffer reported free, leaves a
        //   buffer reported in use non-volatile, and reports how many are left; asking
        //   again once that buffer frees marks it and reports none left.
        // Why it exists: research/41 D2's property 2 -- no surface the render server
        //   may still read may hold undefined pixels. The in-use report is the only
        //   thing standing between a hidden pane's saving and a discarded surface
        //   being composited, and research/41 F8 measured one buffer still in use
        //   after a committed and flushed detach in 44 hides of 44.
        // Scenario: a chain presents once, the render server keeps holding the buffer
        //   that was attached, the owner releases, then the server lets go and the
        //   owner's retry releases again.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 40, rows: 10))
        prefill(&terminal, rows: 10)
        _ = terminal.drainDamage()
        let box = BusyBox()
        let swapchain = try #require(box.makeSwapchain(columns: 40, rows: 10, metrics: metrics))
        let plan = planFrame(for: terminal, presentation: blockCursor)
        let attached = try #require(swapchain.publish(plan: plan, damage: .none))

        box.isBusy = { $0 === attached }
        let first = swapchain.releasePixels()
        #expect(first == TerminalFramePixelRelease(released: 2, inUse: 1, failed: 0))
        #expect(box.state(of: attached) == IOSurfacePurgeabilityState([]))
        #expect(swapchain.census.storeCount(.volatile) == 2)
        #expect(swapchain.census.nonVolatileBytes == attached.surfaceBytes)

        box.isBusy = { _ in false }
        let second = swapchain.releasePixels()
        #expect(second == TerminalFramePixelRelease(released: 1, inUse: 0, failed: 0))
        #expect(box.state(of: attached) == .purgeableVolatile)
        #expect(swapchain.census.storeCount(.volatile) == 3)
        #expect(swapchain.census.nonVolatileBytes == 0)
        #expect(swapchain.census.bytes == 3 * attached.surfaceBytes)
    }

    @Test("a refused purgeability call leaves that buffer's pages alone and is reported")
    func releasePixelsReportsARefusal() throws {
        // Intent: a store whose state change the kernel refuses is counted as failed,
        //   stays non-volatile, and is asked again by the next release.
        // Why it exists: a refusal that were counted as released would take the
        //   buffer's bytes out of the census's non-volatile total while the process is
        //   still charged for every one of them, which is the exact misattribution
        //   research/41 D1 forbids.
        // Scenario: the kernel refuses one store, then stops refusing.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 40, rows: 10))
        prefill(&terminal, rows: 10)
        _ = terminal.drainDamage()
        let box = BusyBox()
        let swapchain = try #require(box.makeSwapchain(columns: 40, rows: 10, metrics: metrics))
        let plan = planFrame(for: terminal, presentation: blockCursor)
        let attached = try #require(swapchain.publish(plan: plan, damage: .none))

        box.refusing = { $0 === attached }
        #expect(
            swapchain.releasePixels()
                == TerminalFramePixelRelease(released: 2, inUse: 0, failed: 1)
        )
        #expect(swapchain.census.storeCount(.volatile) == 2)

        box.refusing = { _ in false }
        #expect(
            swapchain.releasePixels()
                == TerminalFramePixelRelease(released: 1, inUse: 0, failed: 0)
        )
        #expect(swapchain.census.storeCount(.volatile) == 3)
    }

    @Test("a released chain writes nothing and presents its pending plan after reclaim")
    func releasedPixelsAreNeverWritten() throws {
        // Intent: while its pixels are released a chain renders nothing -- publish and
        //   retry both return nil and leave the plan pending, and the buffer on screen
        //   at the release keeps its bytes -- and the first publish after an intact
        //   reclaim presents the plan that was waiting.
        // Why it exists: this is the type's own half of "no write while released"
        //   (research/41 D2). The owning view's visibility guard is the first line; a
        //   buffer whose pages the kernel may take must refuse the write regardless of
        //   who asks, because that write would fault pages back in and undo the saving
        //   even where it could not tear a frame.
        // Scenario: a chain presents, releases every buffer, takes two publishes and a
        //   retry, then reclaims intact and publishes once.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 40, rows: 10))
        prefill(&terminal, rows: 10)
        _ = terminal.drainDamage()
        let box = BusyBox()
        let swapchain = try #require(box.makeSwapchain(columns: 40, rows: 10, metrics: metrics))
        let firstPlan = planFrame(for: terminal, presentation: blockCursor)
        let attached = try #require(swapchain.publish(plan: firstPlan, damage: .none))
        #expect(swapchain.releasePixels().inUse == 0)

        var latestPlan = firstPlan
        for _ in 0..<2 {
            terminal.feed(Array((line + "\r\n").utf8))
            let damage = terminal.drainDamage()
            latestPlan = planFrame(for: terminal, presentation: blockCursor)
            #expect(swapchain.publish(plan: latestPlan, damage: damage) == nil)
        }
        #expect(swapchain.retryPendingPresentation() == nil)
        #expect(swapchain.hasPendingPresentation)
        expectBitmap(
            try blitBitmap(attached, plan: firstPlan, metrics: metrics),
            matches: try renderBitmap(plan: firstPlan, metrics: metrics),
            "a released buffer was written"
        )

        #expect(swapchain.reclaimPixels().isIntact)
        let presented = try #require(swapchain.retryPendingPresentation())
        expectBitmap(
            try blitBitmap(presented, plan: latestPlan, metrics: metrics),
            matches: try renderBitmap(plan: latestPlan, metrics: metrics),
            "the plan pending across the release did not present"
        )
        #expect(swapchain.hasPendingPresentation == false)
    }

    @Test("reclaim is intact only when every buffer's pages survived")
    func reclaimReportsWhatTheKernelDid() throws {
        // Intent: a reclaim whose returned old states are all Volatile or NonVolatile
        //   is intact; one that finds any Empty, or any refused call, is not.
        // Why it exists: `Empty` means the pixels are undefined
        //   (`IOSurfaceRef.h:438-440`), and the only safe answer is replacing the
        //   chain. A reclaim that reported intact on a discard would let an
        //   incremental render apply damage over garbage.
        // Scenario: three reclaims of a released chain -- all pages surviving, the
        //   kernel having taken one buffer's pages, and the kernel refusing one call.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 40, rows: 10))
        prefill(&terminal, rows: 10)
        _ = terminal.drainDamage()
        let box = BusyBox()
        let plan = planFrame(for: terminal, presentation: blockCursor)

        let intactChain = try #require(box.makeSwapchain(columns: 40, rows: 10, metrics: metrics))
        _ = try #require(intactChain.publish(plan: plan, damage: .none))
        intactChain.releasePixels()
        let intact = intactChain.reclaimPixels()
        #expect(intact == TerminalFramePixelReclaim(
            intact: 3, discarded: 0, nonVolatile: 0, failed: 0
        ))
        #expect(intact.isIntact)
        #expect(intactChain.census.storeCount(.nonVolatile) == 3)

        let discardedChain = try #require(box.makeSwapchain(columns: 40, rows: 10, metrics: metrics))
        let discardedStore = try #require(discardedChain.publish(plan: plan, damage: .none))
        discardedChain.releasePixels()
        box.discarding = { $0 === discardedStore }
        let discarded = discardedChain.reclaimPixels()
        #expect(discarded == TerminalFramePixelReclaim(
            intact: 2, discarded: 1, nonVolatile: 0, failed: 0
        ))
        #expect(discarded.isIntact == false)
        box.discarding = { _ in false }

        let refusedChain = try #require(box.makeSwapchain(columns: 40, rows: 10, metrics: metrics))
        let refusedStore = try #require(refusedChain.publish(plan: plan, damage: .none))
        refusedChain.releasePixels()
        box.refusing = { $0 === refusedStore }
        let refused = refusedChain.reclaimPixels()
        #expect(refused == TerminalFramePixelReclaim(
            intact: 2, discarded: 0, nonVolatile: 0, failed: 1
        ))
        #expect(refused.isIntact == false)
        box.refusing = { _ in false }

        // The buffer the render server never let go of never went volatile, and a
        // reclaim that finds it that way is not a trust break.
        let partialChain = try #require(box.makeSwapchain(columns: 40, rows: 10, metrics: metrics))
        let held = try #require(partialChain.publish(plan: plan, damage: .none))
        box.isBusy = { $0 === held }
        partialChain.releasePixels()
        box.isBusy = { _ in false }
        let partial = partialChain.reclaimPixels()
        #expect(partial == TerminalFramePixelReclaim(
            intact: 2, discarded: 0, nonVolatile: 1, failed: 0
        ))
        #expect(partial.isIntact)
    }

    @Test("every presented buffer equals a from-scratch render across release and reclaim")
    func rotationStaysByteIdenticalAcrossRelease() throws {
        // Intent: a chain that is released and intactly reclaimed between publishes
        //   keeps presenting frames byte-identical to a from-scratch render.
        // Why it exists: this is the rotation gate extended over the hidden-pane
        //   lifecycle. After an intact reclaim the pages are exactly what they were
        //   (`IOSurfaceRef.h:445`), so the stale-damage ledger must still be right --
        //   if release or reclaim disturbed it, an incremental render after a reveal
        //   would leave a band of an older generation on screen.
        // Scenario: twenty scrolling publishes, with the whole chain released and
        //   reclaimed before every fourth one, as a tab hidden and revealed does.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 60, rows: 20))
        prefill(&terminal, rows: 20)
        _ = terminal.drainDamage()
        let box = BusyBox()
        let swapchain = try #require(box.makeSwapchain(columns: 60, rows: 20, metrics: metrics))

        for step in 0..<20 {
            if step % 4 == 0 {
                swapchain.releasePixels()
                #expect(swapchain.reclaimPixels().isIntact, "step \(step): pages were not intact")
            }
            terminal.feed(Array((line + "\r\n").utf8))
            let damage = terminal.drainDamage()
            let plan = planFrame(for: terminal, presentation: blockCursor)
            let presented = try #require(
                swapchain.publish(plan: plan, damage: damage),
                "step \(step): reclaimed swapchain refused to present"
            )
            expectBitmap(
                try blitBitmap(presented, plan: plan, metrics: metrics),
                matches: try renderBitmap(plan: plan, metrics: metrics),
                "step \(step) diverged"
            )
        }
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

    @Test("the census reports one entry per buffer, summing each buffer's own size")
    func censusCountsEveryBuffer() throws {
        // Intent: a swapchain's census has one store entry per buffer it built, its
        //   bytes are the sum of those buffers' kernel-reported sizes, and `holds`
        //   answers only for its own buffers.
        // Why it exists: research/41 T1 attributes the app's IOSurface footprint by
        //   walking live panes. A census that counted a configured depth instead of
        //   the buffers it holds, or that claimed a store it does not own, would
        //   report bytes no vmmap line can be reconciled to.
        // Scenario: a depth-3 chain publishes once, then a depth-2 chain is built
        //   beside it.
        let metrics = try metrics
        var terminal = try #require(Terminal(columns: 40, rows: 10))
        prefill(&terminal, rows: 10)
        _ = terminal.drainDamage()
        let box = BusyBox()
        let swapchain = try #require(box.makeSwapchain(columns: 40, rows: 10, metrics: metrics))
        let plan = planFrame(for: terminal, presentation: blockCursor)
        let presented = try #require(swapchain.publish(plan: plan, damage: .none))

        let census = swapchain.census
        #expect(census.stores.count == 3)
        #expect(census.bytes == 3 * presented.surfaceBytes)
        #expect(census.stores.allSatisfy { $0.bytes == presented.surfaceBytes })
        #expect(census.stores.allSatisfy { $0.pixelWidth == presented.ioSurface.width })
        #expect(census.stores.allSatisfy { $0.pixelHeight == presented.ioSurface.height })
        #expect(swapchain.holds(presented))

        let other = try #require(
            box.makeSwapchain(columns: 40, rows: 10, metrics: metrics, depth: 2)
        )
        let otherPresented = try #require(other.publish(plan: plan, damage: .none))
        #expect(other.census.stores.count == 2)
        #expect(other.census.bytes == 2 * otherPresented.surfaceBytes)
        #expect(swapchain.holds(otherPresented) == false)
        #expect(other.holds(presented) == false)
    }

    @Test("a swapchain matches only the four inputs it was built from")
    func matchesEveryConstructionInput() throws {
        // Intent: the full query reports a match only when columns, rows,
        //   metrics, and color space all hold, and the metrics-only query
        //   ignores geometry.
        // Why it exists: the owner used to mirror these four values beside the
        //   swapchain, so a drift silently kept buffers built for the wrong
        //   geometry. The swapchain answering for itself removes the mirror,
        //   and each input has to count.
        // Scenario: build at 40x10 with sRGB, then vary one input at a time.
        let metrics = try metrics
        let otherMetrics = try #require(TerminalRenderMetrics(displayScale: 1))
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let swapchain = try #require(
            TerminalFrameSwapchain(columns: 40, rows: 10, metrics: metrics, colorSpace: sRGB)
        )

        #expect(swapchain.matches(columns: 40, rows: 10, metrics: metrics, colorSpace: sRGB))
        #expect(
            swapchain.matches(columns: 41, rows: 10, metrics: metrics, colorSpace: sRGB) == false
        )
        #expect(
            swapchain.matches(columns: 40, rows: 11, metrics: metrics, colorSpace: sRGB) == false
        )
        #expect(
            swapchain.matches(
                columns: 40, rows: 10, metrics: otherMetrics, colorSpace: sRGB
            ) == false
        )
        #expect(
            swapchain.matches(
                columns: 40, rows: 10, metrics: metrics, colorSpace: displayP3
            ) == false
        )

        // The metrics-only query keeps the swapchain's own geometry, so a grid
        // that moved does not by itself force a re-render: that republishes
        // through the controller instead.
        #expect(swapchain.matches(metrics: metrics, colorSpace: sRGB))
        #expect(swapchain.matches(metrics: otherMetrics, colorSpace: sRGB) == false)
        #expect(swapchain.matches(metrics: metrics, colorSpace: displayP3) == false)
    }

    @Test("color spaces match by value, not by object identity")
    func colorSpacesMatchByValue() throws {
        // Intent: two separately constructed color spaces describing the same
        //   space match, while different spaces and nil-versus-a-space do not.
        // Why it exists: this pins the premise the whole comparison rests on --
        //   `CGColorSpace` equality being by value. If a future OS compared by
        //   identity instead, every publish would rebuild the buffers, and that
        //   thrash should fail a test here rather than ship.
        // Scenario: a swapchain built with the named sRGB space, queried with
        //   an sRGB space rebuilt from its own ICC data.
        let metrics = try metrics
        let named = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let iccData = try #require(named.copyICCData())
        let rebuilt = try #require(CGColorSpace(iccData: iccData))
        let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let swapchain = try #require(
            TerminalFrameSwapchain(columns: 20, rows: 5, metrics: metrics, colorSpace: named)
        )

        #expect(swapchain.matches(metrics: metrics, colorSpace: rebuilt))
        #expect(swapchain.matches(metrics: metrics, colorSpace: displayP3) == false)
        #expect(swapchain.matches(metrics: metrics, colorSpace: nil) == false)

        // Nil is stored as passed, never normalized to sRGB: the substitution
        // for a missing space stays private to the backing store.
        let unspecified = try #require(
            TerminalFrameSwapchain(columns: 20, rows: 5, metrics: metrics)
        )
        #expect(unspecified.matches(metrics: metrics, colorSpace: nil))
        #expect(unspecified.matches(metrics: metrics, colorSpace: named) == false)
    }
}
