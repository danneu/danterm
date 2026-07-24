// Corpus-wide totality, determinism, immutability, and canonical-form proofs.
import Foundation
import Testing

import TerminalCore
import TerminalCoreRecording
@testable import TerminalRenderPlanning

struct RenderCorpusPlanningTests {
    @Test("Every neutral event can overlay logical damage into the next complete plan")
    func everyNeutralEventOverlaysDamage() throws {
        // Intent: prove each event's logical damage covers every changed render row.
        // Why it exists: producer examples cannot prove corpus-wide sufficiency across
        //   parser actions, alternate screens, resize, reflow, and viewport navigation.
        // Scenario: a retained pane applies only each event's damaged rows and must end
        //   with exactly the same plan as a fresh complete redraw.
        for url in try fixtureURLs() {
            let recording = try JSONDecoder().decode(
                NeutralTerminalRecording.self,
                from: Data(contentsOf: url)
            )
            try assertDamageEquivalence(recording, fixtureName: url.lastPathComponent)
        }
    }

    @Test("Every libvterm checkpoint produces an equal canonical plan without mutation")
    func everyLibvtermCheckpoint() throws {
        let root = fixtureRoot.appending(path: "libvterm", directoryHint: .isDirectory)
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
                let presentation = RenderPresentation(
                    theme: .dark,
                    isCursorVisible: terminal.presentation.isCursorVisible,
                    cursorShape: terminal.presentation.cursorShape
                )
                let first = planFrame(for: terminal, presentation: presentation)
                let second = planFrame(for: terminal, presentation: presentation)
                #expect(first == second, "Fixture: \(url.lastPathComponent)")
                #expect(terminal == before, "Fixture: \(url.lastPathComponent)")
                assertCanonical(first)
            }
        }
        #expect(checkpointCount > 0)
    }

    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Tests/TerminalCoreTests/Fixtures", directoryHint: .isDirectory)
    }

    private func fixtureURLs() throws -> [URL] {
        try ["danterm", "libvterm"].flatMap { directory in
            try FileManager.default.contentsOfDirectory(
                at: fixtureRoot.appending(path: directory, directoryHint: .isDirectory),
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }
        }
        .sorted { $0.path < $1.path }
    }

    private func assertDamageEquivalence(
        _ recording: NeutralTerminalRecording,
        fixtureName: String
    ) throws {
        var terminal = try #require(Terminal(
            columns: recording.initial.columns,
            rows: recording.initial.rows
        ))
        var interactionState = TerminalInteractionState()
        _ = terminal.drainDamage()
        var retainedPlan = planFrame(
            for: terminal,
            presentation: .init(
                theme: .dark,
                isCursorVisible: terminal.presentation.isCursorVisible,
                cursorShape: terminal.presentation.cursorShape
            )
        )

        for (eventIndex, event) in recording.events.enumerated() {
            apply(event, to: &terminal, interactionState: &interactionState)
            let damage = terminal.drainDamage()
            let completePlan = planFrame(
                for: terminal,
                presentation: .init(
                    theme: .dark,
                    isCursorVisible: terminal.presentation.isCursorVisible,
                    cursorShape: terminal.presentation.cursorShape
                )
            )
            let clippedPlan = clipFramePlan(completePlan, to: damage)
            retainedPlan = overlay(clippedPlan, damage: damage, on: retainedPlan)
            if retainedPlan != completePlan {
                let damageDescription = damage.isFull
                    ? "full"
                    : String(describing: damage.rows.sorted())
                let message = "Fixture: \(fixtureName), event: \(eventIndex), "
                    + "damage: \(damageDescription)"
                Issue.record(Comment(rawValue: message))
                retainedPlan = completePlan
            }
        }
    }

    private func apply(
        _ event: NeutralTerminalRecordingEvent,
        to terminal: inout Terminal,
        interactionState: inout TerminalInteractionState
    ) {
        switch event {
        case .feed(let bytes):
            terminal.feed(bytes)
            _ = terminal.drainReplyBytes()
        case .mouse(let mouse):
            _ = applyNeutralTerminalMouse(
                mouse,
                terminal: &terminal,
                interactionState: &interactionState
            )
        case .resize(let columns, let rows):
            terminal.resize(columns: columns, rows: rows)
        case .viewport(let navigation):
            switch navigation {
            case .byRows(let rows): terminal.scroll(byRows: rows)
            case .toTopRow(let row): terminal.scroll(toTopRow: row)
            case .toBottom: terminal.scrollToBottom()
            }
        case .input, .paste, .focus, .checkpoint:
            break
        }
    }

    private func overlay(
        _ clipped: RenderFramePlan,
        damage: TerminalDamage,
        on retained: RenderFramePlan
    ) -> RenderFramePlan {
        guard damage.isFull == false,
              retained.columns == clipped.columns,
              retained.rows == clipped.rows,
              retained.defaultBackground == clipped.defaultBackground,
              retained.selectionBackground == clipped.selectionBackground,
              retained.searchMatchBackground == clipped.searchMatchBackground
        else {
            return clipped
        }
        let rows = damage.rows
        return RenderFramePlan(
            columns: retained.columns,
            rows: retained.rows,
            defaultBackground: retained.defaultBackground,
            selectionBackground: retained.selectionBackground,
            searchMatchBackground: retained.searchMatchBackground,
            backgroundRuns: (0..<retained.rows).flatMap { row in
                rows.contains(row)
                    ? clipped.backgroundRuns.filter { $0.row == row }
                    : retained.backgroundRuns.filter { $0.row == row }
            },
            selectionRuns: (0..<retained.rows).flatMap { row in
                rows.contains(row)
                    ? clipped.selectionRuns.filter { $0.row == row }
                    : retained.selectionRuns.filter { $0.row == row }
            },
            searchMatchRuns: (0..<retained.rows).flatMap { row in
                rows.contains(row)
                    ? clipped.searchMatchRuns.filter { $0.row == row }
                    : retained.searchMatchRuns.filter { $0.row == row }
            },
            textRuns: (0..<retained.rows).flatMap { row in
                rows.contains(row)
                    ? clipped.textRuns.filter { $0.row == row }
                    : retained.textRuns.filter { $0.row == row }
            },
            decorationRuns: (0..<retained.rows).flatMap { row in
                rows.contains(row)
                    ? clipped.decorationRuns.filter { $0.row == row }
                    : retained.decorationRuns.filter { $0.row == row }
            },
            cursor: clipped.cursor ?? retained.cursor.flatMap { rows.contains($0.row) ? nil : $0 }
        )
    }
}
