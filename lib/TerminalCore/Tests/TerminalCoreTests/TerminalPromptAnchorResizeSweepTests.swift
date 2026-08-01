// Deterministic resize injection over live shell-dialect recordings, including byte offsets
// inside authored feed chunks where prompt erase/re-mark timing windows can exist.
import Foundation
import Testing
import TerminalCoreRecording

@testable import TerminalCore

/// Probes prompt anchoring at replay timings the authored resize events did not capture.
struct TerminalPromptAnchorResizeSweepTests {
    @Test("resize injection schedules are deterministic, internal, and self-identifying")
    func scheduleContract() throws {
        // Intent: a seed always selects the same real intra-chunk injection point and
        //   produces a token that can rerun that one case.
        // Why it exists: a randomized sweep without a concrete rerun selector turns a
        //   regression into a search problem, while event-boundary-only injection misses
        //   the erase-to-re-mark window this sweep exists to probe.
        // Scenario: CI reports one seeded dialect replay failure and a developer reruns it.
        let fixture = try loadPromptAnchorSweepFixture(named: "zsh-dialect-width-sweep")

        let first = try promptAnchorResizeInjections(
            fixture: fixture,
            fixtureName: "zsh-dialect-width-sweep",
            seed: 7
        )
        let repeated = try promptAnchorResizeInjections(
            fixture: fixture,
            fixtureName: "zsh-dialect-width-sweep",
            seed: 7
        )

        #expect(first == repeated)
        #expect(first.count == 1)
        for injection in first {
            let bytes = try #require(fixture.events[injection.eventIndex].feedBytes)
            let promptMarkPrefixes = ["A", "N", "P"].map {
                Array("\u{1B}]133;\($0)".utf8)
            }
            #expect(injection.byteOffset > 0)
            #expect(injection.byteOffset < bytes.count)
            #expect(promptMarkPrefixes.contains { prefix in
                bytes[injection.byteOffset...].starts(with: prefix)
            })
            #expect(injection.rerunSelector.contains("zsh-dialect-width-sweep:7"))
            #expect(injection.diagnostic.contains("event=\(injection.eventIndex)"))
            #expect(injection.diagnostic.contains("byte=\(injection.byteOffset)"))
            let rerun = try selectedPromptAnchorSweepCases(selector: injection.rerunSelector)
            #expect(rerun.count == 1)
            #expect(rerun.first?.injection == injection)
        }
    }

    @Test("seeded intra-chunk resizes preserve every dialect recording's prompt outcome")
    func dialectRecordingSweep() throws {
        // Intent: move real authored resizes immediately before prompt re-marks inside
        //   feed chunks, checking the prompt snapshot oracle throughout replay.
        // Why it exists: all seven prompt-anchor bugs came from live timing shapes, and
        //   two escaped hand-built cases because no resize landed inside a feed chunk.
        // Scenario: a pane resize arrives after the shell's erase but before OSC 133 A,
        //   while completed command output from the preceding prompt remains retained.
        for sweepCase in try selectedPromptAnchorSweepCases() {
            let terminal = try replayPromptAnchorSweepCase(sweepCase)
            let diagnostic = sweepCase.injection.diagnostic
            let markerCount = terminal.fullHistoryText.components(
                separatedBy: promptAnchorCompletedOutputMarker
            ).count - 1
            let outcomeCount = terminal.fullHistoryText.components(
                separatedBy: sweepCase.fixture.promptOutcomeToken
            ).count - 1
            let context = Comment(rawValue: diagnostic)

            #expect(markerCount == 1, context)
            #expect(outcomeCount == 1, context)
            expectValidGrid(terminal, context: context)
        }
    }
}

private let promptAnchorCompletedOutputMarker = "DANTERM-SWEEP-COMPLETED"
private let promptAnchorSweepSeedBudget = UInt64(1)...8

private struct PromptAnchorSweepFixture {
    let name: String
    let promptOutcomeToken: String
    let recording: NeutralTerminalRecording
}

private struct PromptAnchorSweepCase {
    let fixture: PromptAnchorSweepFixture
    let injection: PromptAnchorResizeInjection
}

private struct PromptAnchorResizeInjection: Equatable {
    let fixtureName: String
    let seed: UInt64
    let eventIndex: Int
    let byteOffset: Int
    let columns: Int
    let rows: Int

