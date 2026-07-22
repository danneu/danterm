// Env-gated app-side geometry convergence and timing for terminal benchmarks.
// It resizes the window to a requested grid, then observes the exact Swift frame
// consumed by draw without adding hooks to TerminalCore.
import Cocoa
import TerminalRenderPlanning

#if DANTERM_TERMINAL_BENCHMARK
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
    private let resultPath: String
    private var startNanoseconds: UInt64?
    private var completed = false

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
        self.resultPath = resultPath
    }

    /// Records the app-side observation before a newly parsed frame becomes drawable.
    func observePublishedFrame(_ plan: RenderFramePlan) {
        guard startNanoseconds == nil, frameText(plan).contains(startMarker) else { return }
        startNanoseconds = DispatchTime.now().uptimeNanoseconds
        FileManager.default.createFile(atPath: startAcknowledgmentPath, contents: Data())
    }

    /// Acknowledges the consumed frame only after its synchronous drawing work returns.
    func observeCompletedDraw(_ plan: RenderFramePlan) {
        guard completed == false, let startNanoseconds else { return }
        let text = frameText(plan)
        guard text.contains(completionMarker), text.contains(expectedFinalState) else { return }
        completed = true
        let elapsed = DispatchTime.now().uptimeNanoseconds - startNanoseconds
        let object: [String: Any] = [
            "clock": "dispatch-uptime-nanoseconds",
            "elapsedNanoseconds": elapsed,
            "event": "final-draw-completed",
            "expectedFinalState": expectedFinalState,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: resultPath), options: .atomic)
        } catch {
            print("[benchmark] Failed to write final-draw result: \(error)")
        }
    }

    private func frameText(_ plan: RenderFramePlan) -> String {
        plan.textRuns
            .sorted { ($0.row, $0.startColumn) < ($1.row, $1.startColumn) }
            .map { run in
                run.cells.flatMap(\.scalars).map(String.init).joined()
            }
            .joined(separator: "\n")
    }
}
#endif
