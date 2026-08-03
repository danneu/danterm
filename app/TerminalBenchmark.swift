// Env-gated app-side geometry convergence and timing for terminal benchmarks.
// It resizes the window to a requested grid, then observes the exact Swift frame
// consumed by draw without adding hooks to TerminalCore.
import Cocoa
import TerminalBenchmarkCoverage
import TerminalBenchmarkMarkers
import TerminalBenchmarkTopology
import TerminalCore
import TerminalPaneSession
import TerminalRenderExecution
import TerminalRenderPlanning

#if DANTERM_TERMINAL_BENCHMARK
/// Captures every machine or visibility state that can invalidate a measured block.
@MainActor
final class TerminalBenchmarkStateRecorder {
    private weak var window: NSWindow?
    private let thermalStateOverride: String?
    private let stateResultPath: String?
    private var recording = false
    private(set) var samples: [[String: Any]] = []
    nonisolated(unsafe) private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(window: NSWindow, environment: [String: String]) {
        self.window = window
        self.thermalStateOverride = environment["DANTERM_BENCHMARK_THERMAL_STATE_OVERRIDE"]
            .flatMap { $0.isEmpty ? nil : $0 }
        self.stateResultPath = environment["DANTERM_TERMINAL_BENCHMARK_STATE_RESULT"]
        let center = NotificationCenter.default
        for name in [
            ProcessInfo.thermalStateDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
        ] {
            let token = center.addObserver(
                forName: name,
                object: ProcessInfo.processInfo,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.record(reason: "machine-state-change")
                }
            }
            notificationTokens.append((center, token))
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let workspaceToken = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.record(reason: "active-space-change", activeSpaceChanged: true)
            }
        }
        notificationTokens.append((workspaceCenter, workspaceToken))
    }

    deinit {
        for (center, token) in notificationTokens {
            center.removeObserver(token)
        }
    }

    func beginBlock() {
        samples = []
        recording = true
        record(reason: "start")
    }

    func windowDidChangeOcclusionState() {
        record(reason: "occlusion-change")
    }

    func observeDrawState() {
        guard isWindowPresentedLocally() == false else { return }
        record(reason: "draw-while-occluded")
    }

    func finishBlock() -> [[String: Any]] {
        record(reason: "completion")
        recording = false
        return samples
    }

    private func record(reason: String, activeSpaceChanged: Bool = false) {
        guard recording else { return }
        let info = ProcessInfo.processInfo
        samples.append([
            "reason": reason,
            "activeSpaceChanged": activeSpaceChanged,
            "visible": isWindowVisible(),
            "thermalState": thermalStateOverride ?? thermalStateName(info.thermalState),
            "lowPowerMode": info.isLowPowerModeEnabled,
        ])
        checkpointSamples()
    }

    private func checkpointSamples() {
        guard let stateResultPath,
              let data = try? JSONSerialization.data(
                  withJSONObject: ["machineStateSamples": samples],
                  options: [.sortedKeys]
              )
        else { return }
        try? data.write(to: URL(fileURLWithPath: stateResultPath), options: .atomic)
    }

    /// The occlusion and containment half of the visibility contract, using only in-process
    /// AppKit state. Split out because `observeDrawState()` runs on every draw and the
    /// WindowServer round-trip below cost ~30% of main-thread busy time in the
    /// full-screen-content-churn profile -- more than the drawing it was policing. AppKit
    /// keeps `occlusionState` current from the same notification that drives
    /// `windowDidChangeOcclusionState()`, so the per-draw tripwire still fires on a real
    /// occlusion; `record()` keeps the full check, so every sample that reaches validation
    /// still carries the WindowServer confirmation.
    private func isWindowPresentedLocally() -> Bool {
        guard let window, window.occlusionState.contains(.visible) else { return false }
        guard let screenVisibleFrame = window.screen?.visibleFrame,
              screenVisibleFrame.contains(window.frame)
        else { return false }
        return true
    }

    /// Samples the two conditions a profiled input-driven workload must hold for:
    /// this app is the frontmost one, and its window is really on screen.
    ///
    /// Exposed from here rather than re-probed by the activity publisher because
    /// this type already owns the window and the full presentation check. The
    /// caller is the observer's 100 ms wall-clock sampling timer, which exists
    /// only on profiling runs and fires whether or not the app is drawing, so
    /// the WindowServer round-trip inside `isWindowVisible()` -- the reason
    /// `observeDrawState()` uses the cheaper local check -- is paid at most ten
    /// times a second and never on a measured path.
    func presentationCoverageSample() -> (isForeground: Bool, isPresented: Bool) {
        (NSApplication.shared.isActive, isWindowVisible())
    }

    private func isWindowVisible() -> Bool {
        guard isWindowPresentedLocally(), let window else { return false }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(window.windowNumber)
        ) as? [[String: Any]],
        let windowInfo = windows.first,
        let onScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool
        else { return false }
        return onScreen
    }

    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// Carries one backend's achieved grid and point-sized cells across the narrow session seam.
struct TerminalBenchmarkGeometry: Equatable {
    let columns: Int
    let rows: Int
    let cellWidth: CGFloat
    let cellHeight: CGFloat
}

/// Converges the benchmark window by correcting only the terminal grid's point-size delta.
@MainActor
final class TerminalBenchmarkGeometryController {
    private weak var window: NSWindow?
    private let targetColumns: Int
    private let targetRows: Int
    private let session: () -> (any TerminalSession)?
    private var timer: Timer?