    var rerunSelector: String {
        [fixtureName, String(seed), String(eventIndex), String(byteOffset), String(columns), String(rows)]
            .joined(separator: ":")
    }

    var diagnostic: String {
        "fixture=\(fixtureName) seed=\(seed) injection point event=\(eventIndex) "
            + "byte=\(byteOffset) resize=\(columns)x\(rows); rerun: "
            + "DANTERM_PROMPT_ANCHOR_SWEEP=\(rerunSelector) swift test --package-path "
            + "lib/TerminalCore --filter TerminalPromptAnchorResizeSweepTests.dialectRecordingSweep"
    }
}

private struct PromptAnchorFeedSpan {
    let eventIndex: Int
    let columns: Int
    let rows: Int
}

private struct PromptAnchorSweepGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

private enum PromptAnchorSweepError: Error {
    case noPromptMarks(String)
    case invalidRerunSelector(String)
    case unsupportedEvent(String)
}

private func loadPromptAnchorSweepFixture(named name: String) throws -> NeutralTerminalRecording {
    let url = try #require(Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures/danterm"
    ))
    return try JSONDecoder().decode(
        NeutralTerminalRecording.self,
        from: Data(contentsOf: url)
    )
}

private func promptAnchorResizeInjections(
    fixture: NeutralTerminalRecording,
    fixtureName: String,
    seed: UInt64
) throws -> [PromptAnchorResizeInjection] {
    let spans = promptAnchorFeedSpans(in: fixture)
    var generator = PromptAnchorSweepGenerator(state: seed)
    let promptMarks = ["A", "N", "P"].map { Array("\u{1B}]133;\($0)".utf8) }
    let injectableEvents = Set(spans.map(\.eventIndex))
    let markCandidates = fixture.events.enumerated().flatMap { eventIndex, event -> [(Int, Int)] in
        guard injectableEvents.contains(eventIndex), case .feed(let bytes) = event else { return [] }
        return bytes.indices.compactMap { offset in
            guard offset > 0 else { return nil }
            return promptMarks.contains { promptMark in
                offset + promptMark.count < bytes.count
                    && bytes[offset..<(offset + promptMark.count)].elementsEqual(promptMark)
            } ? (eventIndex, offset) : nil
        }
    }
    guard markCandidates.isEmpty == false else {
        throw PromptAnchorSweepError.noPromptMarks(fixtureName)
    }
    let mark = markCandidates[Int(generator.next() % UInt64(markCandidates.count))]
    let span = try #require(spans.first { $0.eventIndex == mark.0 })
    let beforePromptMark = promptAnchorInjection(
        eventIndex: mark.0,
        byteOffset: mark.1,
        span: span,
        fixtureName: fixtureName,
        seed: seed
    )
    return [beforePromptMark]
}

private func promptAnchorFeedSpans(
    in fixture: NeutralTerminalRecording
) -> [PromptAnchorFeedSpan] {
    var spans: [PromptAnchorFeedSpan] = []
    for (eventIndex, event) in fixture.events.enumerated() {
        guard case .feed(let bytes) = event,
              bytes.count > 1,
              let nextResize = fixture.events.dropFirst(eventIndex + 1).first(where: {
                  if case .resize = $0 { return true }
                  return false
              }),
              case .resize(let columns, let rows) = nextResize
        else { continue }
        spans.append(PromptAnchorFeedSpan(
            eventIndex: eventIndex,
            columns: columns,
            rows: rows
        ))
    }
    return spans
}

private func promptAnchorInjection(
    eventIndex: Int,
    byteOffset: Int,
    span: PromptAnchorFeedSpan,
    fixtureName: String,
    seed: UInt64
) -> PromptAnchorResizeInjection {
    return PromptAnchorResizeInjection(
        fixtureName: fixtureName,
        seed: seed,
        eventIndex: eventIndex,
        byteOffset: byteOffset,
        columns: span.columns,
        rows: span.rows
    )
}

