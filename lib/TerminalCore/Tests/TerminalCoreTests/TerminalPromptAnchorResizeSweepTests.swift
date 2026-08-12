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
        // Why it exists: seeds are how a developer widens the sweep past the cases the gate
        //   chose, and a seeded run without a concrete rerun selector turns a regression into a
        //   search problem; event-boundary-only injection would also miss the erase-to-re-mark
        //   window this sweep exists to probe.
        // Scenario: a developer widens the sweep with
        //   `DANTERM_PROMPT_ANCHOR_SWEEP=<fixture>:<seed>`, hits a failure, and reruns exactly
        //   that case from the token it printed.
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
            let seededSelector = try selectedPromptAnchorSweepCases(
                selector: "zsh-dialect-width-sweep:7"
            )
            #expect(seededSelector.count == 1)
            #expect(seededSelector.first?.injection == injection)
        }
    }

    @Test("the sweep's chosen cases pin both ends of every fixture's candidate axis")
    func boundaryCaseContract() throws {
        // Intent: the case set the gate replays reaches each fixture's first and last legal
        //   injection point, both extremes of the follow-up resize, and every distinct in-chunk
        //   byte offset -- with no two cases replaying the same injection.
        // Why it exists: these cases replaced eight seeded draws per fixture, and a chosen set
        //   is only worth the seeds it replaced if the choosing rules actually hold. Nothing in
        //   `dialectRecordingSweep` itself would notice a rule that silently collapsed to one
        //   point, because a smaller sweep still passes.
        // Scenario: a fixture is re-recorded, or a rule is edited, and the sweep quietly stops
        //   covering the narrow end of the width sweep where the prompt wraps differently.
        for fixtureName in ["zsh-dialect-width-sweep", "zsh-redraw-discriminator"] {
            let recording = try loadPromptAnchorSweepFixture(named: fixtureName)
            let candidates = promptAnchorMarkCandidates(in: recording)
            let injections = try promptAnchorBoundaryInjections(
                fixture: recording,
                fixtureName: fixtureName
            )
            let points = Set(injections.map { [$0.eventIndex, $0.byteOffset] })

            #expect(injections.count == Set(injections.map(\.identity)).count)
            #expect(points.contains([candidates[0].eventIndex, candidates[0].byteOffset]))
            #expect(points.contains([
                candidates[candidates.count - 1].eventIndex,
                candidates[candidates.count - 1].byteOffset,
            ]))
            let areas = candidates.map { $0.span.columns * $0.span.rows }
            let chosenAreas = Set(injections.map { $0.columns * $0.rows })
            #expect(chosenAreas.contains(try #require(areas.min())))
            #expect(chosenAreas.contains(try #require(areas.max())))
            #expect(
                Set(injections.map(\.byteOffset)) == Set(candidates.map(\.byteOffset))
            )
        }
    }

    @Test("chosen intra-chunk resizes preserve every dialect recording's prompt outcome")
    func dialectRecordingSweep() throws {
        // Intent: move real authored resizes immediately before prompt re-marks inside
        //   feed chunks, checking the prompt snapshot oracle throughout replay.
        // Why it exists: all seven prompt-anchor bugs came from live timing shapes, and
        //   two escaped hand-built cases because no resize landed inside a feed chunk.
        // Scenario: a pane resize arrives after the shell's erase but before OSC 133 A,
        //   while completed command output from the preceding prompt remains retained.
        var gridValidatedFixtures: Set<String> = []
        for sweepCase in try selectedPromptAnchorSweepCases() {
            let terminal = try replayPromptAnchorSweepCase(sweepCase)
            let historyText = terminal.fullHistoryText
            let markerCount = historyText.components(
                separatedBy: promptAnchorCompletedOutputMarker
            ).count - 1
            let outcomeCount = historyText.components(
                separatedBy: sweepCase.fixture.promptOutcomeToken
            ).count - 1
            let context = Comment(rawValue: sweepCase.injection.diagnostic)

            #expect(markerCount == 1, context)
            #expect(outcomeCount == 1, context)
            // Structural validity is a property of the fixture's replay shape rather than of which
            // point the resize was injected at, and it copies the whole terminal twice, so one case
            // per fixture carries it. `TerminalShellDialectTests` runs it on the un-injected replay
            // of the two discriminator fixtures; this is the injected counterpart for all five.
            if gridValidatedFixtures.insert(sweepCase.fixture.name).inserted {
                expectValidGrid(terminal, context: context)
            }
        }
    }
}