    init?(
        window: NSWindow,
        environment: [String: String],
        session: @escaping () -> (any TerminalSession)?
    ) {
        guard let columnsValue = environment["DANTERM_TERMINAL_BENCHMARK_COLUMNS"],
              let rowsValue = environment["DANTERM_TERMINAL_BENCHMARK_ROWS"],
              let columns = Int(columnsValue), columns > 0,
              let rows = Int(rowsValue), rows > 0
        else { return nil }
        self.window = window
        self.targetColumns = columns
        self.targetRows = rows
        self.session = session
    }

    deinit {
        timer?.invalidate()
    }

    /// Starts bounded-cadence convergence on the main run loop after pane creation.
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.convergeOnce()
            }
        }
    }

    private func convergeOnce() {
        guard let window, let geometry = session()?.benchmarkGeometry else { return }
        guard geometry.columns != targetColumns || geometry.rows != targetRows else {
            if let screenVisibleFrame = window.screen?.visibleFrame {
                window.setFrameTopLeftPoint(NSPoint(
                    x: screenVisibleFrame.minX,
                    y: screenVisibleFrame.maxY
                ))
            }
            timer?.invalidate()
            timer = nil
            return
        }
        let widthDelta = CGFloat(targetColumns - geometry.columns) * geometry.cellWidth
        let heightDelta = CGFloat(targetRows - geometry.rows) * geometry.cellHeight
        let contentSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
        window.setContentSize(NSSize(
            width: contentSize.width + widthDelta,
            height: contentSize.height + heightDelta
        ))
    }
}

/// Measures parse-to-draw benchmark markers without adding hooks to TerminalCore.
@MainActor
final class TerminalBenchmarkObserver {
    static let shared = TerminalBenchmarkObserver(environment: ProcessInfo.processInfo.environment)

    /// Keeps per-draw topology accounting to bounded counter updates until snapshot encoding.
    private struct DamageTopologyKey: Hashable {
        let damagedRowCount: Int
        let spanCount: Int
        let isFull: Bool
        let usedDirtyRectFallback: Bool
    }

    private let startMarker: String
    private let completionMarker: String
    private let expectedFinalState: String
    private let startAcknowledgmentPath: String
    private let startDrawAcknowledgmentPath: String?
    private let readyDrawAcknowledgmentPath: String?
    private let localizedDrawAcknowledgmentPrefix: String?
    private let resultPath: String
    private let profilesIncrementalMixedDamage: Bool
    /// True when the producer sends a settling frame before its measured draws.
    private let requiresSettlingDraw: Bool
    /// True when one app serves many blocks and must re-arm between them.
    private let reusesBlocks: Bool
    /// The two block-boundary paths, encoded once: they are probed on every
    /// published frame of an open block.
    private let resultPathBytes: [CChar]
    private let startAcknowledgmentPathBytes: [CChar]
    private var startNanoseconds: UInt64?
    private var completed = false
    private var localizedSequences = Set<Int>()
    private var observedSettlingDraw = false
    private var localizedDrawDurations: [UInt64] = []
    private var localizedDirtyRowCounts: [Int] = []
    /// Planning cost published since the last accepted draw, and how many
    /// `planFrame` calls it covers.
    ///
    /// Accumulated rather than latched because AppKit can coalesce several
    /// published frames into one draw; summing attributes every plan the block
    /// actually paid for instead of silently discarding the superseded ones.
    private var pendingPlanNanoseconds: UInt64 = 0
    private var pendingPlanFrameCount = 0
    private var acceptedPlanDurations: [UInt64] = []
    private var acceptedPlanFrameCount = 0
    /// Main-actor time blocked in the per-delivery drain fence, accumulated the same
    /// way and for the same reason as the plan cost above: several published frames
    /// can coalesce into one draw, and every fence the block waited on was really
    /// paid. The max is tracked separately because the decision this answers is
    /// whether a single block exceeds a frame budget, which a sum cannot show.
    private var pendingFenceStallNanoseconds: UInt64 = 0
    private var pendingFenceStallCount = 0
    private var acceptedFenceStallDurations: [UInt64] = []
    private var acceptedFenceStallCount = 0
    private var acceptedFenceStallMaxNanoseconds: UInt64 = 0
    /// Whole-process CPU time, summed over every thread, charged to each accepted
    /// draw as the delta since the previously accepted one.
    ///
    /// Exists because `drawDurationNanoseconds` measures elapsed time between two
    /// points on the main thread, so work done on any other thread is invisible
    /// to it at any size. Doc 17's `F6` found the single largest cost in the app
    /// -- Core Animation recomputing per-glyph bounds during display-list replay,
    /// 16.8% of one workload's on-CPU total -- sitting in exactly that blind
    /// spot, visible only to a diagnostic-only profiler. This is the same
    /// quantity a decision block can carry.
    ///
    /// It measures CPU consumed, not latency: work moved onto an otherwise idle
    /// core reads as neutral here. That makes it the right metric for "did we
    /// stop doing this work" and the wrong one for frame time.
    private var blockStartProcessCPUNanoseconds: UInt64?
    private var lastAcceptedProcessCPUNanoseconds: UInt64?
    private var acceptedProcessCPUDurations: [UInt64] = []
    private var pendingRedrawSequence: Int?
    private var publishedRedrawSequence: Int?
    private var redrawSequences = Set<Int>()
    /// Accepted-draw selection and topology evidence for the two sparse-span
    /// workloads, and nil for every other one -- which is what keeps this whole
    /// accounting off the five existing workloads' measured path.
    private var sparseSpanRecorder: TerminalBenchmarkSparseSpanRecorder?
    /// Engine damage published since the current redraw sequence appeared,
    /// unioned rather than latched.
    ///
    /// One producer update is one stimulus, but the parser can publish it as
    /// several frames, so the frame carrying the sequence number in its OSC
    /// title may hold only part of the damaged rows. Unioning until a draw is
    /// accepted reconstructs the update's real topology; resetting when a new
    /// sequence arrives is what keeps the settling frame's rows out of the first
    /// measured update.
    private var pendingEngineDamage = TerminalDamage.none
    /// Where lifetime draw/plan-publish counts are republished for an attached
    /// profiler, and the counts themselves. Absent outside profiling runs.
    ///
    /// A `loop`-mode app never completes a block, so none of the accepted-draw
    /// accounting above is ever written and a profiler attached to it has no
    /// frame count to normalize its samples by. Doc 17's `F5` had to rest on
    /// commit history for exactly that reason, and its three substitute frame
    /// proxies disagreed by 1.7x. These are lifetime totals over *every* draw
    /// the app performed -- which is what a profile actually contains -- so
    /// unlike the accepted counters they are never cleared by
    /// `reopenCompletedBlockIfRequested`.
    private let activityPath: String?
    private var observedDrawCount = 0
    private var observedPlanFrameCount = 0
    private var observedDamageTopologySampleCount = 0
    private var observedDamageTopologyHistogram: [DamageTopologyKey: Int] = [:]
    private var observedDamagedRowCountHistogram: [Int: Int] = [:]
    private var observedContiguousSpanCountHistogram: [Int: Int] = [:]
    private var observedFullDamageCount = 0
    private var observedDirtyRectFallbackCount = 0
    private var lastActivityWriteNanoseconds: UInt64 = 0
    /// Lifetime foreground/presentation samples, taken on a wall-clock cadence so
    /// a profiling window can be shown to have been attributable.
    /// Published only when a state recorder exists to produce the samples --
    /// counters nobody fed would report an unsampled run as a clean one.
    private var presentationCoverage = TerminalBenchmarkPresentationCoverageRecorder()
    /// The wall-clock sampler behind `presentationCoverage`. Absent outside
    /// profiling runs, and never touched by the draw path.
    private var presentationSamplingTimer: Timer?
    private weak var measuredController: TerminalPaneSessionController?
    private var fenceBlockPolicy = TerminalPaneFenceBlockPolicy()
    /// Retained for the lifetime of the observer, not built per frame: it holds
    /// the scratch buffer that keeps marker detection off the allocator.
    private var markerScanner: TerminalBenchmarkMarkerScanner
    var stateRecorder: TerminalBenchmarkStateRecorder?