private func selectedPromptAnchorSweepCases(
    selector: String? = ProcessInfo.processInfo.environment["DANTERM_PROMPT_ANCHOR_SWEEP"]
) throws -> [PromptAnchorSweepCase] {
    let fixtureSpecs = [
        ("bash-dialect-width-sweep", "repo:"),
        ("fish-dialect-width-sweep", "repo:"),
        ("zsh-dialect-width-sweep", "repo:"),
        ("fish-redraw-discriminator", "\u{256D}"),
        ("zsh-redraw-discriminator", "\u{256D}"),
    ]
    let fixtures = try fixtureSpecs.map { name, token in
        PromptAnchorSweepFixture(
            name: name,
            promptOutcomeToken: token,
            recording: try loadPromptAnchorSweepFixture(named: name)
        )
    }

    guard let selector else {
        return try fixtures.flatMap { fixture in
            try promptAnchorSweepSeedBudget.flatMap { seed in
                try promptAnchorResizeInjections(
                    fixture: fixture.recording,
                    fixtureName: fixture.name,
                    seed: seed
                ).map { PromptAnchorSweepCase(fixture: fixture, injection: $0) }
            }
        }
    }

    let fields = selector.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count == 6,
          let fixture = fixtures.first(where: { $0.name == fields[0] }),
          let seed = UInt64(fields[1]),
          let eventIndex = Int(fields[2]),
          let byteOffset = Int(fields[3]),
          let columns = Int(fields[4]),
          let rows = Int(fields[5]),
          fixture.recording.events.indices.contains(eventIndex),
          case .feed(let bytes) = fixture.recording.events[eventIndex],
          byteOffset > 0,
          byteOffset < bytes.count,
          columns >= 2,
          rows >= 1
    else {
        throw PromptAnchorSweepError.invalidRerunSelector(selector)
    }
    return [PromptAnchorSweepCase(
        fixture: fixture,
        injection: PromptAnchorResizeInjection(
            fixtureName: fixture.name,
            seed: seed,
            eventIndex: eventIndex,
            byteOffset: byteOffset,
            columns: columns,
            rows: rows
        )
    )]
}

private func replayPromptAnchorSweepCase(
    _ sweepCase: PromptAnchorSweepCase,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> Terminal {
    let fixture = sweepCase.fixture.recording
    let injection = sweepCase.injection
    let context = Comment(rawValue: injection.diagnostic)
    var terminal = try #require(
        Terminal(columns: fixture.initial.columns, rows: fixture.initial.rows),
        context,
        sourceLocation: sourceLocation
    )
    terminal.feed(Array(
        ("\u{1B}]133;C\u{7}\(promptAnchorCompletedOutputMarker)\r\n"
            + "\u{1B}]133;D;0\u{7}").utf8
    ))
    #expect(
        terminal.semanticPromptRowsForTesting.first?.stamp == .output,
        context,
        sourceLocation: sourceLocation
    )

    for (eventIndex, event) in fixture.events.enumerated() {
        switch event {
        case .feed(let bytes) where eventIndex == injection.eventIndex:
            terminal.feed(Array(bytes[..<injection.byteOffset]))
            drainPromptAnchorSweepEffects(from: &terminal)
            expectSemanticPromptInvariants(
                terminal,
                context: "\(injection.diagnostic) phase=feed-prefix",
                sourceLocation: sourceLocation
            )
            terminal.resize(columns: injection.columns, rows: injection.rows)
            expectSemanticPromptInvariants(
                terminal,
                context: "\(injection.diagnostic) phase=injected-resize",
                sourceLocation: sourceLocation
            )
            terminal.feed(Array(bytes[injection.byteOffset...]))
            drainPromptAnchorSweepEffects(from: &terminal)
        case .feed(let bytes):
            terminal.feed(bytes)
            drainPromptAnchorSweepEffects(from: &terminal)
        case .resize(let columns, let rows):
            terminal.resize(columns: columns, rows: rows)
        case .checkpoint:
            break
        case .input, .paste, .focus, .mouse, .viewport:
            throw PromptAnchorSweepError.unsupportedEvent(injection.diagnostic)
        }
        expectSemanticPromptInvariants(
            terminal,
            context: "\(injection.diagnostic) authored-event=\(eventIndex)",
            sourceLocation: sourceLocation
        )
    }
    return terminal
}

private func drainPromptAnchorSweepEffects(from terminal: inout Terminal) {
    _ = terminal.drainReplyBytes()
    _ = terminal.drainPendingClipboardWrite()
}

private extension NeutralTerminalRecordingEvent {
    var feedBytes: [UInt8]? {
        guard case .feed(let bytes) = self else { return nil }
        return bytes
    }
}
