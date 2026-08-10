// Headless replay helper used by the opt-in terminal viability harness to compare
// live pane text with the same neutral recording replayed through TerminalCore.
import Foundation
import TerminalCore
import TerminalCoreRecording

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: terminal-recording-replay <screen|history> <recording.json>\n".utf8))
    exit(2)
}

let mode = CommandLine.arguments[1]
let recordingURL = URL(fileURLWithPath: CommandLine.arguments[2])

do {
    let data = try Data(contentsOf: recordingURL)
    let recording = try JSONDecoder().decode(NeutralTerminalRecording.self, from: data)
    try recording.provenance.validate()
    let terminal = try recording.replay()
    let text: String
    switch mode {
    case "screen":
        text = terminal.screenText
    case "history":
        text = terminal.fullHistoryText
    default:
        throw CocoaError(.fileReadCorruptFile, userInfo: [
            NSLocalizedDescriptionKey: "mode must be screen or history",
        ])
    }
    FileHandle.standardOutput.write(Data(text.utf8))
} catch {
    FileHandle.standardError.write(Data("terminal-recording-replay: \(error)\n".utf8))
    exit(1)
}