    init?(environment: [String: String]) {
        guard let startMarker = environment["DANTERM_TERMINAL_BENCHMARK_START_MARKER"],
              let completionMarker = environment["DANTERM_TERMINAL_BENCHMARK_COMPLETION_MARKER"],
              let expectedFinalState = environment["DANTERM_TERMINAL_BENCHMARK_EXPECTED_FINAL_STATE"],
              let startAcknowledgmentPath = environment["DANTERM_TERMINAL_BENCHMARK_START_ACK"],
              let resultPath = environment["DANTERM_TERMINAL_BENCHMARK_RESULT"]
        else { return nil }
        self.startMarker = startMarker
        self.completionMarker = completionMarker
        self.expectedFinalState = expectedFinalState
        self.startAcknowledgmentPath = startAcknowledgmentPath
        self.startDrawAcknowledgmentPath =
            environment["DANTERM_TERMINAL_BENCHMARK_START_DRAW_ACK"]
        self.readyDrawAcknowledgmentPath =
            environment["DANTERM_TERMINAL_BENCHMARK_READY_DRAW_ACK"]
        self.localizedDrawAcknowledgmentPrefix =
            environment["DANTERM_TERMINAL_BENCHMARK_LOCALIZED_DRAW_ACK_PREFIX"]
        self.resultPath = resultPath
        self.markerScanner = TerminalBenchmarkMarkerScanner(
            startMarker: startMarker,
            completionMarker: completionMarker,
            expectedFinalState: expectedFinalState
        )
        self.profilesIncrementalMixedDamage =
            environment["DANTERM_TERMINAL_BENCHMARK_WORKLOAD"]
                == "full-screen-incremental-mixed-churn"
        self.sparseSpanRecorder = environment["DANTERM_TERMINAL_BENCHMARK_WORKLOAD"]
            .flatMap(TerminalBenchmarkSparseSpanRecorder.init(workload:))
        let updateCount = { (name: String) in
            environment[name].flatMap(Int.init) ?? 0
        }
        self.requiresSettlingDraw =
            updateCount("DANTERM_TERMINAL_BENCHMARK_LOCALIZED_UPDATES") > 0
            || updateCount("DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES") > 0
        self.reusesBlocks = environment["DANTERM_BENCHMARK_MODE"] == "persistent"
        self.activityPath = environment["DANTERM_TERMINAL_BENCHMARK_ACTIVITY_PATH"]
            .flatMap { $0.isEmpty ? nil : $0 }
        self.resultPathBytes = resultPath.utf8CString.map { $0 }
        self.startAcknowledgmentPathBytes = startAcknowledgmentPath.utf8CString.map { $0 }
    }

