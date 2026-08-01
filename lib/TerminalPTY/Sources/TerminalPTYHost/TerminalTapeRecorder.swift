// Diagnostic recorder for a live pane's exact `Terminal` drive sequence -- every feed
// chunk with its real PTY read boundaries, and every resize -- written as JSON lines
// in the neutral fixture schema, so a corruption seen in a real pane can be replayed
// against a bare `Terminal` in a unit test. This is the instrument that decides
// whether a visual artifact is a `TerminalCore` bug or something downstream of it:
// replay reproduces it (core) or it does not (renderer/app).
//
// It earns a permanent place because reconstructing a stimulus is a standing guess
// about which variable matters, and recording one is not. The OSC 133 stale-width
// investigation exhausted every synthetic stimulus it could think of -- geometry
// sweeps, resizes spliced into bursts -- and each replayed clean; the first recorded
// tape reproduced the artifact row for row and became a fixture. See
// docs/research/24-osc-133-dialect/README.md, the "record its drive sequence before
// theorizing" rule.
//
// Off unless `DANTERM_TAPE_PATH` is set in the app's environment, so a normal pane
// pays one optional check per feed. Its own file so that it stays deletable as a
// unit: this file plus the two `tape?.` call sites in TerminalPTYHost are the whole
// instrument.
//
// Usage: `env DANTERM_TAPE_PATH=/tmp/danterm-tape "$HOME/Applications/DanTerm Dev.app/Contents/MacOS/DanTerm Dev"`,
// then reproduce the artifact. Each pane writes `<path>.<pid>.jsonl`. Convert to a
// fixture by wrapping the events in the schema `TerminalFixture` expects and scrubbing
// any OSC 7 host/user paths out of the captured bytes.
import Foundation

/// Append-only JSONL writer for a single pane's terminal drive sequence.
///
/// Owned by the `TerminalPTYHost` actor and only ever touched from its serial queue,
/// so it needs no locking of its own. Writes eagerly rather than buffering: the whole
/// point is surviving a pane or app that is killed mid-investigation.
final class TerminalTapeRecorder {
    private let handle: FileHandle

    /// Returns a recorder only when `DANTERM_TAPE_PATH` names a creatable file, so the
    /// call sites stay a single optional-chained call with no configuration branch.
    /// Each pane gets its own file suffixed with its PID to keep tapes from interleaving.
    static func fromEnvironment(initialColumns: Int, initialRows: Int) -> TerminalTapeRecorder? {
        guard let base = ProcessInfo.processInfo.environment["DANTERM_TAPE_PATH"] else { return nil }
        let path = "\(base).\(ProcessInfo.processInfo.processIdentifier).jsonl"
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path)
        else { return nil }
        let recorder = TerminalTapeRecorder(handle: handle)
        recorder.write("{\"initial\":{\"columns\":\(initialColumns),\"rows\":\(initialRows)}}")
        return recorder
    }

    private init(handle: FileHandle) {
        self.handle = handle
    }

    func recordFeed(_ bytes: [UInt8]) {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        write("{\"type\":\"feed\",\"hex\":\"\(hex)\"}")
    }

    func recordResize(columns: Int, rows: Int) {
        write("{\"type\":\"resize\",\"columns\":\(columns),\"rows\":\(rows)}")
    }

    private func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }
}
