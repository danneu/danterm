// Research doc 33, task T13: plans one canonical frame and reports style work.
import Foundation

guard var terminal = Terminal(columns: 179, rows: 66) else {
  fatalError("canonical geometry must be valid")
}
terminal.setSelection(
  TerminalTextRange(
    start: TerminalTextPosition(row: 0, column: 0),
    end: TerminalTextPosition(row: 65, column: 179)
  ))

_ = planFrame(
  for: terminal,
  presentation: RenderPresentation(theme: .dark, isCursorVisible: false, cursorShape: .block)
)

let report = [
  "planFrames": 1,
  "viewportCells": 179 * 66,
  "distinctStyleRuns": t13Counters.distinctStyleRuns,
  "resolveCellStyleCalls": t13Counters.resolveCellStyleCalls,
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0A]))