    deinit {
        presentationSamplingTimer?.invalidate()
    }

    /// Starts sampling foreground/presentation on wall-clock time, for profiling
    /// runs only.
    ///
    /// The sample used to be taken inside `publishActivity`, which the draw path
    /// calls -- so its real rate was `min(draw rate, 10/s)` and the coverage
    /// section certified exactly the instants the app happened to be busy. A run
    /// that drew 19 times in 13 seconds reported `lapsedForegroundSamples: 0`
    /// from 19 observations, and a Cmd-Tab shorter than the ~700 ms between them
    /// would have been invisible to it. Observing focus requires a clock that
    /// does not belong to the thing being observed.
    ///
    /// A timer of its own rather than `TerminalBenchmarkGeometryController`'s
    /// 20 ms one: that timer invalidates itself the moment the grid converges,
    /// seconds before any profiler attaches, so reusing it would sample only the
    /// window nobody profiles -- and it is deliberately fast for convergence,
    /// which is 5x more WindowServer round-trips than this needs.
    ///
    /// Scheduled in `.common` modes so a tracking or modal run loop -- which a
    /// GUI capture can enter without the app being wrong -- does not silently
    /// stop the sampler and reproduce the hole this closes. It stays outside
    /// every measured bracket for the same reason the draw-path publish did: it
    /// runs on the run loop between draws, never inside one. It cannot see a
    /// main-thread hang, though: a blocked main thread stops this timer too, so
    /// a true hang still yields no samples. That residual is the density floor's
    /// to catch -- too few samples for the interval is exactly what a hang leaves
    /// behind, and `presentation_coverage` rejects it.
    func startPresentationSampling() {
        guard activityPath != nil, presentationSamplingTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.samplePresentationCoverage()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        presentationSamplingTimer = timer
    }

    /// Takes one wall-clock foreground/presentation sample and republishes the
    /// activity snapshot that carries it.
    ///
    /// The sample is taken unconditionally and the publish is left to its own
    /// 100 ms throttle: the sample is the measurement whose cadence has to be
    /// uniform, while the write is only how a reader sees it, and a write the
    /// draw path already did a moment ago costs a sample nothing.
    private func samplePresentationCoverage() {
        guard let activityPath else { return }
        if let stateRecorder {
            let sample = stateRecorder.presentationCoverageSample()
            presentationCoverage.record(
                isForeground: sample.isForeground,
                isPresented: sample.isPresented
            )
        }
        publishActivity(atPath: activityPath)
    }

    /// Selects the one pane whose cumulative fence counters define benchmark blocks.
    func attachFenceMetricsController(_ controller: TerminalPaneSessionController) {
        guard measuredController == nil || measuredController === controller else { return }
        measuredController = controller
    }

    /// Drops controller access and invalidates any span that can no longer complete safely.
    func detachFenceMetricsController(_ controller: TerminalPaneSessionController) {
        guard measuredController === controller else { return }
        fenceBlockPolicy.invalidateAfterApplicationExitFence()
        measuredController = nil
    }

    /// Invalidates an open span after the controller's application-exit fence returns.
    func observeApplicationExitFence(
        for controller: TerminalPaneSessionController
    ) {
        detachFenceMetricsController(controller)
    }

    /// Records the app-side observation before a newly parsed frame becomes drawable.
    ///
    /// `planDurationNanoseconds` is the cost of the `planFrame` call that produced
    /// this plan. It is collected here because planning happens on the PTY-output
    /// path, outside the draw timer that produces `drawDurationNanoseconds`.
    /// `damage` is the frame's own changed rows. It is what separates a marker
    /// this frame wrote from one an earlier block left standing on the screen.
    func observePublishedFrame(
        _ plan: RenderFramePlan,
        damage: TerminalDamage,
        planDurationNanoseconds: UInt64 = 0,
        fenceStallNanoseconds: UInt64 = 0
    ) {
        if activityPath != nil { observedPlanFrameCount += 1 }
        reopenCompletedBlockIfRequested()
        if startNanoseconds != nil, completed == false {
            pendingPlanNanoseconds += planDurationNanoseconds
            pendingPlanFrameCount += 1
            pendingFenceStallNanoseconds += fenceStallNanoseconds
            pendingFenceStallCount += 1
            acceptedFenceStallMaxNanoseconds = max(
                acceptedFenceStallMaxNanoseconds,
                fenceStallNanoseconds
            )
        }
        if sparseSpanRecorder != nil {
            // Reset on the frame that carries a new sequence number, union on every
            // frame after it: together those bracket exactly one producer update.
            if pendingRedrawSequence != nil { pendingEngineDamage = .none }
            pendingEngineDamage.formUnion(damage)
        }
        if let pendingRedrawSequence {
            publishedRedrawSequence = pendingRedrawSequence
            self.pendingRedrawSequence = nil
        }
        // Ordered so the scan is skipped once the block is running: after start
        // there is nothing on this path a scan could still decide, and the
        // publish path sees every parsed frame, not just the drawn ones.
        guard startNanoseconds == nil else { return }
        // Only the rows this frame changed can open a block. A plan carries the
        // whole viewport, and a finished block leaves its start marker standing
        // on the screen -- so scanning the whole plan let an unrelated frame
        // (the harness echoing the next block's command) re-detect the previous
        // block's marker and open a block no producer had started.
        guard scanMarkers(plan, damage: damage).containsStartMarker else { return }
        if let measuredController {
            fenceBlockPolicy.beginBlock(at: measuredController.fenceMetrics)
        }
        startNanoseconds = DispatchTime.now().uptimeNanoseconds
        // Seeded here so the first accepted draw has a predecessor to difference
        // against; without it that draw's interval would be unattributable and
        // the CPU series would be one shorter than the draw series.
        let processCPU = processCPUNanoseconds()
        blockStartProcessCPUNanoseconds = processCPU
        lastAcceptedProcessCPUNanoseconds = processCPU
        stateRecorder?.beginBlock()
        writeAcknowledgment(atPath: startAcknowledgmentPath)
    }

