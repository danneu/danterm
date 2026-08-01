// Corpus-wide totality, determinism, immutability, and canonical-form proofs.
import Foundation
import Testing

import TerminalCore
import TerminalCoreRecording
@testable import TerminalRenderPlanning

struct RenderCorpusPlanningTests {
    @Test("Every neutral event can overlay logical damage into the next complete plan")
    func everyNeutralEventOverlaysDamage() throws {
        // Intent: prove each event's logical damage covers every changed render row, both
        //   for a consumer overlaying clipped output and for the planner that reuses the
        //   runs of undamaged rows.
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
        let initialPresentation = RenderPresentation(
            theme: .dark,
            isCursorVisible: terminal.presentation.isCursorVisible,
            cursorShape: terminal.presentation.cursorShape
        )
        var retainedPlan = planFrame(for: terminal, presentation: initialPresentation)
        // Second consumer of the same event stream: where `retainedPlan` proves damage
        // is sufficient to overlay a clipped plan, this proves row reuse never needs
        // more than damage either -- the planner keeps its own retained rows and must
        // still land on the from-scratch plan after every event.
        var reusingPlanner = PaneFramePlanner()
        _ = reusingPlanner.planFrame(
            for: terminal,
            presentation: initialPresentation,
            damage: .full
        )

        for (eventIndex, event) in recording.events.enumerated() {
            apply(event, to: &terminal, interactionState: &interactionState)
            let damage = terminal.drainDamage()
            let presentation = RenderPresentation(
                theme: .dark,
                isCursorVisible: terminal.presentation.isCursorVisible,
                cursorShape: terminal.presentation.cursorShape
            )
            let completePlan = planFrame(for: terminal, presentation: presentation)
            let damageDescription = damage.isFull
                ? "full"
                : String(describing: damage.rows.sorted())
            let context = "Fixture: \(fixtureName), event: \(eventIndex), "
                + "damage: \(damageDescription)"

            let clippedPlan = clipFramePlan(completePlan, to: damage)
            retainedPlan = overlay(clippedPlan, damage: damage, on: retainedPlan)
            if retainedPlan != completePlan {
                Issue.record(Comment(rawValue: context))
                retainedPlan = completePlan
            }

            let reusedPlan = reusingPlanner.planFrame(
                for: terminal,
                presentation: presentation,
                damage: damage
            )
            if reusedPlan != completePlan {
                Issue.record(Comment(rawValue: "Row reuse diverged -- \(context)"))
                reusingPlanner = PaneFramePlanner()
                _ = reusingPlanner.planFrame(
                    for: terminal,
                    presentation: presentation,
                    damage: .full
                )
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
        // Each run array is a hoisted local with fully spelled-out closure signatures.
        // Written as five inline `flatMap { row in cond ? a.filter { $0.row == row } : ... }`
        // arguments, this one function cost ~1s of typecheck time: the solver had to infer
        // both closures' parameter and result types through a ternary in each of five
        // arguments at once. Keep the annotations.
        let backgroundRuns: [RenderBackgroundRun] = (0..<retained.rows).flatMap { (row: Int) -> [RenderBackgroundRun] in
            let source: [RenderBackgroundRun] = rows.contains(row) ? clipped.backgroundRuns : retained.backgroundRuns
            return source.filter { (run: RenderBackgroundRun) -> Bool in run.row == row }
        }
        let selectionRuns: [RenderSelectionRun] = (0..<retained.rows).flatMap { (row: Int) -> [RenderSelectionRun] in
            let source: [RenderSelectionRun] = rows.contains(row) ? clipped.selectionRuns : retained.selectionRuns
            return source.filter { (run: RenderSelectionRun) -> Bool in run.row == row }
        }
        let searchMatchRuns: [RenderSelectionRun] = (0..<retained.rows).flatMap { (row: Int) -> [RenderSelectionRun] in
            let source: [RenderSelectionRun] = rows.contains(row) ? clipped.searchMatchRuns : retained.searchMatchRuns
            return source.filter { (run: RenderSelectionRun) -> Bool in run.row == row }
        }
        let textRuns: [RenderTextRun] = (0..<retained.rows).flatMap { (row: Int) -> [RenderTextRun] in
            let source: [RenderTextRun] = rows.contains(row) ? clipped.textRuns : retained.textRuns
            return source.filter { (run: RenderTextRun) -> Bool in run.row == row }
        }
        let decorationRuns: [RenderDecorationRun] = (0..<retained.rows).flatMap { (row: Int) -> [RenderDecorationRun] in
            let source: [RenderDecorationRun] = rows.contains(row) ? clipped.decorationRuns : retained.decorationRuns
            return source.filter { (run: RenderDecorationRun) -> Bool in run.row == row }
        }
        let retainedCursor: RenderCursor? = retained.cursor.flatMap { cursor in
            rows.contains(cursor.row) ? nil : cursor
        }
        let cursor: RenderCursor? = clipped.cursor ?? retainedCursor
        return RenderFramePlan(
            columns: retained.columns,
            rows: retained.rows,
            defaultBackground: retained.defaultBackground,
            selectionBackground: retained.selectionBackground,
            searchMatchBackground: retained.searchMatchBackground,
            backgroundRuns: backgroundRuns,
            selectionRuns: selectionRuns,
            searchMatchRuns: searchMatchRuns,
            textRuns: textRuns,
            decorationRuns: decorationRuns,
            cursor: cursor
        )
    }
}
