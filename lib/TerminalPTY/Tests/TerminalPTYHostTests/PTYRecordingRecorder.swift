// Test-support serialization for owner-ordered PTY recordings. Captures are
// written only when the opt-in directory environment variable is present.
import Foundation
import TerminalCoreRecording

/// Encodes a complete neutral session without making recording a product feature.
struct PTYRecordingRecorder {
    let recording: NeutralTerminalRecording

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(recording)
    }

    func writeIfRequested(
        name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard let directory = environment["DANTERM_PTY_RECORDING_DIR"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appending(path: name)
            .appendingPathExtension("json")
        try encoded().write(to: url, options: .atomic)
    }
}
