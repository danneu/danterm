// Behavioral proof for the OSC 133 dialect that DanTerm's bundled shell integrations
// emit (docs/research/24-osc-133-dialect). Everything here replays a live PTY
// recording of a real shell rather than hand-written marks, so the dialect is pinned
// to what `integrations/shell-integration/danterm.{zsh,bash,fish}` actually produce
// in front of a real prompt framework. Two kinds of recording live here and they
// answer different questions: the `fish-staircase-*` trio reproduces the original
// incident and discriminates the `redraw` value, while the `*-dialect-width-sweep`
// recordings guard the shipped emitters against regressing. Parser-level unit cases
// for the marks themselves stay in TerminalOSC133Tests.
import Foundation
import Testing

@testable import TerminalCore

/// Pins the shipped shell integrations' emitted dialect to the resize behavior it buys.
struct TerminalShellDialectTests {
    /// A recorded `{feed, resize}` stream in the shared neutral-fixture schema.
    private struct Recording: Decodable {
        let initial: Initial
        let events: [Event]

        struct Initial: Decodable {
            let columns: Int
            let rows: Int
        }

        struct Event: Decodable {
            let type: String
            let hex: String?
            let columns: Int?
            let rows: Int?
        }
    }

    /// A token from the upper prompt row. It is the row a wrong `redraw` value either
    /// erases outright or strands a copy of on every resize step, so it is the one
    /// worth counting; the lower row is rewritten in place either way.
    private static let upperRow = "repo:"

