// The one bound that spans the recorder and the wire: no single record a production-bounded
// pane recorder can produce may exceed the JSON-RPC line ceiling once it is wrapped in the
// `pane.tape.event` notification that carries it.
//
// This lives here because the two ends belong to packages that must not know each other. The
// retention budget is TerminalPTYHost's and the framing bound is DanTermProtocol's, and the
// engine package deliberately does not depend on the protocol, so this is the only target
// that links both. Nothing else can catch the two drifting apart.
import Foundation
import Testing
import DanTermProtocol
@testable import TerminalPTYHost

struct PaneTapeEventLineBoundsTests {
    // Intent: no single record a production-bounded recorder can produce exceeds the IPC line
    //   ceiling once it is wrapped in the `pane.tape.event` notification that carries it.
    // Why it exists: the tape reaches a reader as one framed line per record, so the ceiling
    //   applies to the largest record, not to the whole capture. A retention budget that
    //   admits one event larger than a line would make that pane's tape unreadable, and no
    //   smaller record before or after it would show the problem.
    // Scenario: one pane fills its whole payload budget with a single burst of output, and
    //   another fills its whole event ring with the costliest small record the schema admits.
    @Test("no single record from a production-bounded recorder exceeds one JSON-RPC line")
    func productionBoundsFitIPCLine() throws {
        let bulkRecorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .production,
            now: { 0 }
        )
        bulkRecorder.record(.feed(Array(repeating: 0xFF, count: 8 * 1_024 * 1_024 - 128)))

        // A full ring of input-direction events, each with the widest origin stamp the clock
        // can produce. That is the costliest per-event encoding the schema admits, so a ring
        // of output events of the same size fits wherever this one does.
        let tinyRecorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .production,
            now: { 0 }
        )
        for _ in 0..<32_768 {
            tinyRecorder.recordWrite([0xFF], origin: .max, attribution: .user)
        }

        for recorder in [bulkRecorder, tinyRecorder] {
            let events = recorder.capture().snapshot.events
            #expect(events.isEmpty == false)
            var widestLine = Data()
            for event in events {
                let line = try encodeIpcLine(paneTapeEventNotification(event))
                if line.count > widestLine.count { widestLine = line }
            }
            #expect(widestLine.count <= IpcLineFramer.maxLineBytes)
            #expect(
                try JSONDecoder().decode(JsonRpcRequest.self, from: widestLine).method
                    == Methods.paneTapeEvent
            )
        }
    }
}

/// Wraps one recorded event in the notification the producer sends it in, so the size this
/// file measures is the size that actually has to cross the socket. The record shape mirrors
/// the producer's in DanTermSupport.
///
/// The producer may put several records in one such notification and splits that line when it
/// would pass the framing bound. A group of one record has no boundary left to split at, so
/// the per-record bound this file measures is what the split rule rests on.
private func paneTapeEventNotification(
    _ event: TerminalFlightRecordingEvent
) throws -> JsonRpcRequest {
    var record: [String: JSONValue] = [
        "kind": .string("event"),
        "sequence": .number(Double(event.sequence)),
        "elapsedNanoseconds": .number(Double(event.elapsedNanoseconds)),
        "event": try JSONDecoder().decode(
            JSONValue.self,
            from: JSONEncoder().encode(event.event)
        ),
    ]
    if let origin = event.originElapsedNanoseconds {
        record["originElapsedNanoseconds"] = .number(Double(origin))
    }
    if let payload = event.payload {
        record["byteOffset"] = .number(Double(payload.byteOffset))
        record["byteLength"] = .number(Double(payload.byteLength))
    }
    return JsonRpcRequest(
        method: Methods.paneTapeEvent,
        params: .object([
            "subscription": .string(UUID().uuidString),
            "records": .array([.object(record)]),
        ])
    )
}