    /// Ends whatever block is open when the harness deletes that block's
    /// artifacts, which is the only new-block signal a reused app receives.
    ///
    /// Not gated on `completed`: a block that ends *without* a final draw would
    /// otherwise strand its start timestamp and sequence sets into the next
    /// block, which then fails too. Reached only in the persistent mode that
    /// reuses one app across blocks -- a fresh-app run measures a single block
    /// and never re-arms, so it pays nothing for this.
    ///
    /// Ungating it from `completed` is what puts these two probes on every
    /// published frame of an open block, which is the PTY-output path -- so they
    /// use `access` over a pre-encoded path rather than
    /// `FileManager.fileExists`, which would build an `NSString` and take the
    /// slower `stat` route once per frame for the same answer.
    private func reopenCompletedBlockIfRequested() {
        guard reusesBlocks, completed || startNanoseconds != nil,
              isAbsent(resultPathBytes), isAbsent(startAcknowledgmentPathBytes)
        else { return }
        startNanoseconds = nil
        completed = false
        localizedSequences = []
        observedSettlingDraw = false
        localizedDrawDurations = []
        localizedDirtyRowCounts = []
        pendingPlanNanoseconds = 0
        pendingPlanFrameCount = 0
        acceptedPlanDurations = []
        acceptedPlanFrameCount = 0
        pendingFenceStallNanoseconds = 0
        pendingFenceStallCount = 0
        acceptedFenceStallDurations = []
        acceptedFenceStallCount = 0
        acceptedFenceStallMaxNanoseconds = 0
        blockStartProcessCPUNanoseconds = nil
        lastAcceptedProcessCPUNanoseconds = nil
        acceptedProcessCPUDurations = []
        pendingRedrawSequence = nil
        publishedRedrawSequence = nil
        redrawSequences = []
        sparseSpanRecorder?.reset()
        pendingEngineDamage = .none
    }

    /// Associates benchmark-only OSC title metadata with the next published full-screen frame.
    func observeTitle(_ title: String) {
        let prefix = "DANTERM-BENCH-REDRAW-"
        guard title.hasPrefix(prefix), let sequence = Int(title.dropFirst(prefix.count)) else {
            return
        }
        pendingRedrawSequence = sequence
    }

    /// Tells the view to retry when AppKit merged a published full redraw with older partial damage.
    /// Excludes the sparse-span workloads for the same reason it excludes
    /// incremental-mixed: their stimulus is partial damage by construction, and
    /// forcing a full redraw would replace the exact topology they measure.
    var needsPublishedRedraw: Bool {
        publishedRedrawSequence != nil
            && profilesIncrementalMixedDamage == false
            && sparseSpanRecorder == nil
    }