    private func recording(_ name: String) throws -> Recording {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/danterm"
            )
        )
        return try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url))
    }

    /// Replays a recording, optionally rewriting the `redraw` option on every mark in
    /// the stream so a single declaration can be varied against a fixed shell trace.
    private func replay(_ name: String, redrawOverride: String? = nil) throws -> Terminal {
        let recording = try recording(name)
        var terminal = try #require(
            Terminal(columns: recording.initial.columns, rows: recording.initial.rows)
        )
        for event in recording.events {
            guard event.type != "resize" else {
                terminal.resize(columns: try #require(event.columns), rows: try #require(event.rows))
                continue
            }
            var bytes = Self.bytes(fromHex: try #require(event.hex))
            if let redrawOverride {
                var text = String(decoding: bytes, as: UTF8.self)
                for existing in ["redraw=1", "redraw=last", "redraw=0"] {
                    text = text.replacingOccurrences(of: existing, with: redrawOverride)
                }
                bytes = Array(text.utf8)
            }
            terminal.feed(bytes)
        }
        return terminal
    }

    private func promptCopies(in terminal: Terminal) -> Int {
        terminal.fullHistoryText.components(separatedBy: Self.upperRow).count - 1
    }

    private static func bytes(fromHex hex: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex,
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    @Test("the recorded staircase incident is fixed by the redraw declaration and only by it")
    func fishStaircaseNeedsTheDeclaration() throws {
        // Intent: on the exact byte stream that produced the original resize staircase,
        //   declaring `redraw=1` leaves one prompt and declaring `redraw=0` leaves many.
        // Why it exists: this is the incident the whole dialect was built to fix, and it
        //   is the only recording here that discriminates the redraw value for a
        //   whole-prompt-repainting shell. The three files are the same fish + Starship
        //   sweep differing only in the option on fish's own `A`, so any difference in
        //   the outcome is attributable to that option alone.
        // Scenario: a split pane animating open or closed, one resize per layout pass,
        //   against a prompt whose right-aligned segment is padded to the pane width.
        let asRecorded = try replay("fish-staircase-asis")
        let declared = try replay("fish-staircase-redraw1")
        let suppressed = try replay("fish-staircase-redraw0")

        #expect(promptCopies(in: asRecorded) == 1)
        #expect(promptCopies(in: declared) == 1)
        // The staircase is a copy per resize step, so any large number states it; the
        // exact count is a property of the recording's length, not of the contract.
        #expect(promptCopies(in: suppressed) > 10)
        expectValidGrid(declared)
        expectValidGrid(suppressed)
    }

    @Test(
        "a width sweep over each shipped integration's real output leaves exactly one prompt",
        arguments: ["zsh", "bash", "fish"]
    )
    func shippedEmittersSurviveAWidthSweep(_ shell: String) throws {
        // Intent: the dialect as actually emitted by danterm.{zsh,bash,fish} survives a
        //   40-step width sweep with exactly one prompt left in history.
        // Why it exists: guards the shipped emitters, not the parser. A mechanism change
        //   that silently stopped emitting -- a hook losing its slot to a prompt
        //   framework, a `PS1` wrap that a framework overwrites -- would show up here.
        // Scenario: each recording is a live PTY session with the integration sourced and
        //   Starship loaded, resized one column at a time from 100 down to 60.
        let terminal = try replay("\(shell)-dialect-width-sweep")
        #expect(promptCopies(in: terminal) == 1)
        expectValidGrid(terminal)
    }

    @Test("Bash's redraw=last is what keeps its upper prompt row alive")
    func bashRequiresRedrawLast() throws {
        // Intent: on Bash's recorded stream, `redraw=last` leaves the upper prompt row
        //   intact while `redraw=1` and an absent declaration both destroy it.
        // Why it exists: the redraw mode is a promise about what the shell will repaint,
        //   and readline repaints only the final prompt line. Promising the whole block
        //   blanks rows readline never rewrites. Emitting nothing is equally destructive
        //   because the parser's default is `full` -- for Bash the declaration is
        //   load-bearing rather than a hedge, which is easy to get backwards.
        // Scenario: resizing a pane at a two-row Bash prompt.
        #expect(promptCopies(in: try replay("bash-dialect-width-sweep")) == 1)
        // `k=i` is a row stamp with no redraw option, i.e. the declaration removed while
        // everything else about the stream is held fixed.
        #expect(promptCopies(in: try replay("bash-dialect-width-sweep", redrawOverride: "k=i")) == 0)
        #expect(
            promptCopies(in: try replay("bash-dialect-width-sweep", redrawOverride: "redraw=1")) == 0
        )
    }

    @Test("resizing while a command runs leaves its output untouched")
    func resizeDuringOutputPreservesIt() throws {
        // Intent: after `C`, a resize blanks nothing, so a running command's output and
        //   the prompt above it both survive a width change.
        // Why it exists: blanking is scoped to the prompt block, and `C` is the only
        //   thing telling the parser that block has ended. Without it a resize mid-command
        //   would blank the prompt block out from under a running program.
        // Scenario: the user resizes the window while a build streams output.
        for shell in ["zsh", "bash"] {
            let recording = try recording("\(shell)-dialect-width-sweep")
            var terminal = try #require(Terminal(columns: 100, rows: 10))
            terminal.feed(Self.bytes(fromHex: try #require(recording.events[0].hex)))
            terminal.feed(Array("\u{1B}]133;C\u{7}BUILD-OUTPUT-LINE\r\n".utf8))
            for width in [96, 92, 88, 84] {
                terminal.resize(columns: width, rows: 10)
            }
            #expect(
                terminal.fullHistoryText.components(separatedBy: "BUILD-OUTPUT-LINE").count - 1 == 1,
                "\(shell)"
            )
            #expect(promptCopies(in: terminal) == 1, "\(shell)")
        }
    }

    @Test("a stale-width repaint strands no prompt head, and clearing it spares history")
    func staleWidthRepaintLeavesNoDebris() throws {
        // Intent: replaying a real drag over a real zsh prompt leaves exactly one prompt
        //   head on screen, while the earlier shell's prompt and the command typed at it
        //   survive untouched above it.
        // Why it exists: a shell handed a prompt string rendered for the previous width
        //   wraps it over two rows, then repaints from one row lower and erases from
        //   there, leaving the wrapped head stranded one row above the newest stamp.
        //   Anchoring the resize blanking on the first stamp found never looks above it,
        //   so the debris survived every later resize. The second expectation is the
        //   other half of the fix: the climb that reaches the debris must stop at a
        //   continuation row, or it walks into the previous prompt and eats the user's
        //   command line.
        // Scenario: the 2026-07-31 report -- a fish pane, `zsh` typed at it, then the
        //   window dragged narrower, leaving a truncated prompt fragment floating above
        //   the live prompt. Recorded from the live pane rather than reconstructed,
        //   because no synthetic resize burst reproduced it.
        let terminal = try replay("zsh-stale-width-repaint")

        #expect(terminal.screenText.components(separatedBy: "╭ ~").count - 1 == 1)
        #expect(terminal.screenText.contains("╰ $ zsh"))
        expectValidGrid(terminal)
    }
}
