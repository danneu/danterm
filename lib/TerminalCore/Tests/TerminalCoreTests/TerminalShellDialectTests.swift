// Behavioral proof for the OSC 133 dialect that DanTerm's bundled shell integrations
// emit (`research/24/D0`). Everything here replays a live PTY
// recording of a real shell rather than hand-written marks, so the dialect is pinned
// to what `integrations/shell-integration/danterm.{zsh,bash,fish}` actually produce
// in front of a real prompt framework. Two kinds of recording live here and they
// answer different questions: the `fish-staircase-*` trio reproduces the original
// incident and discriminates the `redraw` value, while the `*-dialect-width-sweep`
// recordings guard the shipped emitters against regressing. Parser-level unit cases
// for the marks themselves stay in TerminalOSC133Tests.
import Foundation
import Testing
import TerminalCoreRecording

@testable import TerminalCore

/// Pins the shipped shell integrations' emitted dialect to the resize behavior it buys.
struct TerminalShellDialectTests {
    /// A token from the upper prompt row. It is the row a wrong `redraw` value either
    /// erases outright or strands a copy of on every resize step, so it is the one
    /// worth counting; the lower row is rewritten in place either way.
    private static let upperRow = "repo:"

    /// Decodes a fixture without replaying it. `NeutralTerminalRecording.replay` is deliberately
    /// not used: several of these recordings carry free-form `provenance.source` strings that
    /// `NeutralTerminalProvenance.validate()` rejects, and the redraw-override variants have to
    /// rewrite the feed bytes between the decode and the terminal anyway.
    private func recording(_ name: String) throws -> NeutralTerminalRecording {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/danterm"
            )
        )
        return try JSONDecoder().decode(NeutralTerminalRecording.self, from: Data(contentsOf: url))
    }

    /// Replays a recording, optionally rewriting the `redraw` option on every mark in
    /// the stream so a single declaration can be varied against a fixed shell trace.
    private func replay(_ name: String, redrawOverride: String? = nil) throws -> Terminal {
        let recording = try recording(name)
        var terminal = try #require(
            Terminal(columns: recording.initial.columns, rows: recording.initial.rows)
        )
        for (eventIndex, event) in recording.events.enumerated() {
            let context = "\(name) transformed event \(eventIndex)"
            try Self.apply(event, to: &terminal, redrawOverride: redrawOverride, context: context)
            expectSemanticPromptInvariants(terminal, context: context)
        }
        return terminal
    }

    private func promptCopies(in terminal: Terminal) -> Int {
        terminal.fullHistoryText.components(separatedBy: Self.upperRow).count - 1
    }

    /// Drives one recorded event into `terminal`, optionally rewriting the `redraw` option in a
    /// feed's bytes first. Every event kind these fixtures do not contain is a hard failure rather
    /// than a skip -- silently ignoring an input or viewport event would change what the replayed
    /// stream means without changing any assertion.
    private static func apply(
        _ event: NeutralTerminalRecordingEvent,
        to terminal: inout Terminal,
        redrawOverride: String?,
        context: String
    ) throws {
        switch event {
        case .resize(let columns, let rows):
            terminal.resize(columns: columns, rows: rows)
        case .feed(let bytes):
            terminal.feed(overriding(redrawOverride, in: bytes))
        case .write, .input, .paste, .focus, .mouse, .viewport, .checkpoint:
            throw ShellDialectFixtureError.unsupportedEvent(context)
        }
    }

    private static func overriding(_ redrawOverride: String?, in bytes: [UInt8]) -> [UInt8] {
        guard let redrawOverride else { return bytes }
        var text = String(decoding: bytes, as: UTF8.self)
        for existing in ["redraw=1", "redraw=last", "redraw=0"] {
            text = text.replacingOccurrences(of: existing, with: redrawOverride)
        }
        return Array(text.utf8)
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

    @Test("zsh's redraw declaration is what keeps its sweep down to one prompt")
    func zshRequiresTheDeclaration() throws {
        // Intent: on a zsh stream that actually strands rows, declaring `redraw=1` leaves
        //   one prompt and suppressing it leaves a staircase.
        // Why it exists: `zsh-dialect-width-sweep` guards the emitter but cannot discriminate
        //   the redraw value -- replaying it with `redraw=0` still leaves one prompt, because
        //   a settled sweep that drains each repaint before the next resize never strands
        //   anything. So the zsh half of the contract was pinned by nothing, and a change
        //   that dropped zsh's declaration would have passed the whole suite.
        // Scenario: a fast width drag against a two-row Starship prompt whose right-aligned
        //   segment is padded to the pane width -- one SIGWINCH per column, 100 down to 48,
        //   with only a short drain between steps, which is what a real drag does.
        #expect(topPromptRows(in: try replay("zsh-redraw-discriminator")) == 1)
        #expect(topPromptRows(in: try replay("zsh-redraw-discriminator", redrawOverride: "redraw=1")) == 1)
        // A copy per stranding step, so the magnitude is the claim and the exact count is a
        // property of the recording's length.
        #expect(topPromptRows(in: try replay("zsh-redraw-discriminator", redrawOverride: "redraw=0")) > 10)
        expectValidGrid(try replay("zsh-redraw-discriminator"))
    }

    @Test("fish's redraw value is what keeps its sweep down to one prompt")
    func fishRequiresTheDeclaredValue() throws {
        // Intent: on a sweep against fish running the shipped integration, `redraw=1`
        //   leaves one prompt and either other value leaves a staircase.
        // Why it exists: what was unpinned for fish is the declared *value*.
        //   `fishStaircaseNeedsTheDeclaration` covers the incident but predates the
        //   emitter -- its variants append an option to fish's *native* `A`, so it pins
        //   the parser's response rather than `danterm.fish` -- and
        //   `fish-dialect-width-sweep` cannot discriminate, because a settled sweep that
        //   never strands a row leaves one prompt at any value. Note the mark's absence
        //   is *not* what this catches: the parser defaults to `full`, so deleting the
        //   line renders identically here. The declaration earns its place because the
        //   mode is per-pane state that outlives the shell that set it -- `redraw=last`
        //   below is what a nested Bash leaves behind on exit, and re-declaring per
        //   prompt is what takes it back.
        // Scenario: fish with `danterm.fish` sourced over the maintainer's real config,
        //   swept 100 down to 70 in a 12-row pane -- short enough that stranded copies
        //   scroll into history rather than being overwritten in place.
        #expect(topPromptRows(in: try replay("fish-redraw-discriminator")) == 1)
        #expect(
            topPromptRows(in: try replay("fish-redraw-discriminator", redrawOverride: "redraw=1"))
                == 1
        )
        // Only DanTerm's mark carries a redraw option -- fish's own `A` declares
        // `click_events=1` -- so an override moves exactly the byte under test. A copy per
        // stranding step, so the magnitude is the claim, not the exact count.
        #expect(
            topPromptRows(in: try replay("fish-redraw-discriminator", redrawOverride: "redraw=0"))
                > 10
        )
        #expect(
            topPromptRows(in: try replay("fish-redraw-discriminator", redrawOverride: "redraw=last"))
                > 10
        )
        expectValidGrid(try replay("fish-redraw-discriminator"))
    }

    /// Counts this prompt's top row by the box-drawing glyph that opens it, which is the
    /// row a stranded copy leaves behind. `upperRow` cannot serve: the right-aligned
    /// segment it keys on is dropped by the prompt framework at narrow widths, so it
    /// undercounts exactly where the staircase is worst.
    private func topPromptRows(in terminal: Terminal) -> Int {
        terminal.fullHistoryText.components(separatedBy: "\u{256D}").count - 1
    }

    @Test("a drag across shell transitions leaves every prompt whole and at the left margin")
    func promptSPOverflowSurvivesAShellTransitionDrag() throws {
        // Intent: replaying a drag that spans entering and leaving two subshells leaves
        //   each prompt head at column 0 with exactly one tail, at every width the drag
        //   passed through.
        // Why it exists: fish and zsh advance a line by overflowing one -- the PROMPT_SP
        //   hack pads to the right margin and lets the terminal's wrap do the newline
        //   (`references/fish-shell/src/screen.rs#abandon_line_string`). Padded for a
        //   width a drag has already taken away, that padding really wraps, and the
        //   padded row was left claiming the prompt below it as its own continuation;
        //   reflow then spliced the padding in front of the prompt on every later
        //   resize. Only a recording covers this: the artifact needs a shell whose width
        //   is stale by a specific amount at one specific instant.
        // Scenario: the maintainer entered bash, exited, entered zsh, exited, and dragged
        //   the pane's width throughout. The fish prompt above the `zsh` command came
        //   back indented, with its right-aligned segment re-wrapped onto a row of its
        //   own, and stayed that way.
        let terminal = try replay("fish-prompt-sp-overflow")
        let lines = terminal.fullHistoryText.components(separatedBy: "\n")

        // Before the fix one head arrived as "   \u{256D} ~" -- indented by the columns the
        // stale-width padding overflowed by.
        #expect(lines.allSatisfy { !$0.contains("\u{256D}") || $0.hasPrefix("\u{256D}") })
        // Every head has exactly one tail. A repaint that strands a fragment adds a head
        // without one, which the indent check alone cannot see.
        #expect(topPromptRows(in: terminal) == promptTails(in: terminal))
        expectValidGrid(terminal)
    }

    /// The closing glyph of this prompt's lower row, counted against `topPromptRows` so a
    /// stranded head -- a copy with no input row under it -- shows up as an imbalance.
    private func promptTails(in terminal: Terminal) -> Int {
        terminal.fullHistoryText.components(separatedBy: "\u{2570}").count - 1
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
            try Self.apply(
                recording.events[0],
                to: &terminal,
                redrawOverride: nil,
                context: "\(shell)-dialect-width-sweep event 0"
            )
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

    @Test("a drag that ends on the stranding repaint still strands nothing", arguments: [213, 390])
    func staleWidthDebrisSurvivesNoFollowingResize(_ limit: Int) throws {
        // Intent: cutting the same recording off right after the repaint pair that
        //   strands a head leaves one head, not two.
        // Why it exists: the first fix cleared the debris only from the resize path, so
        //   it depended on the user dragging *past* the stranding repaint. A drag that
        //   stops on it -- the ordinary case, since the last repaint is the one that
        //   matters -- left the artifact on screen with nothing scheduled to remove it.
        //   Clearing at the moment the new head is stamped is what closes that, and this
        //   is the cut point that tells the two fixes apart.
        // Scenario: the maintainer's second report, on a build that already carried the
        //   resize-path fix: same fragment, drag released as the prompt settled.
        let recording = try recording("zsh-stale-width-repaint")
        var terminal = try #require(
            Terminal(columns: recording.initial.columns, rows: recording.initial.rows)
        )
        for (eventIndex, event) in recording.events.prefix(limit).enumerated() {
            let context = "zsh-stale-width-repaint prefix event \(eventIndex)"
            try Self.apply(event, to: &terminal, redrawOverride: nil, context: context)
            expectSemanticPromptInvariants(terminal, context: context)
        }

        #expect(terminal.screenText.components(separatedBy: "╭ ~").count - 1 == 1)
        #expect(terminal.screenText.contains("╰ $ zsh"))
        expectValidGrid(terminal)
    }

    @Test("a narrowing drag does not walk the prompt down the pane")
    func staleWidthRepaintDoesNotAccumulateBlankRows() throws {
        // Intent: after a continuous narrowing drag, the reprinted prompt sits directly
        //   under the command that started the shell, with no blank rows between.
        // Why it exists: every stale-width overflow costs the prompt one row -- the shell
        //   repaints one row lower and never reclaims the row it left. Clearing that row
        //   in place traded a visible fragment for a blank line, so a drag accumulated
        //   one blank per overflow and the prompt visibly walked down the pane. The rows
        //   have to be removed, not emptied.
        // Scenario: the maintainer's third report, on a build carrying both earlier
        //   fixes: no fragment, but eight blank rows between the prompts.
        let terminal = try replay("zsh-stale-width-prompt-drift")
        let lines = terminal.screenText.split(separator: "\n", omittingEmptySubsequences: false)
        let command = try #require(lines.firstIndex { $0.hasPrefix("╰ $ zsh") })
        let head = try #require(lines.lastIndex { $0.hasPrefix("╭ ~") })

        #expect(head == command + 1)
        expectValidGrid(terminal)
    }

    @Test("stacked one-row prompts are history, not debris")
    func oneRowPromptsAreNotTreatedAsDebris() throws {
        // Intent: a single-row prompt entered repeatedly with no output stacks prompt
        //   rows directly on each other; a resize blanks only the live one.
        // Why it exists: the stale-head cleanup walks up over adjacent prompt heads, and
        //   keying that walk on adjacency alone erased the two prompts above -- real
        //   history, silently. Debris is distinguishable because it exists only by
        //   overflowing the width, so it is always soft-wrapped; these are not.
        // Scenario: pressing Enter at an empty prompt a few times, then resizing.
        var terminal = try #require(Terminal(columns: 20, rows: 8))
        for index in 1...3 {
            terminal.feed(Array("\u{1B}]133;A;redraw=1\u{7}$ cmd\(index)\u{1B}]133;B\u{7}\r\n".utf8))
        }
        terminal.resize(columns: 18, rows: 8)

        #expect(terminal.screenText.contains("$ cmd1"))
        #expect(terminal.screenText.contains("$ cmd2"))
        expectValidGrid(terminal)
    }
}

/// Signals a fixture event kind this suite has no meaning for, so the replay fails loudly
/// instead of silently dropping it.
private enum ShellDialectFixtureError: Error {
    case unsupportedEvent(String)
}
