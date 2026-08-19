// Behavioral tests for the shared neutral recording decoder and replay path.
import Foundation
import Testing
import TerminalCoreRecording

@testable import TerminalCore

/// Proves DanTerm-authored recordings use the same public replay path as corpus evidence.
struct NeutralTerminalRecordingTests {
    @Test("feed bytes encode as base64 and round-trip arbitrary values")
    func feedBytesEncodeAsBase64() throws {
        let bytes = Array(UInt8.min...UInt8.max)
        let encoded = try JSONEncoder().encode(NeutralTerminalRecordingEvent.feed(bytes))
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(object["base64"] as? String == Data(bytes).base64EncodedString())
        #expect(object["hex"] == nil)
        #expect(
            try JSONDecoder().decode(NeutralTerminalRecordingEvent.self, from: encoded)
                == .feed(bytes)
        )
    }

    @Test("malformed feed base64 is rejected")
    func malformedFeedBase64IsRejected() {
        let data = Data(#"{"type":"feed","base64":"not base64!"}"#.utf8)

        do {
            _ = try JSONDecoder().decode(NeutralTerminalRecordingEvent.self, from: data)
            Issue.record("Expected malformed base64 to be rejected.")
        } catch NeutralTerminalRecordingError.invalidBase64(let invalidBase64) {
            #expect(invalidBase64 == "not base64!")
        } catch {
            Issue.record("Expected invalidBase64, got \(error).")
        }
    }

    @Test("an unsupported schema version is reported as a version failure, not a geometry one")
    func unsupportedVersionIsRejectedAsAVersionFailure() {
        // Intent: replay() rejects a recording whose schema version it cannot read with
        //   .unsupportedVersion carrying the offending version, not .invalidDimensions.
        // Why it exists: the version check and the Terminal(columns:rows:) construction used
        //   to share one guard, so a future or corrupt schema pointed a debugging reader at
        //   `initial.columns`/`initial.rows` that were in fact perfectly valid.
        // Scenario: a recording written by a newer DanTerm carries version 2 with sound 8x2
        //   geometry; replaying it in an older core must name the schema as the problem.
        let recording = NeutralTerminalRecording(
            version: 2,
            provenance: .danTerm(test: "unsupported-version"),
            initial: NeutralTerminalDimensions(columns: 8, rows: 2),
            events: []
        )

        #expect(throws: NeutralTerminalRecordingError.unsupportedVersion(2)) {
            _ = try recording.replay()
        }
    }

    @Test("feed hex is rejected as an invalid event shape")
    func feedHexIsRejected() {
        #expect(throws: NeutralTerminalRecordingError.self) {
            try JSONDecoder().decode(
                NeutralTerminalRecordingEvent.self,
                from: Data(#"{"type":"feed","hex":"00ff"}"#.utf8)
            )
        }
    }

    @Test(
        "event objects reject missing, duplicate, and unknown fields",
        arguments: [
            #"{"type":"feed"}"#,
            #"{"type":"feed","base64":"YQ==","text":"a"}"#,
            #"{"type":"feed","base64":"YQ==","note":"ignored"}"#,
            #"{"type":"resize","columns":8,"rows":2,"note":"ignored"}"#,
            #"{"type":"expect","expect":{},"note":"ignored"}"#,
            #"{"type":"write"}"#,
            #"{"type":"write","base64":"YQ==","text":"a"}"#,
            #"{"type":"write","base64":"YQ==","note":"ignored"}"#,
        ]
    )
    func invalidEventFieldsAreRejected(_ json: String) {
        #expect(throws: NeutralTerminalRecordingError.self) {
            try JSONDecoder().decode(
                NeutralTerminalRecordingEvent.self,
                from: Data(json.utf8)
            )
        }
    }

    @Test("inert event timing must be a nonnegative integer wherever the schema admits it")
    func invalidElapsedTimingIsRejected() {
        for json in [
            #"{"type":"feed","base64":"YQ==","elapsedNanoseconds":-1}"#,
            #"{"type":"resize","columns":8,"rows":2,"elapsedNanoseconds":"later"}"#,
            #"{"type":"expect","elapsedNanoseconds":null}"#,
            #"{"type":"write","base64":"Aw==","originElapsedNanoseconds":-1}"#,
            #"{"type":"write","base64":"Aw==","originElapsedNanoseconds":"earlier"}"#,
        ] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(
                    NeutralTerminalRecordingEvent.self,
                    from: Data(json.utf8)
                )
            }
        }
    }

    @Test("bytes written toward the child round-trip and leave replay untouched")
    func writeBytesRoundTripAndReplayIgnoresThem() throws {
        // Intent: the vocabulary carries a byte transfer travelling toward the child, encoded
        //   like a feed, and replay reaches the same terminal it would have without it.
        // Why it exists: a tape is a two-directional boundary ledger, but only child output
        //   drives the replayed terminal. A write event that fed the terminal would replay the
        //   user's keystrokes as if the child had echoed them twice.
        let bytes = Array(UInt8.min...UInt8.max)
        let encoded = try JSONEncoder().encode(NeutralTerminalRecordingEvent.write(bytes))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["type"] as? String == "write")
        #expect(object["base64"] as? String == Data(bytes).base64EncodedString())
        #expect(
            try JSONDecoder().decode(NeutralTerminalRecordingEvent.self, from: encoded)
                == .write(bytes)
        )

        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "write-replay"),
            initial: NeutralTerminalDimensions(columns: 8, rows: 2),
            events: [
                .feed(Array("hi".utf8)),
                .write(Array("\u{03}".utf8)),
                .feed(Array("!".utf8)),
            ]
        )
        var expected = try #require(Terminal(columns: 8, rows: 2))
        expected.feed(Array("hi".utf8))
        expected.feed(Array("!".utf8))

        #expect(try recording.replay() == expected)
    }

    @Test("a write event carries an optional origin stamp that no other event may")
    func writeOriginStampIsInertAndExclusive() throws {
        // Intent: only a write event admits the second inert timing key, and decoding ignores
        //   it exactly as it ignores elapsed timing.
        // Why it exists: the origin stamp answers "when did the app first hold these bytes",
        //   which is meaningless for child output -- the read and the record share one turn.
        let stamped = try JSONDecoder().decode(
            NeutralTerminalRecordingEvent.self,
            from: Data(
                #"{"type":"write","text":"ls\n","elapsedNanoseconds":9,"originElapsedNanoseconds":4}"#
                    .utf8
            )
        )

        #expect(stamped == .write(Array("ls\n".utf8)))

        for json in [
            #"{"type":"feed","base64":"YQ==","originElapsedNanoseconds":4}"#,
            #"{"type":"resize","columns":8,"rows":2,"originElapsedNanoseconds":4}"#,
        ] {
            #expect(throws: NeutralTerminalRecordingError.self) {
                try JSONDecoder().decode(
                    NeutralTerminalRecordingEvent.self,
                    from: Data(json.utf8)
                )
            }
        }
    }

    @Test("live capture provenance is replay-valid and distinct from fixture provenance")
    func liveCaptureProvenanceValidates() throws {
        let provenance = NeutralTerminalProvenance.liveCapture()

        try provenance.validate()
        #expect(provenance.source == "danterm-live-capture")
        #expect(provenance != .danTerm(test: "live-pane-tape"))
    }

    @Test("elapsed timestamps are inert during decode and replay")
    func elapsedTimestampsAreInert() throws {
        let withTimestamps = Data(#"""
        {
          "version": 1,
          "provenance": {"source":"danterm-live-capture","author":"DanTerm","test":"live-pane-tape"},
          "initial": {"columns": 8, "rows": 2},
          "futureMetadata": {"readerMayIgnore": true},
          "events": [
            {"type":"feed","base64":"aGk=","elapsedNanoseconds":12},
            {"type":"resize","columns":10,"rows":3,"elapsedNanoseconds":25}
          ]
        }
        """#.utf8)
        let withoutTimestamps = Data(#"""
        {
          "version": 1,
          "provenance": {"source":"danterm-live-capture","author":"DanTerm","test":"live-pane-tape"},
          "initial": {"columns": 8, "rows": 2},
          "events": [
            {"type":"feed","base64":"aGk="},
            {"type":"resize","columns":10,"rows":3}
          ]
        }
        """#.utf8)

        let timed = try JSONDecoder().decode(NeutralTerminalRecording.self, from: withTimestamps)
        let untimed = try JSONDecoder().decode(NeutralTerminalRecording.self, from: withoutTimestamps)

        #expect(timed == untimed)
        #expect(try timed.replay() == untimed.replay())
    }

    @Test("Alacritty provenance validates its pinned Apache-2.0 source")
    func alacrittyProvenanceValidates() throws {
        let provenance = NeutralTerminalProvenance(
            source: "alacritty",
            url: "https://github.com/alacritty/alacritty/blob/852e971cddfabe222d2d5bcda466e130f53af207/alacritty_terminal/tests/ref/hyperlinks/alacritty.recording",
            pinnedCommit: "852e971cddfabe222d2d5bcda466e130f53af207",
            upstreamCase: "hyperlinks",
            license: "Apache-2.0",
            licenseNotice: "LICENSE.alacritty.txt"
        )

        try provenance.validate()
    }

    @Test("recording replay applies Cmd-hover and keeps Cmd-click local-only")
    func replayAppliesHoverWithoutOpening() throws {
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "hover-replay"),
            initial: .init(columns: 16, rows: 2),
            events: [
                .feed(Array("https://a.co".utf8)),
                .mouse(.init(
                    action: .move,
                    column: 2,
                    row: 0,
                    modifiers: [.command]
                )),
            ]
        )

        let encoded = try JSONEncoder().encode(recording)
        let decoded = try JSONDecoder().decode(NeutralTerminalRecording.self, from: encoded)
        var replayed = try decoded.replay()

        #expect(decoded == recording)
        #expect(replayed.hoveredLink?.hyperlink.uri == "https://a.co")

        var interactionState = TerminalInteractionState()
        let downBytes = applyNeutralTerminalMouse(
            .init(
                action: .down,
                button: 1,
                column: 2,
                row: 0,
                modifiers: [.command]
            ),
            terminal: &replayed,
            interactionState: &interactionState
        )
        let upBytes = applyNeutralTerminalMouse(
            .init(
                action: .up,
                button: 1,
                column: 2,
                row: 0,
                modifiers: [.command]
            ),
            terminal: &replayed,
            interactionState: &interactionState
        )
        #expect(downBytes.isEmpty)
        #expect(upBytes.isEmpty)
        #expect(replayed.hoveredLink == nil)
        #expect(replayed.armedLink == nil)
    }
    @Test("DanTerm recordings encode, decode, and replay output around resize")
    func danTermRecordingRoundTrip() throws {
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "output-resize-output"),
            initial: NeutralTerminalDimensions(columns: 8, rows: 2),
            events: [
                .feed(Array("before".utf8)),
                .resize(columns: 12, rows: 3, pinned: false),
                .feed(Array("\nafter".utf8)),
            ]
        )

        let encoded = try JSONEncoder().encode(recording)
        let decoded = try JSONDecoder().decode(NeutralTerminalRecording.self, from: encoded)
        let replayed = try decoded.replay()

        #expect(decoded == recording)
        #expect(replayed.geometry.columns == 12)
        #expect(replayed.geometry.rows.count == 3)
        #expect(replayed.screenText.contains("after"))
    }

    @Test("recording replay drains core replies after every feed")
    func replayDrainsReplies() throws {
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "query-output"),
            initial: NeutralTerminalDimensions(columns: 8, rows: 2),
            events: [
                .feed(Array("\u{1B}[6n".utf8)),
                .feed(Array("visible".utf8)),
            ]
        )

        let replayed = try recording.replay()

        #expect(replayed.pendingReplyBytes.isEmpty)
        #expect(replayed.screenText.contains("visible"))
    }

    @Test("viewport navigation encodes, decodes, and replays whole-value exactly")
    func viewportNavigationRoundTrip() throws {
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "viewport-navigation"),
            initial: NeutralTerminalDimensions(columns: 8, rows: 2),
            events: [
                .feed(Array("one\ntwo\nthree\nfour".utf8)),
                .viewport(.byRows(-1)),
                .viewport(.toTopRow(0)),
                .viewport(.toBottom),
                .viewport(.byRows(-1)),
            ]
        )

        let encoded = try JSONEncoder().encode(recording)
        let decoded = try JSONDecoder().decode(NeutralTerminalRecording.self, from: encoded)
        let replayed = try decoded.replay()
        var expected = try #require(Terminal(columns: 8, rows: 2))
        expected.feed(Array("one\ntwo\nthree\nfour".utf8))
        expected.scroll(byRows: -1)
        expected.scroll(toTopRow: 0)
        expected.scrollToBottom()
        expected.scroll(byRows: -1)

        #expect(decoded == recording)
        #expect(replayed == expected)
        #expect(replayed.scrollProjection.isFollowing == false)
    }

    @Test("mouse input round-trips and replay applies multi-click local selection")
    func mouseSelectionRoundTrip() throws {
        let mouse = NeutralTerminalMouseEvent(
            action: .down,
            button: 1,
            column: 1,
            row: 0,
            modifiers: [.shift],
            clickCount: 2
        )
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "mouse-selection"),
            initial: NeutralTerminalDimensions(columns: 12, rows: 2),
            events: [
                .feed(Array("hello world\u{1B}[?1000h".utf8)),
                .mouse(mouse),
                .mouse(NeutralTerminalMouseEvent(
                    action: .up,
                    button: 1,
                    column: 1,
                    row: 0,
                    modifiers: [.shift]
                )),
            ]
        )

        let encoded = try JSONEncoder().encode(recording)
        let decoded = try JSONDecoder().decode(NeutralTerminalRecording.self, from: encoded)
        let replayed = try decoded.replay()

        #expect(decoded == recording)
        #expect(decoded.events[1] == .mouse(mouse))
        #expect(replayed.selectedText == "hello")
    }

    @Test("a recorded character drag replays to the selection its sub-cell offsets named")
    func characterDragOffsetRoundTrip() throws {
        // Intent: a captured pointer transition carries the horizontal position the live path
        //   resolved a character boundary from, so encoding, decoding, and replay reproduce the
        //   selection the user saw. A recording written before that field decodes to the cell's
        //   leading edge rather than failing.
        // Why it exists: the recorded event rebuilt pointer events from column and row alone.
        //   A character drag confined to one cell would then replay as a drag that never moved,
        //   turning the fixture for that gesture into a fixture for no gesture at all.
        let events: [NeutralTerminalRecordingEvent] = [
            .feed(Array("hello".utf8)),
            .mouse(.init(action: .down, button: 1, column: 1, row: 0, offsetX: 0.1)),
            .mouse(.init(action: .move, column: 1, row: 0, offsetX: 0.9)),
            .mouse(.init(action: .up, button: 1, column: 1, row: 0)),
        ]
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "character-drag-offset"),
            initial: NeutralTerminalDimensions(columns: 8, rows: 2),
            events: events
        )

        let decoded = try JSONDecoder().decode(
            NeutralTerminalRecording.self,
            from: try JSONEncoder().encode(recording)
        )
        #expect(decoded == recording)
        #expect(try decoded.replay().selectedText == "e")

        // A document written before the field existed: the key is absent, not zero, and must
        // still decode and replay. Both ends then land on one boundary, which is the honest
        // answer -- the gesture's sub-cell intent was never captured.
        let older = try JSONDecoder().decode(NeutralTerminalRecording.self, from: Data(#"""
        {
          "version": 1,
          "provenance": {
            "source":"danterm",
            "author":"DanTerm",
            "test":"character-drag-no-offset"
          },
          "initial": {"columns": 8, "rows": 2},
          "events": [
            {"type":"feed", "text":"hello"},
            {"type":"mouse", "action":"down", "button":1, "column":1, "row":0},
            {"type":"mouse", "action":"move", "column":1, "row":0},
            {"type":"mouse", "action":"up", "button":1, "column":1, "row":0}
          ]
        }
        """#.utf8))

        #expect(try older.replay().selectionRange == nil)
    }

    @Test("a recorded off-grid pointer replays off-grid while an older tape replays as inside")
    func offGridMouseRoundTrip() throws {
        // Intent: the neutral record carries the insideness the view measured, so a replica
        //   replaying at the same geometry reaches the same link decision as the pane. A tape
        //   written before the field decodes as inside.
        // Why it exists: the record carried column and row alone, and replay minted an
        //   insideness nobody measured. An off-grid Cmd-press that armed nothing on the Mac
        //   then replayed on a replica as an on-grid press that armed a link.
        // Scenario: the same Cmd-press over a link is recorded twice at one address, once
        //   measured inside the grid and once measured outside it.
        func recording(isInsideGrid: Bool) -> NeutralTerminalRecording {
            NeutralTerminalRecording(
                provenance: .danTerm(test: "off-grid-mouse"),
                initial: NeutralTerminalDimensions(columns: 16, rows: 2),
                events: [
                    .feed(Array("https://a.co".utf8)),
                    .mouse(.init(
                        action: .move,
                        column: 2,
                        row: 0,
                        isInsideGrid: isInsideGrid,
                        modifiers: [.command]
                    )),
                    .mouse(.init(
                        action: .down,
                        button: 1,
                        column: 2,
                        row: 0,
                        isInsideGrid: isInsideGrid,
                        modifiers: [.command]
                    )),
                ]
            )
        }

        func decode(_ value: NeutralTerminalRecording) throws -> NeutralTerminalRecording {
            try JSONDecoder().decode(
                NeutralTerminalRecording.self,
                from: try JSONEncoder().encode(value)
            )
        }

        let inside = try decode(recording(isInsideGrid: true))
        #expect(inside == recording(isInsideGrid: true))
        let insideReplay = try inside.replay()
        #expect(insideReplay.hoveredLink?.hyperlink.uri == "https://a.co")
        #expect(insideReplay.armedLink?.hyperlink.uri == "https://a.co")

        let outside = try decode(recording(isInsideGrid: false))
        #expect(outside == recording(isInsideGrid: false))
        let outsideReplay = try outside.replay()
        #expect(outsideReplay.hoveredLink == nil)
        #expect(outsideReplay.armedLink == nil)

        // A document written before the field existed: the key is absent, not false, so the
        // pointer replays as the on-grid one its clamped coordinates describe.
        let older = try JSONDecoder().decode(NeutralTerminalRecording.self, from: Data(#"""
        {
          "version": 1,
          "provenance": {
            "source":"danterm",
            "author":"DanTerm",
            "test":"off-grid-mouse-untracked"
          },
          "initial": {"columns": 16, "rows": 2},
          "events": [
            {"type":"feed", "text":"https://a.co"},
            {"type":"mouse", "action":"move", "column":2, "row":0, "modifiers":["command"]},
            {"type":"mouse", "action":"down", "button":1, "column":2, "row":0,
             "modifiers":["command"]}
          ]
        }
        """#.utf8))

        #expect(try older.replay().armedLink?.hyperlink.uri == "https://a.co")
    }

    @Test("captured mouse reports are discarded without mutating replayed terminal state")
    func capturedMouseReplayIsTransparent() throws {
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "captured-mouse"),
            initial: NeutralTerminalDimensions(columns: 8, rows: 2),
            events: [
                .feed(Array("text\u{1B}[?1000;1006h".utf8)),
                .mouse(NeutralTerminalMouseEvent(
                    action: .down,
                    button: 1,
                    column: 2,
                    row: 1,
                    clickCount: 3
                )),
                .mouse(NeutralTerminalMouseEvent(
                    action: .up,
                    button: 1,
                    column: 2,
                    row: 1
                )),
            ]
        )
        var expected = try #require(Terminal(columns: 8, rows: 2))
        expected.feed(Array("text\u{1B}[?1000;1006h".utf8))

        let replayed = try recording.replay()

        #expect(replayed == expected)
        #expect(replayed.selectionRange == nil)
    }

    @Test("neutral wheel buttons 4-7 round-trip through the JSON codec")
    func mouseWheelButtonsRoundTrip() throws {
        // Intent: the neutral schema still admits the 4-7 wheel button vocabulary end to end,
        //   encode through decode, without narrowing the decoder's `(1...7)` range check.
        // Why it exists: the button -> direction mapping itself is pinned by
        //   Fixtures/libvterm/state-mouse.json (events 27-31) through TerminalFixtureTests;
        //   this test only guards the codec's acceptance of those buttons, and its old title
        //   claimed direction coverage it never exercised.
        // Scenario: a captured recording carries wheel-up/down/left/right presses and must
        //   survive a serialize/deserialize hop unchanged.
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "mouse-wheel-buttons"),
            initial: NeutralTerminalDimensions(columns: 8, rows: 2),
            events: (4...7).map { button in
                .mouse(NeutralTerminalMouseEvent(
                    action: .down,
                    button: button,
                    column: 3,
                    row: 1
                ))
            }
        )

        let encoded = try JSONEncoder().encode(recording)
        let decoded = try JSONDecoder().decode(NeutralTerminalRecording.self, from: encoded)

        #expect(decoded == recording)
    }

    @Test("readable text feeds decode and replay without changing their UTF-8 bytes")
    func readableTextFeedRoundTrip() throws {
        let data = Data(#"""
        {
          "version": 1,
          "provenance": {
            "source":"danterm",
            "author":"DanTerm",
            "test":"readable-text",
            "note":"top-level provenance remains extensible"
          },
          "initial": {"columns": 8, "rows": 2},
          "events": [
            {"type":"feed", "text":"café"},
            {"type":"resize", "columns": 10, "rows": 3}
          ]
        }
        """#.utf8)

        let recording = try JSONDecoder().decode(NeutralTerminalRecording.self, from: data)

        #expect(recording.events == [
            .feed(Array("café".utf8)),
            .resize(columns: 10, rows: 3, pinned: false),
        ])
        #expect(try recording.replay().geometry.columns == 10)
    }

}