private let promptAnchorCompletedOutputMarker = "DANTERM-SWEEP-COMPLETED"

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
    /// How this injection point was chosen -- a seed for the seeded path, a boundary rule's name
    /// for the ones the gate runs. Carried in the rerun selector so a failure names its own
    /// provenance; deliberately not part of `identity`, which is what dedupe compares.
    let selection: String
    let eventIndex: Int
    let byteOffset: Int
    let columns: Int
    let rows: Int

    /// The replay this injection actually performs. Two rules that choose the same point produce
    /// the same replay, so this -- not the whole struct -- is what the sweep dedupes on.
    var identity: String {
        [fixtureName, String(eventIndex), String(byteOffset), String(columns), String(rows)]
            .joined(separator: ":")
    }

    var rerunSelector: String {
        [fixtureName, selection, String(eventIndex), String(byteOffset), String(columns), String(rows)]
            .joined(separator: ":")
    }

    var diagnostic: String {
        "fixture=\(fixtureName) selection=\(selection) injection point event=\(eventIndex) "
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

/// One legal injection point: a byte offset inside an authored feed chunk that sits immediately
/// before an OSC 133 prompt mark, paired with the resize the recording performs after that chunk.
private struct PromptAnchorMarkCandidate {
    let eventIndex: Int
    let byteOffset: Int
    let span: PromptAnchorFeedSpan
}

/// Every intra-chunk point the sweep is allowed to move a resize to, in replay order.
///
/// Both selection paths read this list, so a seeded rerun token and a gate case name positions
/// from the same enumeration.
private func promptAnchorMarkCandidates(
    in fixture: NeutralTerminalRecording
) -> [PromptAnchorMarkCandidate] {
    let spans = promptAnchorFeedSpans(in: fixture)
    let spansByEvent = Dictionary(
        spans.map { ($0.eventIndex, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    let promptMarks = ["A", "N", "P"].map { Array("\u{1B}]133;\($0)".utf8) }
    return fixture.events.enumerated().flatMap { eventIndex, event -> [PromptAnchorMarkCandidate] in
        guard let span = spansByEvent[eventIndex], case .feed(let bytes) = event else { return [] }
        return bytes.indices.compactMap { offset in
            guard offset > 0 else { return nil }
            let startsAMark = promptMarks.contains { promptMark in
                offset + promptMark.count < bytes.count
                    && bytes[offset..<(offset + promptMark.count)].elementsEqual(promptMark)
            }
            guard startsAMark else { return nil }
            return PromptAnchorMarkCandidate(eventIndex: eventIndex, byteOffset: offset, span: span)
        }
    }
}

private func promptAnchorResizeInjections(
    fixture: NeutralTerminalRecording,
    fixtureName: String,
    seed: UInt64
) throws -> [PromptAnchorResizeInjection] {
    let markCandidates = promptAnchorMarkCandidates(in: fixture)
    guard markCandidates.isEmpty == false else {
        throw PromptAnchorSweepError.noPromptMarks(fixtureName)
    }
    var generator = SeededByteGenerator(state: seed)
    let mark = markCandidates[Int(generator.nextWord() % UInt64(markCandidates.count))]
    return [promptAnchorInjection(
        candidate: mark,
        fixtureName: fixtureName,
        selection: String(seed)
    )]
}

/// The injection points the gate replays: the ends of each fixture's candidate axis, both extremes
/// of the follow-up resize, one representative per distinct in-chunk byte offset, and three
/// interior positions.
///
/// These recordings are one-column-at-a-time width sweeps, so a candidate's event index, its depth
/// in history, and the width it is resized to all move together -- the candidate list is one
/// ordered axis, and what the seeded form did was draw eight points on it. Drawing them
/// deterministically is both cheaper and wider: the eight seeds land on eight *consecutive*
/// candidates of `fish-dialect-width-sweep`'s forty, never reaching either end, where these rules
/// pin both ends by construction. `first`/`last` and `narrowest`/`widest` are separate rules
/// because a recording that does not sweep monotonically would separate them.
private func promptAnchorBoundaryInjections(
    fixture: NeutralTerminalRecording,
    fixtureName: String
) throws -> [PromptAnchorResizeInjection] {
    let candidates = promptAnchorMarkCandidates(in: fixture)
    guard let first = candidates.first, let last = candidates.last else {
        throw PromptAnchorSweepError.noPromptMarks(fixtureName)
    }
    func area(_ candidate: PromptAnchorMarkCandidate) -> Int {
        candidate.span.columns * candidate.span.rows
    }
    var chosen: [(String, PromptAnchorMarkCandidate)] = [
        ("first", first),
        ("last", last),
    ]
    if let narrowest = candidates.min(by: { area($0) < area($1) }) {
        chosen.append(("narrowest", narrowest))
    }
    if let widest = candidates.max(by: { area($0) < area($1) }) {
        chosen.append(("widest", widest))
    }
    for quarter in 1...3 {
        chosen.append(("quarter\(quarter)", candidates[candidates.count * quarter / 4]))
    }
    var seenOffsets: Set<Int> = []
    for candidate in candidates where seenOffsets.insert(candidate.byteOffset).inserted {
        chosen.append(("offset\(candidate.byteOffset)", candidate))
    }

    var seenIdentities: Set<String> = []
    return chosen.compactMap { selection, candidate in
        let injection = promptAnchorInjection(
            candidate: candidate,
            fixtureName: fixtureName,
            selection: selection
        )
        return seenIdentities.insert(injection.identity).inserted ? injection : nil
    }
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
    candidate: PromptAnchorMarkCandidate,
    fixtureName: String,
    selection: String
) -> PromptAnchorResizeInjection {
    return PromptAnchorResizeInjection(
        fixtureName: fixtureName,
        selection: selection,
        eventIndex: candidate.eventIndex,
        byteOffset: candidate.byteOffset,
        columns: candidate.span.columns,
        rows: candidate.span.rows
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
            try promptAnchorBoundaryInjections(
                fixture: fixture.recording,
                fixtureName: fixture.name
            ).map { PromptAnchorSweepCase(fixture: fixture, injection: $0) }
        }
    }

    let fields = selector.split(separator: ":", omittingEmptySubsequences: false)
    // Two fields is the seeded form: it regenerates the injection a seed selects, so an arbitrary
    // seed is still runnable from the command line now that the gate's own cases are chosen.
    if fields.count == 2,
       let fixture = fixtures.first(where: { $0.name == fields[0] }),
       let seed = UInt64(fields[1])
    {
        return try promptAnchorResizeInjections(
            fixture: fixture.recording,
            fixtureName: fixture.name,
            seed: seed
        ).map { PromptAnchorSweepCase(fixture: fixture, injection: $0) }
    }
    guard fields.count == 6,
          let fixture = fixtures.first(where: { $0.name == fields[0] }),
          fields[1].isEmpty == false,
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
            selection: String(fields[1]),
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
        case .write, .input, .paste, .focus, .mouse, .viewport:
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
