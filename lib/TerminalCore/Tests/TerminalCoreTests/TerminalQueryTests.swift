// Verifies terminal-generated query replies, purity, ordering, and chunk invariance.
import Testing

@testable import TerminalCore

/// Pins the core's ordered reply channel to only the capabilities DanTerm implements.
struct TerminalQueryTests {
    @Test("DA, status, and cursor reports emit exact 7-bit replies")
    func primaryQueries() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))

        terminal.feed(Array("\u{1B}Z\u{1B}[c\u{1B}[0c\u{1B}[5n\u{1B}[?5n".utf8))
        #expect(
            terminal.pendingReplyBytes
                == Array("\u{1B}[?1;2c\u{1B}[?1;2c\u{1B}[?1;2c\u{1B}[0n\u{1B}[?0n".utf8)
        )
        #expect(
            terminal.drainReplyBytes()
                == Array("\u{1B}[?1;2c\u{1B}[?1;2c\u{1B}[?1;2c\u{1B}[0n\u{1B}[?0n".utf8)
        )
        #expect(terminal.pendingReplyBytes.isEmpty)

        terminal.feed(Array("\u{1B}[3;4H\u{1B}[6n\u{1B}[?6n".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}[3;4R\u{1B}[?3;4R".utf8))
    }

    @Test("OSC 10 and 11 report canonical baked default colors without changing terminal state")
    func defaultColorQueries() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("content".utf8))
        let before = terminal

        terminal.feed(Array("\u{1B}]10;?\u{07}\u{1B}]11;?\u{1B}\\".utf8))

        #expect(
            terminal.drainReplyBytes()
                == Array(
                    ("\u{1B}]10;rgb:e5e5/e5e5/e5e5\u{1B}\\"
                        + "\u{1B}]11;rgb:0000/0000/0000\u{1B}\\").utf8
                )
        )
        #expect(terminal == before)
    }

    @Test("OSC 10 and 11 report the defaults injected for this terminal")
    func injectedDefaultColorQueries() throws {
        let defaults = TerminalDefaultColors(
            foreground: .init(red: 1, green: 35, blue: 69),
            background: .init(red: 103, green: 137, blue: 171)
        )
        var terminal = try #require(Terminal(columns: 8, rows: 4, defaultColors: defaults))

        terminal.feed(Array("\u{1B}]10;?\u{07}\u{1B}]11;?\u{1B}\\".utf8))

        #expect(terminal.drainReplyBytes() == Array(
            ("\u{1B}]10;rgb:0101/2323/4545\u{1B}\\"
                + "\u{1B}]11;rgb:6767/8989/abab\u{1B}\\").utf8
        ))
    }

    @Test("OSC default-color queries preserve stream order and recover after invalid forms")
    func defaultColorQueryOrderingAndRecovery() throws {
        let invalidQueries = [
            "\u{1B}]10;\u{07}",
            "\u{1B}]10;?;?\u{07}",
            "\u{1B}]10;rgb:ffff/ffff/ffff\u{07}",
            "\u{1B}]11;#ffffff\u{07}",
            "\u{1B}]12;?\u{07}",
            "\u{1B}]110;?\u{07}",
            "\u{1B}]111;?\u{07}",
        ]
        for query in invalidQueries {
            var terminal = try #require(Terminal(columns: 8, rows: 4))
            terminal.feed(Array("content".utf8))
            let before = terminal
            terminal.feed(Array(query.utf8))
            #expect(terminal == before, "query bytes: \(Array(query.utf8))")
            #expect(terminal.pendingReplyBytes.isEmpty)
        }

        let bytes = Array(
            (invalidQueries.joined() + "\u{1B}]10;?\u{07}\u{1B}[5n\u{1B}]11;?\u{1B}\\").utf8
        )
        let expected = Array(
            ("\u{1B}]10;rgb:e5e5/e5e5/e5e5\u{1B}\\"
                + "\u{1B}[0n"
                + "\u{1B}]11;rgb:0000/0000/0000\u{1B}\\").utf8
        )
        var authored = try #require(Terminal(columns: 8, rows: 4))
        authored.feed(bytes)
        #expect(authored.drainReplyBytes() == expected)

        for split in 0...bytes.count {
            var terminal = try #require(Terminal(columns: 8, rows: 4))
            terminal.feed(Array(bytes[..<split]))
            terminal.feed(Array(bytes[split...]))
            #expect(terminal.drainReplyBytes() == expected, "split at \(split)")
        }
    }

    @Test("CPR reports coordinates relative to the DECOM origin")
    func originRelativeCursorReport() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 5))

        terminal.feed(Array("\u{1B}[2;4r\u{1B}[?6h\u{1B}[2;3H\u{1B}[6n\u{1B}[?6n".utf8))

        #expect(terminal.drainReplyBytes() == Array("\u{1B}[2;3R\u{1B}[?2;3R".utf8))
    }

    @Test("DECRQM reports every implemented mode and zero for unknown modes")
    func modeQueries() throws {
        let decModes: [(mode: Int, initial: Int, enabled: Int, disabled: Int)] = [
            (1, 2, 1, 2),
            (6, 2, 1, 2),
            (7, 1, 1, 2),
            (12, 2, 1, 2),
            (25, 1, 1, 2),
            (1000, 2, 1, 2),
            (1002, 2, 1, 2),
            (1003, 2, 1, 2),
            (1004, 2, 1, 2),
            (1006, 2, 1, 2),
            (1047, 2, 1, 2),
            (1049, 2, 1, 2),
            (2026, 2, 1, 2),
            (2027, 3, 3, 3),
            (1048, 0, 0, 0),
            (2004, 2, 1, 2),
            (42, 0, 0, 0),
        ]
        for item in decModes {
            var terminal = try #require(Terminal(columns: 8, rows: 4))
            terminal.feed(Array("\u{1B}[?\(item.mode)$p".utf8))
            #expect(
                terminal.drainReplyBytes()
                    == Array("\u{1B}[?\(item.mode);\(item.initial)$y".utf8),
                "initial DEC mode \(item.mode)"
            )
            terminal.feed(Array("\u{1B}[?\(item.mode)h\u{1B}[?\(item.mode)$p".utf8))
            // Mode 1004 answers its own enable with the focus the terminal retains, which
            // arrives ahead of the DECRQM report.
            let enableReply = item.mode == 1004 ? Array("\u{1B}[O".utf8) : []
            #expect(
                terminal.drainReplyBytes()
                    == enableReply + Array("\u{1B}[?\(item.mode);\(item.enabled)$y".utf8),
                "enabled DEC mode \(item.mode)"
            )
            terminal.feed(Array("\u{1B}[?\(item.mode)l\u{1B}[?\(item.mode)$p".utf8))
            #expect(
                terminal.drainReplyBytes()
                    == Array("\u{1B}[?\(item.mode);\(item.disabled)$y".utf8),
                "disabled DEC mode \(item.mode)"
            )
        }

        let ansiModes: [(mode: Int, initial: Int, enabled: Int, disabled: Int)] = [
            (4, 2, 1, 2),
            (20, 2, 1, 2),
            (12, 0, 0, 0),
        ]
        for item in ansiModes {
            var terminal = try #require(Terminal(columns: 8, rows: 4))
            terminal.feed(Array("\u{1B}[\(item.mode)$p".utf8))
            #expect(
                terminal.drainReplyBytes()
                    == Array("\u{1B}[\(item.mode);\(item.initial)$y".utf8),
                "initial ANSI mode \(item.mode)"
            )
            terminal.feed(Array("\u{1B}[\(item.mode)h\u{1B}[\(item.mode)$p".utf8))
            #expect(
                terminal.drainReplyBytes()
                    == Array("\u{1B}[\(item.mode);\(item.enabled)$y".utf8),
                "enabled ANSI mode \(item.mode)"
            )
            terminal.feed(Array("\u{1B}[\(item.mode)l\u{1B}[\(item.mode)$p".utf8))
            #expect(
                terminal.drainReplyBytes()
                    == Array("\u{1B}[\(item.mode);\(item.disabled)$y".utf8),
                "disabled ANSI mode \(item.mode)"
            )
        }
    }

    @Test("DECSET and DECRST 2027 preserve grapheme assembly")
    func graphemeModeSequencesAreInert() throws {
        for sequence in ["\u{1B}[?2027h", "\u{1B}[?2027l"] {
            var terminal = try #require(Terminal(columns: 3, rows: 1))

            terminal.feed(Array("A\u{200D}\(sequence)\u{0301}".utf8))

            #expect(terminal.cell(row: 0, column: 0)?.scalars == ["A", "\u{200D}", "\u{0301}"])
        }
    }

    @Test("soft and hard reset preserve queued replies and report reset mode defaults")
    func resetsPreserveReplies() throws {
        for reset in ["\u{1B}[!p", "\u{1B}c"] {
            var terminal = try #require(Terminal(columns: 8, rows: 4))
            terminal.feed(Array("\u{1B}[c\u{1B}[?12h\u{1B}[?25l\u{1B}[?2026h\(reset)".utf8))

            #expect(terminal.pendingReplyBytes == Array("\u{1B}[?1;2c".utf8))
            terminal.feed(Array("\u{1B}[?12$p\u{1B}[?25$p\u{1B}[?2026$p".utf8))
            #expect(
                terminal.drainReplyBytes()
                    == Array("\u{1B}[?1;2c\u{1B}[?12;2$y\u{1B}[?25;1$y\u{1B}[?2026;2$y".utf8)
            )
        }
    }

    @Test("malformed and unsupported query forms are bit-identical no-ops")
    func unsupportedQueriesAreSilent() throws {
        let queries = [
            "\u{1B} Z",
            "\u{1B}[1c", "\u{1B}[>c", "\u{1B}[=c",
            "\u{1B}[4n", "\u{1B}[7n", "\u{1B}[?4n", "\u{1B}[?7n",
            "\u{1B}[$p", "\u{1B}[?6;7$p", "\u{1B}[>1q",
            // The two routed DCS families are answered and live in their own suites:
            // TerminalDECRQSSTests and TerminalXTGETTCAPTests. DA2 and 8-bit replies
            // stay denied (`docs/design/2026-08-06-swift-terminal-engine.md` I5).
        ]
        for query in queries {
            var terminal = try #require(Terminal(columns: 8, rows: 4))
            let before = terminal
            terminal.feed(Array(query.utf8))
            #expect(terminal == before, "query bytes: \(Array(query.utf8))")
        }
    }

    @Test("recognized queries preserve pending wrap and an open grapheme cluster")
    func queriesArePure() throws {
        var pendingWrap = try #require(Terminal(columns: 3, rows: 2))
        pendingWrap.feed(Array("abc".utf8))
        let pendingWrapBefore = pendingWrap
        pendingWrap.feed(Array("\u{1B}Z\u{1B}[5n\u{1B}[6n\u{1B}[?25$p".utf8))
        #expect(
            pendingWrap.drainReplyBytes()
                == Array("\u{1B}[?1;2c\u{1B}[0n\u{1B}[1;3R\u{1B}[?25;1$y".utf8)
        )
        #expect(pendingWrap == pendingWrapBefore)
        pendingWrap.feed(Array("Z".utf8))
        #expect(pendingWrap.screenText == "abc\nZ  ")

        var clustered = try #require(Terminal(columns: 3, rows: 2))
        clustered.feed(Array("e".utf8))
        let clusteredBefore = clustered
        clustered.feed(Array("\u{1B}Z\u{1B}[5n\u{1B}[6n\u{1B}[?25$p".utf8))
        #expect(
            clustered.drainReplyBytes()
                == Array("\u{1B}[?1;2c\u{1B}[0n\u{1B}[1;2R\u{1B}[?25;1$y".utf8)
        )
        #expect(clustered == clusteredBefore)
        clustered.feed(Array("\u{301}".utf8))
        #expect(clustered.cell(row: 0, column: 0)?.scalars == TerminalScalars("e\u{301}".unicodeScalars))
    }

    @Test("query replies are invariant across every split point")
    func queryChunkInvariance() throws {
        let bytes = Array("\u{1B}[3;4H\u{1B}Z\u{1B}[6n\u{1B}[?2026h\u{1B}[?2026$p".utf8)
        var authored = try #require(Terminal(columns: 8, rows: 4))
        authored.feed(bytes)

        for split in 0...bytes.count {
            var splitTerminal = try #require(Terminal(columns: 8, rows: 4))
            splitTerminal.feed(Array(bytes[..<split]))
            splitTerminal.feed(Array(bytes[split...]))
            #expect(splitTerminal == authored, "split at \(split)")
        }
    }

    @Test("reply growth remains bounded by a constant multiple of fed query bytes")
    func boundedReplyGrowth() throws {
        let fragments = [
            "\u{1B}[c", "\u{1B}[5n", "\u{1B}[6n", "\u{1B}[?6n",
            "\u{1B}[?2026$p", "\u{1B}[4$p", "\u{1B}[?9999$p",
        ].map { Array($0.utf8) }
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        var fedByteCount = 0

        for seed in 0..<256 {
            let fragment = fragments[seed % fragments.count]
            terminal.feed(fragment)
            fedByteCount += fragment.count
            #expect(terminal.pendingReplyBytes.count <= fedByteCount * 4)
        }
    }

    @Test("XTVERSION replies with the injected DanTerm version")
    func xtversion() throws {
        for query in ["\u{1B}[>q", "\u{1B}[>0q"] {
            var terminal = try #require(Terminal(columns: 8, rows: 4, programVersion: "1.2.3"))
            terminal.feed(Array(query.utf8))
            #expect(terminal.drainReplyBytes() == Array("\u{1B}P>|DanTerm 1.2.3\u{1B}\\".utf8))
        }
    }

    @Test("reply retention drops complete replies that exceed 64 KiB and recovers after drain")
    func replyLimitAndRecovery() throws {
        let query = Array("\u{1B}[5n".utf8)
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        for _ in 0..<16_384 { terminal.feed(query) }
        #expect(terminal.pendingReplyBytes.count == 65_536)
        terminal.feed(query)
        #expect(terminal.pendingReplyBytes.count == 65_536)
        _ = terminal.drainReplyBytes()
        terminal.feed(query)
        #expect(terminal.drainReplyBytes() == Array("\u{1B}[0n".utf8))
    }

    @Test("OSC default-color replies are admitted atomically at the 64 KiB limit")
    func defaultColorReplyLimitAndRecovery() throws {
        let query = Array("\u{1B}]10;?\u{07}".utf8)
        let reply = Array("\u{1B}]10;rgb:e5e5/e5e5/e5e5\u{1B}\\".utf8)
        var terminal = try #require(Terminal(columns: 8, rows: 4))

        for _ in 0..<(65_536 / reply.count) { terminal.feed(query) }
        #expect(terminal.pendingReplyBytes.count == (65_536 / reply.count) * reply.count)
        terminal.feed(query)
        #expect(terminal.pendingReplyBytes.count == (65_536 / reply.count) * reply.count)

        _ = terminal.drainReplyBytes()
        terminal.feed(query)
        #expect(terminal.drainReplyBytes() == reply)
    }
}
