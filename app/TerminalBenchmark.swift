// Env-gated app-side timing for terminal benchmarks. It observes published Swift
// frames before display and acknowledges only the exact frame consumed by draw.
import Foundation
import TerminalRenderPlanning

#if DANTERM_TERMINAL_BENCHMARK
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
