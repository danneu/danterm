// Headless pins for the phone's presentation path: what it presents is always
// byte-identical to a from-scratch render of the same terminal state, damage is
// never dropped on the way there, and an idle pane schedules nothing.
//
// The in-use report is injected, so buffer exhaustion and the coalesced-publish
// retry are reachable without a compositor. Byte equality is a lock-and-compare
// of the presented store's IOSurface against a scratch store rendered in full;
// the engine's own `BitmapTestSupport` is private to its test target.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Foundation
import IOSurface
import TerminalCore
import TerminalCoreRecording
import TerminalRenderExecution
import TerminalRenderPlanning
import Testing

struct FramePresenterTests {
    private var metrics: TerminalRenderMetrics {
        get throws { try #require(TerminalRenderMetrics(displayScale: 2)) }
    }

    @Test("An idle presenter needs no tick and presents nothing")
    func idlePresentsNothing() throws {
        let busy = BusyBox()
        let presenter = busy.makePresenter()
        let stream = try Stream(text: "hello")

        #expect(presenter.needsTick == false)
        #expect(presenter.tick(&stream.replica) == nil)
        #expect(presenter.attachedStore == nil)

        #expect(presenter.fit(columns: stream.columns, rows: stream.rows, metrics: try metrics))
        #expect(presenter.needsTick)
        _ = try #require(presenter.tick(&stream.replica))
        #expect(presenter.needsTick == false)
        #expect(presenter.tick(&stream.replica) == nil)
    }

    @Test("A record that damages nothing presents nothing")
    func damagelessRecordPresentsNothing() throws {
        let busy = BusyBox()
        let presenter = busy.makePresenter()
        let stream = try Stream(text: "hello")
        #expect(presenter.fit(columns: stream.columns, rows: stream.rows, metrics: try metrics))
        let attached = try #require(presenter.tick(&stream.replica))

        // A style change writes no cell and moves no cursor, so the engine records
        // no damage for it and the phone must present nothing at all.
        try stream.feed("\u{1B}[0m")
        presenter.noteDrainPending()
        #expect(presenter.needsTick)
        #expect(presenter.tick(&stream.replica) == nil)
        #expect(presenter.attachedStore === attached)
        #expect(presenter.needsTick == false)
    }

    @Test("A record, a local scroll, and a rebuild each ask for a tick")
    func everyStimulusAsksForATick() throws {
        let busy = BusyBox()
        let presenter = busy.makePresenter()
        let stream = try Stream(text: "hello", rows: 3)
        for _ in 0..<8 { try stream.feed("line\r\n") }
        #expect(presenter.fit(columns: stream.columns, rows: 3, metrics: try metrics))
        _ = try #require(presenter.tick(&stream.replica))
        #expect(presenter.needsTick == false)

        try stream.feed("x")
        presenter.noteDrainPending()
        #expect(presenter.needsTick)
        _ = try #require(presenter.tick(&stream.replica))

        stream.replica.scrollViewport(byRows: -2)
        presenter.noteDrainPending()
        #expect(presenter.needsTick)
        _ = try #require(presenter.tick(&stream.replica))
        #expect(presenter.needsTick == false)

        #expect(presenter.fit(
            columns: stream.columns,
            rows: 3,
            metrics: try #require(TerminalRenderMetrics(displayScale: 3))
        ))
        #expect(presenter.needsTick)
    }

    @Test("A rebuilt presenter redraws in full on its first tick with an empty drain")
    func rebuildRedrawsWithoutNewOutput() throws {
        // Intent: refitting for new metrics presents a full frame even though no
        //   terminal row changed.
        // Why it exists: rotation, a display-scale move, and entering a window all
        //   rebuild the surface without damaging the terminal. Waiting for output
        //   would leave the old pixels on screen at the new bounds.
        // Scenario: a settled pane is refitted at a different display scale and
        //   ticked once, with nothing fed in between.
        let busy = BusyBox()
        let presenter = busy.makePresenter()
        let stream = try Stream(text: "settled")
        #expect(presenter.fit(columns: stream.columns, rows: stream.rows, metrics: try metrics))
        _ = try #require(presenter.tick(&stream.replica))
        #expect(presenter.needsTick == false)

        let rebuiltMetrics = try #require(TerminalRenderMetrics(displayScale: 3))
        #expect(presenter.fit(
            columns: stream.columns,
            rows: stream.rows,
            metrics: rebuiltMetrics
        ))
        let terminal = try #require(stream.replica.terminal)
        let store = try #require(presenter.tick(&stream.replica))
        #expect(presenter.lastRenderedDamage == .full)
        try expectFullRenderEquality(store, terminal: terminal, metrics: rebuiltMetrics)
    }

    @Test("Every presented frame equals a from-scratch render of its terminal")
    func presentedFramesEqualFullRenders() throws {
        // Intent: incremental planning and rotating buffers never change what the
        //   phone shows.
        // Why it exists: this is the whole safety claim of presenting through the
        //   swapchain rather than repainting every pixel once per tick.
        // Scenario: an output-driven scroll stream (shift damage), then a sync
        //   replacement, then a grid change, each compared against a scratch render.
        let busy = BusyBox()
        let presenter = busy.makePresenter()
        let stream = try Stream(text: "start")
        #expect(presenter.fit(columns: stream.columns, rows: stream.rows, metrics: try metrics))

        for index in 0..<12 {
            try stream.feed("row \(index) gjpqy 0123456789\r\n")
            presenter.noteDrainPending()
            let terminal = try #require(stream.replica.terminal)
            let store = try #require(presenter.tick(&stream.replica))
            try expectFullRenderEquality(store, terminal: terminal, metrics: try metrics)
        }

        try stream.synchronize(text: "replaced mid-stream")
        presenter.noteDrainPending()
        let synced = try #require(stream.replica.terminal)
        let syncedStore = try #require(presenter.tick(&stream.replica))
        #expect(presenter.lastRenderedDamage == .full)
        try expectFullRenderEquality(syncedStore, terminal: synced, metrics: try metrics)

        try stream.synchronize(text: "regrown", columns: 30, rows: 8)
        #expect(presenter.fit(columns: 30, rows: 8, metrics: try metrics))
        let regrown = try #require(stream.replica.terminal)
        let regrownStore = try #require(presenter.tick(&stream.replica))
        #expect(presenter.lastRenderedDamage == .full)
        try expectFullRenderEquality(regrownStore, terminal: regrown, metrics: try metrics)
    }

    @Test("A one-row change on a settled screen renders only that row")
    func settledScreenRendersIncrementally() throws {
        // Intent: once every buffer has presented, a one-row edit renders that row
        //   alone instead of the whole grid.
        // Why it exists: it is the narrowing this presentation path exists for, and a
        //   regression is invisible on screen while costing a full repaint per tick.
        // Scenario: four single-character appends on the cursor's own row, one more
        //   publish than the swapchain has buffers.
        let busy = BusyBox()
        let presenter = busy.makePresenter()
        let stream = try Stream(text: "settled screen")
        #expect(presenter.fit(columns: stream.columns, rows: stream.rows, metrics: try metrics))
        _ = try #require(presenter.tick(&stream.replica))

        for character in ["a", "b", "c", "d"] {
            try stream.feed(character)
            presenter.noteDrainPending()
            let terminal = try #require(stream.replica.terminal)
            let store = try #require(presenter.tick(&stream.replica))
            try expectFullRenderEquality(store, terminal: terminal, metrics: try metrics)
        }

        let rendered = try #require(presenter.lastRenderedDamage)
        #expect(rendered.isFull == false)
        #expect(rendered.damagedRowCount == 1)
    }

    @Test("Reset shows nothing until the replacement stream's first full frame")
    func resetDetachesUntilTheNextStream() throws {
        // Intent: selecting another pane never shows the previous pane's pixels.
        // Why it exists: the frame stores outlive the stream they were filled from,
        //   so a reset that only rebuilt them would keep the old frame attached.
        // Scenario: a settled pane is reset, then a second stream is fitted and ticked.
        let busy = BusyBox()
        let presenter = busy.makePresenter()
        let stream = try Stream(text: "first pane")
        #expect(presenter.fit(columns: stream.columns, rows: stream.rows, metrics: try metrics))
        _ = try #require(presenter.tick(&stream.replica))
        #expect(presenter.attachedStore != nil)

        presenter.resetStream()
        #expect(presenter.attachedStore == nil)
        #expect(presenter.needsTick == false)

        let replacement = try Stream(text: "second pane")
        #expect(presenter.fit(
            columns: replacement.columns,
            rows: replacement.rows,
            metrics: try metrics
        ))
        let terminal = try #require(replacement.replica.terminal)
        let store = try #require(presenter.tick(&replacement.replica))
        #expect(presenter.lastRenderedDamage == .full)
        try expectFullRenderEquality(store, terminal: terminal, metrics: try metrics)
    }

    @Test("A same-stream rebuild keeps the attached frame until its successor renders")
    func rebuildKeepsTheAttachedFrame() throws {
        let busy = BusyBox()
        let presenter = busy.makePresenter()
        let stream = try Stream(text: "kept")
        #expect(presenter.fit(columns: stream.columns, rows: stream.rows, metrics: try metrics))
        let attached = try #require(presenter.tick(&stream.replica))

        #expect(presenter.fit(
            columns: stream.columns,
            rows: stream.rows,
            metrics: try #require(TerminalRenderMetrics(displayScale: 3))
        ))
        #expect(presenter.attachedStore === attached)
        let store = try #require(presenter.tick(&stream.replica))
        #expect(presenter.attachedStore === store)
        #expect(store !== attached)
    }

    @Test("Damage marked before an extent is fitted survives until the first fit")
    func damageSurvivesUntilFitted() throws {
        // Intent: records that arrive before this view has an extent still reach the
        //   first frame.
        // Why it exists: a checkpoint-restored quiet pane produces no further output,
        //   so damage consumed by a tick with nowhere to draw would leave it blank.
        // Scenario: a record is marked pending with no surface fitted, ticked, and
        //   only then fitted.
        let busy = BusyBox()
        let presenter = busy.makePresenter()
        let stream = try Stream(text: "before layout")
        presenter.noteDrainPending()
        #expect(presenter.needsTick == false)
        #expect(presenter.tick(&stream.replica) == nil)

        #expect(presenter.fit(columns: stream.columns, rows: stream.rows, metrics: try metrics))
        let terminal = try #require(stream.replica.terminal)
        let store = try #require(presenter.tick(&stream.replica))
        #expect(presenter.lastRenderedDamage == .full)
        try expectFullRenderEquality(store, terminal: terminal, metrics: try metrics)
    }

    @Test("A publish with no free buffer coalesces and a later tick presents it")
    func coalescedPublishIsRetried() throws {
        // Intent: a tick that cannot acquire a buffer keeps asking, and the retry
        //   presents the newest plan into a detached store.
        // Why it exists: the render server can hold every detached buffer across
        //   several presentations; dropping the frame would leave the screen stale.
        // Scenario: every detached store is reported busy for two publishes, then
        //   freed.
        let busy = BusyBox()
        let presenter = busy.makePresenter()
        let stream = try Stream(text: "coalesce")
        #expect(presenter.fit(columns: stream.columns, rows: stream.rows, metrics: try metrics))
        let attached = try #require(presenter.tick(&stream.replica))

        busy.isBusy = { $0 !== attached }
        try stream.feed("first")
        presenter.noteDrainPending()
        #expect(presenter.tick(&stream.replica) == nil)
        #expect(presenter.needsTick)

        try stream.feed(" second")
        presenter.noteDrainPending()
        #expect(presenter.tick(&stream.replica) == nil)
        #expect(presenter.needsTick)

        busy.isBusy = { _ in false }
        let newest = try #require(stream.replica.terminal)
        let store = try #require(presenter.tick(&stream.replica))
        #expect(store !== attached)
        try expectFullRenderEquality(store, terminal: newest, metrics: try metrics)
        #expect(presenter.needsTick == false)
    }

    @Test("A failed drain never ends a tick that still owes a presentation")
    func pendingPresentationOutlivesAFailedDrain() throws {
        // Intent: a pending frame reaches the screen even after the replica stops
        //   being exact.
        // Why it exists: a gap freezes the replica, so the drain that would have
        //   driven the tick returns nothing -- and the coalesced frame is the last
        //   thing the user can still be shown.
        // Scenario: a publish coalesces, a gap record arrives, then a buffer frees.
        let busy = BusyBox()
        let presenter = busy.makePresenter()
        let stream = try Stream(text: "pending")
        #expect(presenter.fit(columns: stream.columns, rows: stream.rows, metrics: try metrics))
        let attached = try #require(presenter.tick(&stream.replica))

        busy.isBusy = { $0 !== attached }
        try stream.feed("late frame")
        presenter.noteDrainPending()
        let pendingTerminal = try #require(stream.replica.terminal)
        #expect(presenter.tick(&stream.replica) == nil)

        try stream.declareGap()
        presenter.noteDrainPending()
        #expect(presenter.tick(&stream.replica) == nil)
        #expect(presenter.needsTick)

        busy.isBusy = { _ in false }
        presenter.noteDrainPending()
        let store = try #require(presenter.tick(&stream.replica))
        try expectFullRenderEquality(store, terminal: pendingTerminal, metrics: try metrics)
        #expect(presenter.needsTick == false)
    }

    // MARK: - Support

    /// A presenter over a mutable busy predicate, so a test steers the injected
    /// in-use report per store exactly as the engine's swapchain tests do.
    private final class BusyBox {
        var isBusy: (TerminalFrameBackingStore) -> Bool = { _ in false }

        func makePresenter() -> MobileFramePresenter {
            MobileFramePresenter(isStoreInUse: { [weak self] store in
                self?.isBusy(store) ?? false
            })
        }
    }

    /// One replica plus the cursor bookkeeping its records must agree with, so a
    /// test states what the pane emitted rather than what the tape encodes.
    private final class Stream {
        var replica = PaneReplica()
        private(set) var columns: Int
        private(set) var rows: Int
        private var sequence: UInt64 = 1
        private var feedBytes = 0

        init(text: String, columns: Int = 24, rows: Int = 6) throws {
            self.columns = columns
            self.rows = rows
            try synchronize(text: text)
        }

        func synchronize(text: String, columns: Int? = nil, rows: Int? = nil) throws {
            self.columns = columns ?? self.columns
            self.rows = rows ?? self.rows
            sequence += 1
            feedBytes = 0
            try replica.apply(.sync(PaneTapeSyncRecord(
                part: 1,
                parts: 1,
                bytes: Data(text.utf8),
                transfer: PaneTapeSyncRecord.Transfer(
                    columns: self.columns,
                    rows: self.rows,
                    pinned: false,
                    droppedHistoryRows: 0,
                    focused: false
                ),
                cursor: PaneTapeCursor(
                    recorderLifetimeId: Self.lifetimeId,
                    nextSequence: sequence,
                    feedBytesBeforeNextSequence: 0,
                    writeBytesBeforeNextSequence: 0
                )
            )))
        }

        func feed(_ text: String) throws {
            let bytes = Array(text.utf8)
            try replica.apply(.event(PaneTapeEventRecord(
                sequence: sequence,
                elapsedNanoseconds: sequence,
                originElapsedNanoseconds: nil,
                byteOffset: feedBytes,
                byteLength: bytes.count,
                event: .feed(bytes)
            )))
            sequence += 1
            feedBytes += bytes.count
        }

        func declareGap() throws {
            try replica.apply(.gap(PaneTapeGapRecord(
                droppedEventCount: 1,
                droppedFeedBytes: 1,
                droppedWriteBytes: 0
            )))
        }

        private static let lifetimeId =
            UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    }

    private func expectFullRenderEquality(
        _ store: TerminalFrameBackingStore,
        terminal: Terminal,
        metrics: TerminalRenderMetrics,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let plan = planFrame(
            for: terminal,
            presentation: MobileFramePresenter.presentation(for: terminal)
        )
        let scratch = try #require(
            TerminalFrameBackingStore(
                columns: plan.columns,
                rows: plan.rowCount,
                metrics: metrics
            ),
            sourceLocation: sourceLocation
        )
        scratch.renderFull(plan)
        #expect(
            surfaceBytes(store) == surfaceBytes(scratch),
            "presented pixels differ from a from-scratch render",
            sourceLocation: sourceLocation
        )
    }

    private func surfaceBytes(_ store: TerminalFrameBackingStore) -> [UInt8] {
        let surface = store.ioSurface
        surface.lock(options: [.readOnly], seed: nil)
        defer { surface.unlock(options: [.readOnly], seed: nil) }
        return [UInt8](UnsafeRawBufferPointer(
            start: surface.baseAddress,
            count: surface.bytesPerRow * surface.height
        ))
    }
}
