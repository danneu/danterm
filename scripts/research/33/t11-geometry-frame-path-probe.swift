// Research doc 33, task T11: plans one canonical frame and reports geometry projection work.
import Foundation

guard let terminal = Terminal(columns: 179, rows: 66) else {
    fatalError("canonical geometry must be valid")
}

_ = planFrame(
    for: terminal,
    presentation: RenderPresentation(theme: .dark, isCursorVisible: true, cursorShape: .block)
)

let report = [
    "planFrames": 1,
    "presentedRowGeometryCalls": t11Counters.presentedRowGeometryCalls,
    "geometryRowAllocations": t11Counters.geometryRowAllocations,
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0A]))
