// What the presentation-event trace must guarantee to a reader that computes a
// latency from it: nothing is written unless the environment asked for a trace,
// every event is one line, and the line carries the monotonic timestamp it was
// given rather than one the sampler chose later. Where the view records each
// event is the view's subject, not this file's.
import Foundation
import Testing

@testable import DanTerm

@MainActor
struct TerminalPresentationEventSamplerTests {
    @Test("no sampler exists unless the environment names a log file")
    func absentVariableMakesNoSampler() {
        #expect(TerminalPresentationEventSampler.make(environment: [:]) == nil)
        #expect(
            TerminalPresentationEventSampler.make(
                environment: [TerminalPresentationEventSampler.environmentVariable: ""]
            ) == nil
        )
    }

    // Intent: one recorded event becomes exactly one JSON line naming the event
    // and the timestamp it was recorded at.
    // Why it exists: the reader pairs a `reveal` with the `attach` that follows
    // it and subtracts the two timestamps, so a dropped line, a merged line, or
    // a re-clocked timestamp turns into a wrong latency rather than an error.
    // Scenario: a pane is created, revealed, presents a frame, and is hidden.
    @Test("each event is one line carrying its own name and timestamp")
    func eachEventIsOneTimestampedLine() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("presentation-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("trace.jsonl")

        let sampler = try #require(
            TerminalPresentationEventSampler.make(
                environment: [
                    TerminalPresentationEventSampler.environmentVariable: log.path,
                ]
            )
        )
        sampler.record(.create, at: 1_000)
        sampler.record(.reveal, at: 2_500)
        sampler.record(.attach, at: 9_750)
        sampler.record(.hide, at: 20_000)
        sampler.close()

        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .map { line -> [String: Any] in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                return object as? [String: Any] ?? [:]
            }
        #expect(lines.count == 4)
        #expect(lines.map { $0["event"] as? String } == ["create", "reveal", "attach", "hide"])
        #expect(lines.map { $0["uptimeNanoseconds"] as? UInt64 } == [1_000, 2_500, 9_750, 20_000])
        // One pane's whole trace carries one pane index, so a reader can split a
        // multi-pane log by it without any other key.
        #expect(Set(lines.compactMap { $0["pane"] as? Int }).count == 1)
    }

    // Intent: two panes tracing into one file stay separable.
    // Why it exists: the ten-tab staging traces ten panes into a single log, and
    // a reveal has to be paired with the attach of the same pane; sharing an
    // index would pair one pane's reveal with another pane's frame.
    // Scenario: two panes exist at once and both record an event.
    @Test("two samplers writing one file carry different pane indexes")
    func panesAreSeparable() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("presentation-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("trace.jsonl")
        let environment = [TerminalPresentationEventSampler.environmentVariable: log.path]

        let first = try #require(TerminalPresentationEventSampler.make(environment: environment))
        let second = try #require(TerminalPresentationEventSampler.make(environment: environment))
        first.record(.reveal, at: 1)
        second.record(.reveal, at: 2)
        first.close()
        second.close()

        let indexes = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .map { line -> Int in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                return (object as? [String: Any])?["pane"] as? Int ?? -1
            }
        try #require(indexes.count == 2)
        #expect(indexes[0] != indexes[1])
    }
}
