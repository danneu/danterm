// Env-gated app-side geometry convergence and timing for terminal benchmarks.
// It resizes the window to a requested grid, then observes the exact Swift frame
// consumed by draw without adding hooks to TerminalCore.
import Cocoa
import TerminalBenchmarkMarkers
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

    private let startMarker: String
    private let completionMarker: String
    private let expectedFinalState: String
    private let startAcknowledgmentPath: String
    private let startDrawAcknowledgmentPath: String?
    private let readyDrawAcknowledgmentPath: String?
    private let localizedDrawAcknowledgmentPrefix: String?
    private let resultPath: String
    private let profilesIncrementalMixedDamage: Bool
    private var startNanoseconds: UInt64?
    private var completed = false
    private var localizedSequences = Set<Int>()
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
    private var pendingRedrawSequence: Int?
    private var publishedRedrawSequence: Int?
    private var redrawSequences = Set<Int>()
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
    }

    /// Records the app-side observation before a newly parsed frame becomes drawable.
    ///
    /// `planDurationNanoseconds` is the cost of the `planFrame` call that produced
    /// this plan. It is collected here because planning happens on the PTY-output
    /// path, outside the draw timer that produces `drawDurationNanoseconds`.
    func observePublishedFrame(_ plan: RenderFramePlan, planDurationNanoseconds: UInt64 = 0) {
        reopenCompletedBlockIfRequested()
        if startNanoseconds != nil, completed == false {
            pendingPlanNanoseconds += planDurationNanoseconds
            pendingPlanFrameCount += 1
        }
        if let pendingRedrawSequence {
            publishedRedrawSequence = pendingRedrawSequence
            self.pendingRedrawSequence = nil
        }
        // Ordered so the scan is skipped once the block is running: after start
        // there is nothing on this path a scan could still decide, and the
        // publish path sees every parsed frame, not just the drawn ones.
        guard startNanoseconds == nil else { return }
        guard scanMarkers(plan).containsStartMarker else { return }
        startNanoseconds = DispatchTime.now().uptimeNanoseconds
        stateRecorder?.beginBlock()
        writeAcknowledgment(atPath: startAcknowledgmentPath)
    }

    private func reopenCompletedBlockIfRequested() {
        guard completed,
              FileManager.default.fileExists(atPath: resultPath) == false,
              FileManager.default.fileExists(atPath: startAcknowledgmentPath) == false
        else { return }
        startNanoseconds = nil
        completed = false
        localizedSequences = []
        localizedDrawDurations = []
        localizedDirtyRowCounts = []
        pendingPlanNanoseconds = 0
        pendingPlanFrameCount = 0
        acceptedPlanDurations = []
        acceptedPlanFrameCount = 0
        pendingRedrawSequence = nil
        publishedRedrawSequence = nil
        redrawSequences = []
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
    var needsPublishedRedraw: Bool {
        publishedRedrawSequence != nil && profilesIncrementalMixedDamage == false
    }

    /// Acknowledges the consumed frame only after its synchronous drawing work returns.
    func observeCompletedDraw(
        _ plan: RenderFramePlan,
        dirtyRect: CGRect,
        metrics: TerminalRenderMetrics,
        drawDurationNanoseconds: UInt64
    ) {
        guard completed == false, let startNanoseconds else { return }
        stateRecorder?.observeDrawState()
        let markers = scanMarkers(plan)
        if markers.containsStartMarker, let startDrawAcknowledgmentPath {
            writeAcknowledgment(atPath: startDrawAcknowledgmentPath)
        }
        if markers.containsLocalizedReady,
           let readyDrawAcknowledgmentPath
        {
            writeAcknowledgment(atPath: readyDrawAcknowledgmentPath)
        }
        if let sequence = markers.localizedSequence,
           localizedSequences.insert(sequence).inserted
        {
            localizedDrawDurations.append(drawDurationNanoseconds)
            acceptPendingPlan()
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
        if let sequence = publishedRedrawSequence,
           redrawDirtyRowCount == (profilesIncrementalMixedDamage ? 6 : plan.rows),
           redrawSequences.insert(sequence).inserted
        {
            publishedRedrawSequence = nil
            localizedDrawDurations.append(drawDurationNanoseconds)
            acceptPendingPlan()
            localizedDirtyRowCounts.append(redrawDirtyRowCount)
            if let localizedDrawAcknowledgmentPrefix {
                writeAcknowledgment(
                    atPath: "\(localizedDrawAcknowledgmentPrefix)-\(String(format: "%06d", sequence))"
                )
            }
        }
        guard markers.containsCompletionMarker, markers.containsExpectedFinalState else { return }
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
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: resultPath), options: .atomic)
        } catch {
            print("[benchmark] Failed to write final-draw result: \(error)")
        }
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

    /// Attributes the planning done since the previous accepted draw to this one.
    ///
    /// Called from every site that appends a draw duration, so `planDurations`
    /// stays index-aligned with `drawDurations` and both normalize by the same
    /// accepted-draw count.
    private func acceptPendingPlan() {
        acceptedPlanDurations.append(pendingPlanNanoseconds)
        acceptedPlanFrameCount += pendingPlanFrameCount
        pendingPlanNanoseconds = 0
        pendingPlanFrameCount = 0
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