    /// Acknowledges the consumed frame only after its synchronous drawing work returns.
    func observeCompletedDraw(
        _ plan: RenderFramePlan,
        dirtyRect: CGRect,
        metrics: TerminalRenderMetrics,
        drawDurationNanoseconds: UInt64,
        damage: TerminalDamage,
        usedDirtyRectFallback: Bool
    ) {
        // Counted before every gate below, because a profile contains every draw
        // the app performed -- not only the ones a measured block accepts. In
        // loop mode no block ever opens, so a count taken after these guards
        // would stay at zero for the whole profiling window.
        if let activityPath {
            observedDrawCount += 1
            observeDamageTopology(
                damage,
                rowCount: plan.rows,
                usedDirtyRectFallback: usedDirtyRectFallback
            )
            publishActivity(atPath: activityPath)
        }
        guard completed == false, let startNanoseconds else { return }
        stateRecorder?.observeDrawState()
        let markers = scanMarkers(plan)
        if markers.containsStartMarker, let startDrawAcknowledgmentPath {
            writeAcknowledgment(atPath: startDrawAcknowledgmentPath)
        }
        if markers.containsLocalizedReady,
           let readyDrawAcknowledgmentPath
        {
            observedSettlingDraw = true
            writeAcknowledgment(atPath: readyDrawAcknowledgmentPath)
        }
        if let sequence = markers.localizedSequence,
           localizedSequences.insert(sequence).inserted
        {
            localizedDrawDurations.append(drawDurationNanoseconds)
            acceptPendingWork()
            localizedDirtyRowCounts.append(
                dirtyRowCount(for: dirtyRect, metrics: metrics, rowCount: plan.rows)
            )
            if let localizedDrawAcknowledgmentPrefix {
                writeAcknowledgment(
                    atPath: "\(localizedDrawAcknowledgmentPrefix)-\(String(format: "%06d", sequence))"
                )
            }
        }
        let redrawDirtyRowCount = dirtyRowCount(
            for: dirtyRect,
            metrics: metrics,
            rowCount: plan.rows
        )
        // Two selection rules, one per stimulus family. A dirty-rectangle rule
        // cannot serve the sparse-span workloads at all: the rectangle a compound
        // clip draws under is the union of its spans, so 2 spans and 17 spans
        // present the same bounding row count. Those workloads select on the
        // engine damage that produced the clip instead, and the topology check is
        // what makes an off-topology draw fail to acknowledge rather than enter
        // the series.
        //
        // The recorder is consulted only for a sequence this block has not
        // accepted yet, because recording is what an accepted draw is: a record
        // written for any other draw would leave the topology series longer than
        // the timing series they must be read against.
        var acceptsRedrawDraw = publishedRedrawSequence
            .map { redrawSequences.contains($0) == false } ?? false
        if acceptsRedrawDraw {
            if sparseSpanRecorder != nil {
                acceptsRedrawDraw = sparseSpanRecorder?.recordDrawIfTopologyMatches(
                    engineDamage: pendingEngineDamage,
                    clipDamage: damage,
                    rowCount: plan.rows,
                    usedDirtyRectFallback: usedDirtyRectFallback
                ) == true
            } else {
                acceptsRedrawDraw =
                    redrawDirtyRowCount == (profilesIncrementalMixedDamage ? 6 : plan.rows)
            }
        }
        if let sequence = publishedRedrawSequence,
           acceptsRedrawDraw,
           redrawSequences.insert(sequence).inserted
        {
            publishedRedrawSequence = nil
            pendingEngineDamage = .none
            localizedDrawDurations.append(drawDurationNanoseconds)
            acceptPendingWork()
            localizedDirtyRowCounts.append(redrawDirtyRowCount)
            if let localizedDrawAcknowledgmentPrefix {
                writeAcknowledgment(
                    atPath: "\(localizedDrawAcknowledgmentPrefix)-\(String(format: "%06d", sequence))"
                )
            }
        }
        guard markers.containsCompletionMarker, markers.containsExpectedFinalState else { return }
        // A settling workload draws its settling frame before anything it
        // measures, so a completion that arrives first cannot belong to this
        // block: it is the previous block's completion text still on the
        // screen. Accepting it would close the block before the producer's
        // first write and strand every later acknowledgment.
        guard requiresSettlingDraw == false || observedSettlingDraw else { return }
        completed = true
        let elapsed = DispatchTime.now().uptimeNanoseconds - startNanoseconds
        var object: [String: Any] = [
            "clock": "dispatch-uptime-nanoseconds",
            "elapsedNanoseconds": elapsed,
            "event": "final-draw-completed",
            "startMarker": startMarker,
            "expectedFinalState": expectedFinalState,
            "machineStateSamples": stateRecorder?.finishBlock() ?? [],
        ]
        // Outside the draw-series guard, unlike every other auxiliary series here: a
        // workload measured as one replay (`scrollback-stream`) localizes no per-draw
        // durations at all, and that is the workload whose sustained output makes this
        // fence wait worth measuring in the first place. Pending is added to accepted
        // for the same reason -- with no accepted draws there is nothing to promote
        // pending into, so reading accepted alone would report zero for the flood.
        //
        // Beside the draw numbers, never folded in: this is main-thread time the draw
        // timer does not span, spent waiting on the pane's host queue rather than doing
        // work of its own. Folding it in would redefine the metric the decision
        // thresholds are calibrated for.
        object["cumulativeFenceStallNanoseconds"] =
            acceptedFenceStallDurations.reduce(0, +) + pendingFenceStallNanoseconds
        object["fenceStallFrameCount"] = acceptedFenceStallCount + pendingFenceStallCount
        object["maxFenceStallNanoseconds"] = acceptedFenceStallMaxNanoseconds
        object["fenceStallDurationsNanoseconds"] = acceptedFenceStallDurations
        if let measuredController,
           let fenceMetrics = fenceBlockPolicy.completeBlock(
               at: measuredController.fenceMetrics
           )
        {
            object["fenceMetrics"] = fenceMetricsArtifact(fenceMetrics)
        }
        if localizedDrawDurations.isEmpty == false {
            object["cumulativeDrawNanoseconds"] = localizedDrawDurations.reduce(0, +)
            object["drawCount"] = localizedDrawDurations.count
            object["drawSequences"] = redrawSequences.sorted()
            object["drawDurationsNanoseconds"] = localizedDrawDurations
            object["dirtyRowCounts"] = localizedDirtyRowCounts
            // Reported beside the draw numbers, never folded into them: planning
            // is outside the draw timer, so adding it would redefine the metric
            // the decision thresholds are calibrated for.
            object["cumulativePlanNanoseconds"] = acceptedPlanDurations.reduce(0, +)
            object["planCount"] = acceptedPlanDurations.count
            object["planFrameCount"] = acceptedPlanFrameCount
            object["planDurationsNanoseconds"] = acceptedPlanDurations
            // Also beside, never folded in, and for a second reason: this is CPU
            // consumed across all threads, a different quantity from the elapsed
            // main-thread time the draw thresholds are calibrated for. Folding it
            // in would double-count the draw itself.
            object["cumulativeProcessCPUNanoseconds"] = acceptedProcessCPUDurations.reduce(0, +)
            object["processCPUCount"] = acceptedProcessCPUDurations.count
            object["processCPUDurationsNanoseconds"] = acceptedProcessCPUDurations
            // The block's own CPU span, independent of the per-interval series, so
            // a reader can tell whether the intervals account for the whole block
            // or whether draws were dropped between them.
            if let blockStartProcessCPUNanoseconds,
               let lastAcceptedProcessCPUNanoseconds,
               lastAcceptedProcessCPUNanoseconds >= blockStartProcessCPUNanoseconds
            {
                object["blockProcessCPUNanoseconds"] =
                    lastAcceptedProcessCPUNanoseconds - blockStartProcessCPUNanoseconds
            }
            // Present only for the sparse-span workloads, and carrying the same
            // accepted draws as the timing and CPU series above: their verdicts
            // are unreadable without proof that every measured draw really
            // carried the topology the workload names, while the five existing
            // workloads keep the artifact their frozen rules were calibrated on.
            if let sparseSpanRecorder {
                object["sparseSpanTopology"] = sparseSpanRecorder.artifact()
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: resultPath), options: .atomic)
        } catch {
            print("[benchmark] Failed to write final-draw result: \(error)")
        }
    }

    private func fenceMetricsArtifact(
        _ metrics: TerminalPaneFenceMetrics
    ) -> [String: Any] {
        func measurement(
            _ value: TerminalPaneFenceMeasurement
        ) -> [String: Any] {
            [
                "waitNanoseconds": value.waitNanoseconds,
                "count": value.count,
            ]
        }

        return [
            "clock": "dispatch-uptime-nanoseconds",
            "totalWaitNanoseconds": metrics.total.waitNanoseconds,
            "totalCount": metrics.total.count,
            "hostEntryCount": metrics.hostEntryCount,
            "kinds": [
                "delivery": measurement(metrics.delivery),
                "checkpoint": measurement(metrics.checkpoint),
                "teardown": measurement(metrics.teardown),
                "initialization": measurement(metrics.initialization),
                "diagnostic": measurement(metrics.diagnostic),
            ],
        ]
    }

    /// Republishes the lifetime counters, at most every 100 ms, so a profiling
    /// window can be converted into a draw count.
    ///
    /// Takes no sample of its own. The foreground/presentation sample it used to
    /// take here inherited this method's callers, one of which is the draw path
    /// -- which made the coverage rate `min(draw rate, 10/s)` and left the
    /// attributability claim resting on observations that existed only where the
    /// app was busy. `startPresentationSampling` owns that sample now.
    ///
    /// Each snapshot carries its own clock reading rather than relying on a fixed
    /// publish cadence: the reader differences two snapshots' (count, clock)
    /// pairs, so the interval it reports is exactly the one the two snapshots
    /// span and the cadence costs it no accuracy. It only has to be short
    /// relative to a profiling run, which is seconds.
    ///
    /// Called from `observeCompletedDraw` after the draw timer has already
    /// stopped, alongside the acknowledgment writes, so it is outside every
    /// measured bracket -- and it is reached only when a profiling run supplied
    /// a path, so decision blocks pay one nil check per draw and nothing else.
    private func publishActivity(atPath path: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastActivityWriteNanoseconds >= 100_000_000 else { return }
        lastActivityWriteNanoseconds = now
        var object: [String: Any] = [
            "schemaVersion": 2,
            "clock": "dispatch-uptime-nanoseconds",
            "uptimeNanoseconds": now,
            "drawCount": observedDrawCount,
            "planFrameCount": observedPlanFrameCount,
            "damageTopology": [
                "sampleCount": observedDamageTopologySampleCount,
                "jointHistogram": topologyHistogramArtifact(
                    observedDamageTopologyHistogram
                ),
                "damagedRowCountHistogram": histogramArtifact(
                    observedDamagedRowCountHistogram
                ),
                "maximalContiguousSpanCountHistogram": histogramArtifact(
                    observedContiguousSpanCountHistogram
                ),
                "fullDamageCount": observedFullDamageCount,
                "dirtyRectFallbackCount": observedDirtyRectFallbackCount,
            ],
        ]
        // Present only when something sampled it. An absent key says "not
        // measured", which is the one thing all-zero counters could not say --
        // and a bounded capture must reject an interval it cannot prove was
        // attributable rather than read silence as a clean run.
        if stateRecorder != nil {
            object["presentationCoverage"] = presentationCoverage.artifact()
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else { return }
        // Atomic because a reader snapshots this file while draws continue; a
        // torn read would be indistinguishable from a real counter value.
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Records the exact post-coalescing damage topology submitted to Core Graphics.
    private func observeDamageTopology(
        _ damage: TerminalDamage,
        rowCount: Int,
        usedDirtyRectFallback: Bool
    ) {
        let damagedRowCount = damage.isFull ? rowCount : damage.rows.count
        let spanCount = damage.isFull
            ? (rowCount > 0 ? 1 : 0)
            : terminalDamageMaximalContiguousSpanCount(damage.rows)
        observedDamageTopologySampleCount += 1
        let topologyKey = DamageTopologyKey(
            damagedRowCount: damagedRowCount,
            spanCount: spanCount,
            isFull: damage.isFull,
            usedDirtyRectFallback: usedDirtyRectFallback
        )
        observedDamageTopologyHistogram[topologyKey, default: 0] += 1
        observedDamagedRowCountHistogram[damagedRowCount, default: 0] += 1
        observedContiguousSpanCountHistogram[spanCount, default: 0] += 1
        if damage.isFull { observedFullDamageCount += 1 }
        if usedDirtyRectFallback { observedDirtyRectFallbackCount += 1 }
    }

    private func histogramArtifact(_ histogram: [Int: Int]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: histogram.map { (String($0.key), $0.value) })
    }

    private func topologyHistogramArtifact(
        _ histogram: [DamageTopologyKey: Int]
    ) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: histogram.map { key, count in
            let label = [
                "rows=\(key.damagedRowCount)",
                "spans=\(key.spanCount)",
                "full=\(key.isFull)",
                "dirtyRectFallback=\(key.usedDirtyRectFallback)",
            ].joined(separator: ",")
            return (label, count)
        })
    }

    /// Reports whether one pre-encoded path is absent, at the cost of a single
    /// syscall and no allocation.
    private func isAbsent(_ path: [CChar]) -> Bool {
        path.withUnsafeBufferPointer { access($0.baseAddress!, F_OK) != 0 }
    }

    /// Creates the empty file the producer is blocking on, as cheaply as the
    /// filesystem allows.
    ///
    /// `FileManager.createFile` performs a full atomic write -- protected
    /// temporary file, then `rename`, plus a `URL` construction and an `lstat`
    /// -- which made it the largest remaining piece of the observer's
    /// main-thread cost once marker scanning stopped dominating. These files are
    /// zero-byte existence flags, so there is no content for atomicity to
    /// protect and a bare create is equivalent.
    private func writeAcknowledgment(atPath path: String) {
        let descriptor = path.withCString {
            open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        guard descriptor >= 0 else { return }
        close(descriptor)
    }

    /// Attributes the work done since the previous accepted draw to this one:
    /// planning, and whole-process CPU.
    ///
    /// Called from every site that appends a draw duration, so both series stay
    /// index-aligned with `drawDurations` and all three normalize by the same
    /// accepted-draw count.
    ///
    /// The CPU delta covers the whole interval between two accepted draws, so it
    /// charges this draw with everything the process did in it -- this draw's
    /// synchronous work, the *previous* draw's asynchronous display-list replay,
    /// parsing, planning, and the observer itself. That is deliberate: replay is
    /// the cost being hunted and it does not finish inside the draw that queued
    /// it, so any bracket narrow enough to exclude the neighbours would also
    /// exclude the thing worth measuring. It makes the series an interval series,
    /// not a per-draw one -- meaningful in aggregate over a block, not for a
    /// single index.
    private func acceptPendingWork() {
        acceptedPlanDurations.append(pendingPlanNanoseconds)
        acceptedPlanFrameCount += pendingPlanFrameCount
        pendingPlanNanoseconds = 0
        pendingPlanFrameCount = 0
        acceptedFenceStallDurations.append(pendingFenceStallNanoseconds)
        acceptedFenceStallCount += pendingFenceStallCount
        pendingFenceStallNanoseconds = 0
        pendingFenceStallCount = 0
        let processCPU = processCPUNanoseconds()
        if let previous = lastAcceptedProcessCPUNanoseconds, processCPU >= previous {
            acceptedProcessCPUDurations.append(processCPU - previous)
        }
        lastAcceptedProcessCPUNanoseconds = processCPU
    }

    /// Reads CPU time consumed by this process, summed across every thread.
    ///
    /// `TASK_ABSOLUTETIME_INFO` rather than `getrusage`: it reports the task's
    /// own absolute-time counters, which is what makes threads other than the
    /// caller's countable. Returns 0 on failure, which the caller's monotonicity
    /// guard turns into a dropped sample rather than a bogus one.
    private func processCPUNanoseconds() -> UInt64 {
        var info = task_absolutetime_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_absolutetime_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_ABSOLUTETIME_INFO), rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        let ticks = info.total_user &+ info.total_system
        return Self.machTicksToNanoseconds(ticks)
    }

    /// Converts mach absolute ticks to nanoseconds using the timebase read once
    /// per process, because `mach_timebase_info` is a syscall and this runs per
    /// accepted draw.
    private static let machTimebase: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
            return mach_timebase_info_data_t(numer: 1, denom: 1)
        }
        return timebase
    }()

    private static func machTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(machTimebase.numer) / UInt64(machTimebase.denom)
    }

    /// Finds every marker this frame carries in one pass over the plan's runs.
    ///
    /// The whole plan is handed across in one concrete call so the traversal
    /// stays inside the scanner's module, where it specializes. Plan order is
    /// used as-is because `FramePlanner` emits runs row-major and
    /// `clipFramePlan` only filters, so the sort this used to perform could
    /// never reorder anything.
    private func scanMarkers(_ plan: RenderFramePlan) -> TerminalBenchmarkMarkerScan {
        markerScanner.scan(plan)
    }

    /// Scans only what this frame changed, so a marker left standing by an
    /// earlier block cannot answer for the current one.
    private func scanMarkers(
        _ plan: RenderFramePlan,
        damage: TerminalDamage
    ) -> TerminalBenchmarkMarkerScan {
        markerScanner.scan(plan, limitedToRows: damage.isFull ? nil : damage.rows)
    }

    private func dirtyRowCount(
        for rect: CGRect,
        metrics: TerminalRenderMetrics,
        rowCount: Int
    ) -> Int {
        guard rowCount > 0, rect.isEmpty == false else { return 0 }
        let first = min(rowCount, max(0, Int(floor(rect.minY / metrics.cellSize.height))))
        let end = min(rowCount, max(0, Int(ceil(rect.maxY / metrics.cellSize.height))))
        return max(0, end - first)
    }
}
#endif
