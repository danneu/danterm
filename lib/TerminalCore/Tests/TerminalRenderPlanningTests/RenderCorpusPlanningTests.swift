// Corpus-wide totality, determinism, immutability, and canonical-form proofs.
import Foundation
import Testing

import TerminalCoreRecording
@testable import TerminalRenderPlanning

struct RenderCorpusPlanningTests {
    @Test("Every libvterm checkpoint produces an equal canonical plan without mutation")
    func everyLibvtermCheckpoint() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Tests/TerminalCoreTests/Fixtures/libvterm", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        try #require(exists)
        try #require(isDirectory.boolValue)

        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(urls.isEmpty == false)

        var checkpointCount = 0
        for url in urls {
            let recording = try JSONDecoder().decode(
                NeutralTerminalRecording.self,
                from: Data(contentsOf: url)
            )
            _ = try recording.replay { eventIndex, terminal in
                guard case .checkpoint = recording.events[eventIndex] else { return }
                checkpointCount += 1
                let before = terminal
                let presentation = RenderPresentation(theme: .dark, isCursorVisible: true)
                let first = planFrame(for: terminal, presentation: presentation)
                let second = planFrame(for: terminal, presentation: presentation)
                #expect(first == second, "Fixture: \(url.lastPathComponent)")
                #expect(terminal == before, "Fixture: \(url.lastPathComponent)")
                assertCanonical(first)
            }
        }
        #expect(checkpointCount > 0)
    }
}
