# 2026-08-06: The Swift Terminal Engine -- Migration Record and Decision Register

- Status: Accepted
- Date: 2026-08-06
- Supersedes: [2026-07-20: Terminal Engine Experiment Decision (Milestone 5)](2026-07-20-terminal-engine-experiment-decision.md)
- Supersedes: [2026-05-27: Terminal Focus and Display Link Recovery](2026-05-27-terminal-focus-display-link.md)

<!-- docs-lint: allow-missing plan-terminal-engine/ -->

This note is the terminal engine's decision register. It replaced the
`plan-terminal-engine/` planning directory when the engine left the plan state
ahead of 0.1.0; that directory was deleted on 2026-08-12 once every claim it
still carried was either a row below or dead with the migration. This register
is **live**: a decision here is amended in place when the engine's behavior
changes. It is not a frozen historical record, and the milestone roadmap it grew
out of is not preserved -- see git history for both.

### Keeping the register honest

A decision changes by **amending its row's text**, dated, not by flipping its
status and leaving stale wording behind:

- Reversing a `rejected` row is a new decision with a new rationale. Rewrite the
  row to state what is now done and why the earlier rejection no longer holds,
  keeping the original rationale in a trailing `Superseded YYYY-MM-DD:` clause.
  A rejection that silently becomes `live` destroys the reason it existed.
- Satisfying a `deferred` row rewrites it as the contract that shipped.
- Contradicting a `live` row is a decision change and amends this document in
  the same commit as the code.
- A `spent` row is never revived. It describes a world that no longer exists.
- A row that never bound anything -- a truism, or a restatement of another row --
  is removed rather than amended, and the removal commit says what subsumes it.
  **Ids are never renumbered**, because code and other documents cite them, so
  removal leaves a gap. A gap means "removed as non-binding", not "never
  considered": check git history before re-proposing an idea whose id is missing.

## Context

DanTerm depended on libghostty for terminal semantics, PTY ownership, input,
and rendering. Waiting on upstream releases delayed fixes, and upstream runtime
behavior could conflict with DanTerm's macOS power requirements. The project
chose to own a terminal engine whose supported behavior is explicit, testable,
and released on DanTerm's own schedule rather than an upstream one.

The work ran on an isolated `experiment/swift-terminal-engine` branch through
ten milestones. Both backends implemented one narrow DanTerm-facing boundary
during development, an explicit interactive viability gate at Milestone 4
forced a continue-or-abandon decision at Milestone 5, and libghostty was removed
outright at Milestone 10: no Zig, no xcframework, no GhosttyKit, no
`DANTERM_TERMINAL_BACKEND`, no fallback. Ghostty survives only as a gitignored
reference checkout under `references/`, alongside nine other emulators.

**Milestone 9 never closed as one composite gate.** Removal proceeded ahead of
it by owner decision, and its "no required fallback to Ghostty" criterion closed
by construction rather than by evidence.

Section L is therefore the **contract proved layer by layer**, not one proven
gate. Most of the scheduling contract has maintained deterministic coverage --
unchanged visible terminals publish no recurring frames, hidden panes keep
terminal/semantic/inspection/recovery state current without rendering and then
reveal one complete frame, stalled consumers coalesce into bounded pending work
retaining final state, and recovery traces prove freshness, retry, and
quiescence.
[docs/evidence/2026-08-06-milestone-9-power-performance.md](../evidence/2026-08-06-milestone-9-power-performance.md)
records a pass on the maintained idle, hidden-pane, visible-output,
recovery-freshness, system-sleep, responsiveness, and teardown gates. Three
seams the register once listed as unproved closed there: sleep/wake, which now
has a production `NSWorkspace` adapter, `WorkspaceLifecycleObserver` in
`app/AppPresentationLifecycle.swift`; application-runtime teardown; and
sustained-output responsiveness, which is proved as input ordering and still not
as a latency bound, because no number defines "interactive" (see Open
questions). The three 2026-08-06 rows in the **Proof record** below say what
each of those gates executes and which of them `just test` runs.

One seam remains unproved: **sparse-clip topology** can be measured as
whole-process CPU but has no frozen rule letting the workload issue a verdict.
[plans/impl/2026-08-06-1143-m9-power-performance-gates.md](../../plans/impl/2026-08-06-1143-m9-power-performance-gates.md)
owns closing it and is the authority on its current state.

## Decision

The decisions below are the engine's acceptance standard. Cite one as
`docs/design/2026-08-06-swift-terminal-engine.md D5`.

Status values:

- **live** -- binding on the code; this document is its owner
- **elsewhere** -- binding, but another document or row owns it; this row is a
  pointer
- **spent** -- true as history, describes a world that no longer exists
- **deferred** -- a decision *not* to do something for now
- **rejected** -- an alternative considered and declined

### A. Product scope and compatibility

| id | Decision | Status |
|---|---|---|
| A1 | The engine is a DanTerm-internal component used by the macOS app and the in-repo iOS client, not a general-purpose terminal framework or reusable public API. The iOS client consumes the engine packages without changing that ownership boundary (research/35/D3). | live |
| A2 | The compatibility target is a finite, priority-ordered list: zsh/bash/fish, ssh, tmux, vim/neovim, fzf, more/less, btop/htop, lazygit, Claude Code, Codex. | live |
| A3 | Apple frameworks are allowed without justification; a third-party dependency is admitted only when its benefit outweighs its release, security, maintenance, and integration cost. | live |
| A4 | Existing terminal implementations inform design and serve as test references, but none is normative. Protocol specifications and the DanTerm contract decide intended behavior; reference emulator output is evidence, not authority. Accepted risk: differential testing can reproduce a reference's bugs. | live |
| A5 | The supported terminal contract is finite and documented; unsupported legacy behavior is not silently treated as a future requirement. | live |
| A6 | Product behavior outside the terminal surface -- tabs, groups, splits, alerts, persistence, IPC -- stays owned by DanTerm and unchanged by the backend swap. | live |
| A7 | A pane that cannot create its terminal process fails through DanTerm's existing pane lifecycle rather than leaving a ghost pane. | live |
| A8 | Accepted risk: the initial support matrix is narrower than mature emulators, on the grounds that explicit compatibility can grow from measured need. | live |
| A9 | Out of scope: bidirectional/RTL layout, terminal image protocols, VoiceOver, ligatures, and preserving or reconnecting to child processes across restart. | deferred |

### B. Architecture and ownership

| id | Decision | Status |
|---|---|---|
| B1 | Functional-core / imperative-shell, with Elm-style reduction at control boundaries. | live |
| B2 | Terminal semantics and pane-lifecycle decisions are synchronous deterministic transitions producing ordered effects as values; they may mutate exclusively owned state in place. | live |
| B3 | One serialized owner per pane applies transitions and interprets their effects. Each pane has exactly one mutable terminal and lifecycle owner; consumers receive read-only state. | live |
| B4 | That owner is a Swift actor bound to a serial dispatch-queue executor; read-only consumers receive `Sendable` terminal value snapshots. | live |
| B5 | High-volume data -- PTY byte batches, grid state, render damage -- never enters DanTerm's top-level Elm model or command loop. Only product-level events (title, cwd, bell, notification, process exit, creation failure) reach the model. | live |
| B6 | Effectful boundaries separate deterministic policy from system mechanism wherever meaningful policy exists: keyboard, paste, mouse, PTY, rendering, power, links. | live |
| B7 | A direct deterministic system operation with no meaningful policy does not get an artificial abstraction solely for mocking. A witness is allowed only when the system boundary is genuinely nondeterministic, that nondeterminism participates in an ownership or lifecycle invariant, and no production input can drive it deterministically. Its production implementation is stateless and semantically identical to the direct operation, and substitution stays in the owning package's test target. *Amended 2026-08-13:* the earlier rule did not admit nondeterministic lifecycle boundaries whose failure cases need deterministic proof. | live |
| B8 | Deterministic policy performs no IO and reads no ambient clock, process, AppKit, font, display, clipboard, or workspace state. | live |
| B9 | Framework adapters normalize inputs or execute decisions; they never silently redefine engine policy. | live |
| B10 | DanTerm has **one concrete terminal runtime**. The process-wide multi-backend abstraction was deleted with libghostty, but the narrow per-session `TerminalSession` protocol survives deliberately as the AppKit boundary that pane containers, the reconciler, and UI test doubles all speak. Terminal handles, bytes, grids, and rendering stay out of it. Substitution is per-session for UI testing, not a backend-selection seam. | live |
| B11 | Accepted risk: pure policy tests cannot prove macOS framework behavior, so narrow real-system tests remain required at every Apple-framework and PTY seam. | live |
| B12 | Rejected: immutable copying of the screen or scrollback after every transition. | rejected |
| B13 | Rejected: routing terminal bytes or cell mutations through DanTerm `Msg` values. | rejected |
| B14 | Rejected: concurrency inside the terminal semantics reducer. | rejected |

### C. Terminal core semantics

| id | Decision | Status |
|---|---|---|
| C1 | The core is a synchronous state machine over bytes plus explicit inputs, producing output bytes, damage, and semantic effects. PTY IO, scheduling, rendering, and AppKit live outside it. | live |
| C2 | Supported surface: primary and alternate screens; cursor movement, wrapping, tabs, margins, scrolling regions; insertion, deletion, erasure, background-color erase; DECSCA character protection with the selective erases DECSED and DECSEL that honor it; saved cursor and modes; 7-bit GL character sets; 16-color, 256-color, and RGB presentation; bold, dim, italic, underline and underline color, reverse, hidden, strike; cursor style and the requested blink preference; synchronized updates; device, cursor, and mode queries needed for feature detection. | live |
| C3 | Unknown, malformed, canceled, or truncated sequences never poison subsequent input. | live |
| C4 | Input chunk boundaries do not change behavior. | live |
| C5 | Alternate-screen content never enters normal scrollback. | live |
| C6 | Synchronized updates suppress intermediate presentation without suppressing final state changes. | live |
| C7 | Query replies report only capabilities the engine actually implements. | live |
| C8 | Out of scope: VT52, printer, Tektronix, and terminal graphics emulation. | deferred |
| C9 | Character sets are the 7-bit GL half of ISO 2022 in full: ASCII, DEC Special Graphics, and UK, designated into G0-G3 and invoked by SI/SO, LS2/LS3, and SS2/SS3. There is no GR bank, because the UTF-8 decoder consumes every byte at or above 0x80 before charset logic could see it, so GR state could never be observed. An unrecognized designation -- an unknown final, or extra intermediates such as `ESC ( % 5` -- designates ASCII rather than leaving the slot stale, because no program can query charset state and stale line drawing is worse than deterministic plain text. The DEC Special table matches xterm on all of 0x60-0x7E and keeps 0x5F identity, which is ghostty's choice where xterm's wide build maps it to U+2426. | live |

### D. Unicode, grid, and scrollback

| id | Decision | Status |
|---|---|---|
| D1 | The extended grapheme cluster is the indivisible user-visible unit. Terminal width is protocol state, not a measurement of the chosen glyph. Grapheme clustering is unconditional, so DECRQM reports DEC private mode 2027 as permanently set; the behavior and advertised status must change together. *Amended 2026-08-21:* the engine previously clustered unconditionally but reported mode 2027 as unrecognized. | live |
| D2 | Width rules: zero-width marks extend their cluster; narrow clusters occupy one cell; East Asian Wide and Fullwidth occupy two; **East Asian Ambiguous occupies one by default**; supported emoji occupy a stable width and render through macOS font fallback. | live |
| D3 | Private Use Area glyphs, including Nerd Font glyphs, are ordinary font glyphs. No separate Nerd Font protocol is required. | live |
| D4 | Unicode behavior is pinned to a specific Unicode data version so width and segmentation cannot drift silently between releases. | live |
| D5 | Scrollback has a fixed **16 MiB per-pane** storage budget (`Terminal.scrollbackByteLimit`). The active viewport is outside that budget. | live |
| D6 | Scrollback preserves the difference between hard line endings and soft wraps, so content reflows when a pane changes width. | live |
| D7 | Primary-screen resize reflows retained history and active rows as one ordered sequence of logical lines. Trailing never-written blank rows are layout data and keep their count across width changes; wrap growth displaces rows into history instead of consuming those blanks, and widening pulls the displaced rows back before adding new padding. The history/live seam is derived from that one stream, so an unchanged width round trip restores the layout without resize-series state. Cursor visibility bounds blank preservation: if the reflowed cursor would land above the viewport, resize removes only the trailing blanks needed to show it. The cursor otherwise stays attached to the same logical cell boundary, including explicit blank cells, with the existing per-width column clamp. Explicit browsing keeps its content anchor, and a bottom-row cursor remains the zero-trailing-blank bottom-follow case. This follows the structural model used by alacritty, tmux, and iTerm2. Resize runs in two ordered stages: the live cursor alone decides the resulting layout, and the DECSC slot is then mapped through the displacement or reflow that layout produced, by the same attachment rules -- same logical cell, line boundary for a pending wrap, trailing-padding distance for a position past the content. Two fallbacks cover a saved position with no cell to follow: a row that left the active area takes the live cursor's off-screen policy (row 0, column kept, then the usual clamp), and a position on a never-written blank row keeps its row offset below the content. *Amended 2026-08-13:* the resize-series fallback preserved a remembered layout only across selected consecutive events; preserving blank rows makes each width change information-preserving by construction. | live |
| D8 | At the live bottom, height shrink moves displaced rows into scrollback and growth pulls the newest eligible primary rows back before adding blank rows. | live |
| D9 | Resize never duplicates or discards logical content, except through ordinary 16 MiB eviction or OSC 133 prompt/input rows blanked before reflow when the shell has promised to redraw them after SIGWINCH. | live |
| D10 | Alternate-screen resize does not reflow and never contributes rows to primary history. Cells retain coordinates; shrink discards cells outside the rectangle and clears a grapheme or wide cell as a whole; growth adds blanks; cursors clamp without landing on a wide-cell tail; margins reset to the full grid. | live |
| D11 | Eviction removes oldest content at valid grapheme boundaries. A single logical line larger than the budget may lose its oldest prefix, but retained content stays valid and is marked truncated. | live |
| D13 | Every grid mutation leaves a wide cell and a grapheme cluster whole. Overwrite, erase, insert, delete, scroll, and reflow rewrite or clear both halves of a wide pair together and never strand a combining mark, so no mutation can produce an orphaned half-cell. A projected text range starts and ends on a cluster boundary, because the projection trims whole units rather than cells (`Terminal.trimmedLogicalLineRange`). D10 states the alternate-screen resize case and G10 the token-classification case; both specialize this rule. | live |
| D14 | A live grapheme cluster and the matching REP memory retain at most 256 UTF-8 bytes. A joining scalar that would cross the limit is dropped as one whole scalar; segmentation state continues, so later output starts at the correct boundary. This keeps live cells and state-synchronization payloads bounded while preserving at least 64 maximum-width scalars or 127 common two-byte combining marks. Reference behavior disagrees: Alacritty is unbounded (`references/alacritty/alacritty_terminal/src/term/cell.rs#Cell::push_zerowidth`), libvterm exposes six code points (`references/libvterm/include/vterm.h#VTERM_MAX_CHARS_PER_CELL`), and kitty caps cells at 24 to prevent denial of service (`references/kitty/kitty/screen.c#add_combining_char`). Boundedness is DanTerm's contract rather than compatibility with the uncapped case. | live |
| D12 | Out of scope: configurable ambiguous-width or scrollback policies. | deferred |

### E. Logical-text projection (inspection, selection, search, recovery)

| id | Decision | Status |
|---|---|---|
| E1 | The core owns **one** deterministic logical-text projection shared by inspection, selection, search, and persistence, so a resize cannot change IPC output or saved history when logical content did not change. | live |
| E2 | Projection rules: a soft wrap contributes no separator; a hard boundary contributes `\n`; empty right-hand padding and padding-only trailing rows are omitted; spaces written into content are preserved; no final newline is added merely because a viewport or selection ended. | live |
| E3 | Inspection has two explicit ranges: viewport text (logical content intersecting the rows the local viewport selects) and full-history text (retained scrollback plus active rows of the active screen). | live |
| E4 | `danterm pane read` without `--lines` returns viewport text. With `--lines N` it returns the last N newline-delimited **logical lines** of full-history text, not the last N visual rows; `N == 0` returns an empty string; otherwise the source projection's final-newline state is preserved. | live |
| E5 | Search is a literal search over the full-history projection, comparing whole graphemes by Unicode 17.0 canonical caseless keys including root-locale full case folding. Compatibility decomposition and locale-sensitive casing are excluded. | live |
| E6 | Search spans soft wraps but not an unrequested hard newline; it selects the newest match first, navigates toward older matches with Next and newer with Previous, and wraps at either end. | live |
| E7 | Export and enriched recovery checkpoints capture primary-screen full history. Alternate-screen content is transient and is never replayed into a new shell. | live |
| E8 | The pre-existing DanTerm persistence projection remains the compatibility contract and is the explicit exception to space preservation: it trims leading and trailing whitespace from the full text as a whole, omits the result when nothing remains, retains at most 4,000 logical lines and 400,000 grapheme clusters, and stores non-empty replay text with exactly one final newline. | live |
| E9 | Recovery restores plain text only. Terminal modes, presentation attributes, selection, search state, and alternate-screen state are not reconstructed. | live |
| E10 | Enriched recovery freshness is event-driven with bounded coalescing: isolated changes are eventually written, sustained changes cannot postpone a covering checkpoint indefinitely, a mutation stays dirty until a checkpoint covers it, clean termination flushes, and a clean terminal schedules no recurring checkpoint work. | live |
| E11 | The previous backend's inspection and recovery text was captured as a characterization corpus before the runtime reader moved. The recorder is gone; the committed corpus still replays as a gating regression. | live |
| E12 | Out of scope: styled or HTML export; persisting modes, attributes, selection, search state, or the alternate screen; regex, whole-word, or locale-sensitive search. | deferred |

### F. PTY and process lifecycle

| id | Decision | Status |
|---|---|---|
| F1 | DanTerm owns one local PTY session per live terminal pane. The PTY layer is a macOS side-effect boundary for child launch, byte IO, geometry, process-group behavior, exit observation, and cleanup. | live |
| F2 | PTY children launch through **`posix_spawn` plus a tiny single-threaded bootstrap** (`PTYSessionBootstrap`) that establishes the child session, controlling terminal, foreground process group, standard streams, cwd, and final `execve` -- never forking the multithreaded app process. | live |
| F3 | An ordinary interactive pane launches the user's account shell from the macOS account database as a login shell, with `/bin/zsh` then `/bin/sh` as fallbacks. Its `argv[0]` has the login shell form and it receives no additional shell arguments. | live |
| F4 | The child working directory is the pane's requested directory when it exists and is accessible, otherwise the account home directory, otherwise `/`. | live |
| F5 | The child inherits the app process environment; the advertised terminal variables and pane-scoped `DANTERM_*` values set by DanTerm override inherited values. | live |
| F6 | `--cmd`, restore prefill, restore execute, and recovery replay send initial **input to the login shell** exactly once, with their specified execute-versus-prefill newline behavior. They never become a different process-launch mode. | live |
| F7 | Closing a pane never deliberately detaches the session: DanTerm hangs up the PTY and terminates every process remaining in the owned session -- foreground, background, stopped, and hangup-resistant -- escalating from ordinary hangup to forced termination after bounded grace periods. Orderly application termination applies the same bounded teardown to every live pane, and closing one pane never touches a sibling session. | live |
| F8 | A process that deliberately daemonizes out of the owned session is outside this contract. | live |
| F9 | When the shell exits on its own, the PTY layer reports its status once and the session-keyed `sessionEnded` update decides the resulting pane, tab, and last-window behavior. There is no new process-exited holding state. | live |
| F10 | DanTerm does not preserve or reconnect to child processes across a restart; a restart creates new processes and may replay saved scrollback. | live |
| F11 | Background and occluded panes continue consuming PTY output even when they do not render it. | live |
| F12 | Accepted risk: after an abrupt crash, macOS closes the PTY master and ordinary hangup applies, but no in-process escalation can run, so a hangup-resistant background process may be reparented and survive. Accepted to keep session supervision outside the product. | live |
| F14 | Rejected: a process broker, daemon, or session-survival service. | rejected |

### G. Input and interaction

| id | Decision | Status |
|---|---|---|
| G1 | macOS owns text composition. Option remains a native composition modifier so Spanish dead-key sequences work; there is **no Option-as-Alt**. | live |
| G2 | macOS composition has precedence over every terminal keyboard mode. Option is never reinterpreted as terminal Alt while participating in composition; Kitty encoding applies only after text is committed and to non-text key events. | live |
| G3 | Supported key contracts: legacy xterm, application cursor and keypad modes, focus reporting, bracketed paste, and the Kitty keyboard protocol. Kitty is opt-in through its protocol; legacy applications retain legacy behavior. **Focus is retained terminal state, not an edge:** the terminal holds the host's effective focus whether or not mode 1004 is enabled, starts unfocused, and answers every `DECSET 1004` with `CSI I` or `CSI O` for the state it holds right then, as foot does. A focus change while the mode is enabled is transmitted at the moment of the change; a change while it is disabled is retained silently; a change that leaves the state the same writes nothing. Disabling the mode, DECSTR, RIS, and screen switches do not discard retained focus. The host's effective focus is the conjunction of two inputs the host session retains independently -- the terminal view owns pane focus, and DanTerm is the active application -- so a pane that keeps first-responder status across a deactivation reports itself unfocused, and the host sends the derived value only when it changes. Serialized terminal state restates no focus, so anything that rebuilds a terminal from those bytes -- a pane-tape synchronization above all -- carries effective focus beside them and seeds it before feeding the bytes; the reports that reconstruction provokes are the rebuilder's own and are discarded. | live |
| G4 | **Deliberate departure from xterm:** any Return chord holding Shift encodes `LF` (`0x0A`), ESC-prefixed under Alt, in every mode combination including LNM. Shift+Return is an explicit "insert a line feed" affordance so composers that cannot negotiate the Kitty protocol get a newline instead of a submit. Shift-free Return keeps its xterm bytes; Kitty-mode Shift+Return still encodes `CSI 13;2u`. | live |
| G5 | xterm `modifyOtherKeys` is deferred; its set and query sequences stay inert until a prioritized application workflow demonstrably requires it. | deferred |
| G6 | The engine supports local text selection and SGR mouse reporting. When an application has captured mouse input, Shift-left bypasses reporting: with no selection it starts a local selection, outside a settled selection it extends from the fixed opposite endpoint at the settled character, token, or trimmed-line granularity, and inside the selection it leaves the range unchanged for the whole gesture. The canonical start boundary belongs to the before-selection extension arm; the canonical end boundary belongs to the inside-selection no-op region. | live |
| G7 | The local viewport follows the live bottom until the user navigates to older content. While browsing, **the top displayed logical position is the stable anchor**: output and reflow never snap it to the bottom, and eviction clamps it to the oldest retained logical position without re-enabling bottom follow. Only explicit navigation to the newest row re-enables follow. | live |
| G8 | With application mouse reporting active, an unmodified wheel event goes to the application and does not scroll local history; Shift-wheel forces local history navigation and emits no mouse-report bytes; the native scrollbar is always local and never emits terminal mouse input. | live |
| G9 | Search navigation reveals its match without enabling bottom follow, and local scrolling clears neither selection nor search. Content overwritten by output or evicted from history invalidates the affected endpoint or match rather than retargeting it to unrelated text. | live |
| G10 | Click granularity cycles character, terminal token, trimmed logical line. A terminal token is a maximal run of either separators or non-separators. **Separators are every Unicode whitespace scalar plus apostrophe, double quote, U+2502, backtick, pipe, colon, semicolon, comma, parentheses, brackets, braces, angle brackets, and dollar sign** -- period, slash, hyphen, underscore, and equals stay token characters so paths, flags, identifiers, and assignments select as whole runs. Tokens cross soft wraps but not hard boundaries, and classification never splits a grapheme or wide cell. | live |
| G11 | Paste preserves text, tabs, and newlines, removes unsafe control bytes, and uses bracketed-paste markers when the application enables that mode. | live |
| G12 | **OSC 52 writes are allowed up to 1 MiB of decoded content; OSC 52 reads are denied.** This applies equally to local, tmux, and remote applications. | live |
| G13 | OSC 8 hyperlinks and automatic `http://`/`https://` detection are supported. Both explicit and detected links are activatable only when the resolved URL uses `http` or `https`; other schemes remain inert text. Cmd-hover exposes link interaction and Cmd-click opens the resolved URL. | live |
| G14 | File path and source-location navigation is deferred. Removing the previous backend narrowed this visibly: bare file paths are no longer Cmd-clickable. | deferred |
| G15 | Copy-on-select is configurable through `ui.copyOnSelect`, default on. The text is captured atomically with the completing pointer event, so later output cannot change it; consumed gestures and empty selections never copy. Explicit copy uses the current selection and is identical in both modes. | live |
| G17 | A width change preserves a live selection and a live search match. Reflow keeps both attached to the same logical content, together with the selection's granularity, and clamps an endpoint only into retained content; it never clears them. G9 remains the destruction rule and is unchanged: content that output overwrote or eviction removed invalidates the endpoint or match. Alternate-screen resize is the one exception -- it clears inspection outright, because alternate content does not reflow (D10). | live |
| G16 | Out of scope: a multiline-paste confirmation, and clipboard read permission prompts. | deferred |

### H. Renderer, presentation, and configuration

| id | Decision | Status |
|---|---|---|
| H1 | The renderer is an AppKit renderer using CoreText/CoreGraphics and macOS font fallback. **Metal is a possible later renderer, not a dependency.** | live |
| H2 | Rendering separates deterministic planning from Apple-framework execution: given a read-only snapshot and explicit presentation inputs, planning decides the drawing work; CoreText/CoreGraphics resolve and execute glyph and drawing operations. | live |
| H3 | Rendering never changes terminal state or terminal cell width, and font fallback changes glyph choice without changing grid geometry. | live |
| H4 | Damage outside the visible pane causes no drawing work, and a newly visible pane can produce a complete frame from current terminal state. | live |
| H5 | Procedural terminal glyphs follow the sprite system contract. | elsewhere -- [docs/terminal-sprites.md](../terminal-sprites.md) |
| H6 | Presentation defaults, applied when configuration does not override them: macOS monospaced system font at 13 pt normal weight, ligatures disabled, line height derived from font metrics, 16/256/RGB color, a steady block cursor by default, application-requested cursor shapes, selection and hyperlink and underline-style decoration, and Retina-correct geometry. The default theme is Monokai Remastered; remote sessions default to Purplepeter. | live |
| H7 | **DanTerm JSON at `~/.config/danterm/config.json` is the sole configuration authority.** The engine reads no config of its own and no other project's config or theme files. The known schema is `theme.default`, `theme.remote`, `font.family`, `font.size`, and `ui.alertClearMode`. | live |
| H8 | Configuration is projected into **explicit engine inputs** rather than read ambiently inside the engine, so terminal semantics never depend on config lookup and adding a key does not touch the core. | live |
| H9 | The Cmd+, Preferences panel edits the known schema and is a view over the same document, not a second source of truth. Unknown keys in the file are preserved across edits rather than dropped. | live |
| H10 | Config, theme, and keybinding formats are DanTerm-owned and optimized for DanTerm's behavior. Themes from other projects may be translated into the DanTerm catalog; their source formats do not constrain the result. | live |
| H11 | A theme defines presentation only; it can never change parser or PTY behavior. Invalid config cannot leave a pane partially configured. | live |
| H12 | Accepted risk: the correctness-first renderer may use more CPU during heavy visible output than a mature GPU renderer. Behavioral correctness and quiescent idle take priority. | live |
| H13 | Line height remains derived from font metrics and is not configurable. Ligature control is not exposed. | deferred |
| H14 | Rejected: Ghostty config, theme, or keybinding compatibility, and preserving names or semantics solely because another terminal exposes them. | rejected |

### I. Protocols and shell integration

| id | Decision | Status |
|---|---|---|
| I1 | The child environment advertises `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=DanTerm`, and `TERM_PROGRAM_VERSION=<DanTerm version>`. | live |
| I2 | `xterm-256color` is an advertised identity, not a promise to clone xterm. The documented capability contract is normative across supported terminfo variants. | elsewhere -- [docs/terminal-capabilities.md](../terminal-capabilities.md) |
| I3 | A contract change is checked against **two** pinned terminfo baselines -- the minimum supported macOS `xterm-256color` entry and a pinned current ncurses source -- because a single database snapshot is never authoritative. A difference must be added to the contract or shown not to occur in an accepted workflow. This is a rule for whoever edits the contract: the byte-comparison gate that once enforced it was retired, and only the nine key rows are pinned executably. | live |
| I4 | Incompatible contract changes require a new versioned document section, or a new versioned artifact (v2+) if a machine-readable form is ever needed again -- never a revival of the retired v1 JSON manifest. | live |
| I5 | XTVERSION accepts `CSI > q` and `CSI > 0 q` and replies `DCS >|DanTerm <version> ST`, using the same injected bundle version exported as `TERM_PROGRAM_VERSION`. **DA2, DECRQSS, XTGETTCAP, and 8-bit replies remain unsupported.** | live |
| I6 | The notification and progress grammar is deliberately narrow: `OSC 9;<body>` with canonical selectors 1 through 12; `OSC 777;notify;<title>;<body>` retaining later semicolons in the body; and `OSC 9;4;{0,1,2,3,4}` progress forms. Reserved and malformed selector-4 forms are ignored, numeric bodies outside exact selectors 1-12 remain notification text, and **Kitty OSC 99 is ignored**. | live |
| I7 | DanTerm shell integrations use a private, versioned envelope `OSC 1337;DanTermShell=3;<event>[;<arg>...] ST` carrying typed integration-ready, command-start, command-end, and whole-state connection declarations. A connection is local, identity-less remote, or remote with a canonical padded-base64 user and host pair; command text uses the same encoding, and command-end carries a canonical decimal exit status from 0 through 255. The engine validates exact field counts and envelope size before emitting a report tagged with the terminal session's `SessionId`; the model admits bounded metadata and resolves the owning pane from that identity. Version 2 events are ignored outright. | live |
| I8 | Shell events never pass through title handling. | live |
| I9 | Canonical opt-in zsh, Bash, and fish integrations ship in the app bundle. They emit when `DANTERM` or `LC_DANTERM` is present, preserve existing prompt hooks, report local cwd with OSC 7, and have ssh/mosh wrappers forward `LC_DANTERM=1` through `SendEnv`. Every prompt declares the shell's complete connection state: local, or remote with identity when `LC_DANTERM` is present and `DANTERM` is absent. Each wrapper declares identity-less remote before launch, emits nothing afterward, preserves the command's exit status, and relies on the next owning prompt to restore local state or an enclosing remote identity. tmux delivery uses DCS passthrough and depends on the user's existing `allow-passthrough` policy; mosh exposes the near-side declaration because it filters far-side private OSC. | live |
| I10 | Each integration declares an OSC 133 `redraw` mode derived from how that shell actually repaints after SIGWINCH -- `redraw=1` for zsh and fish, `redraw=last` for Bash -- restated on every prompt, because the mode is per-pane terminal state that outlives the shell that set it. The parser default is `full`, so a stamped prompt row with no declaration is an implicit promise to repaint everything. | elsewhere -- [2026-08-01-osc-133-prompt-anchoring.md](2026-08-01-osc-133-prompt-anchoring.md) |
| I11 | The OSC 133 dialect is engine-internal; lifecycle reports travel only on the OSC 1337 envelope, which lets the dialect change for row classification and reflow without changing the model's session-report reducer. Values and lifecycles share one session-owned report vocabulary but keep their distinct reduction rules. | live |
| I12 | BEL emits a session-keyed bell event so a late bell from a dead or replaced session is dropped. **The engine never plays an audible bell.** A transient visual bell is permitted for the focused pane because that pane's normal alert is suppressed while the app is active. | live |
| I13 | Inside tmux, the inner terminal identity remains tmux's responsibility; DanTerm implements the outer capabilities tmux consumes. | live |
| I14 | Rejected: an initial `TERM=danterm` -- remote hosts would need a custom terminfo entry before ordinary applications could rely on it. | rejected |
| I15 | Rejected: Ghostty terminal identity or protocol compatibility as a goal. | rejected |

### J. Per-pane resource and security policy

| id | Decision | Status |
|---|---|---|
| J1 | Untrusted terminal output is bounded **across components**, not only within scrollback. Untrusted output cannot grow retained per-pane state or pending work without an explicit bound. | live |
| J2 | One pending OSC, DCS, APC, PM, or SOS string may contain at most 2 MiB of encoded input; OSC 52 additionally retains its 1 MiB decoded-content limit. | live |
| J3 | One retained title, cwd, link target, complete notification title-plus-body, progress, or typed shell-event payload is limited to 64 KiB. Each layer bounds its own retention independently rather than summing to one aggregate budget: the engine caps its own retention at 256 KiB, and the model caps every terminal-originated field at 64 KiB per value plus at most 100 alerts, so model metadata scales with live pane count rather than a fixed byte bound. | live |
| J4 | Pending terminal query replies are limited to 64 KiB per pane, and replies are admitted or dropped as complete units. | live |
| J5 | Damage is coalesced into bounded active-grid state or a full-redraw marker, never retained as an event-by-event queue. | live |
| J6 | Semantic-event queues have both count and byte bounds. Replaceable title, cwd, and progress values coalesce to their newest complete value; bell, shell, and notification events share a 100-event discrete queue; other excess events are dropped as complete pane-scoped units. | live |
| J7 | When a sequence exceeds its limit, the engine applies **none** of that sequence, consumes through normal termination or cancellation without retaining the discarded payload, and resumes parsing later valid input. PTY ingress may apply backpressure rather than creating an unbounded user-space byte queue. | live |
| J8 | In UTF-8 input mode, OSC, DCS, APC, PM, and SOS payloads own every encoded byte from `0x80` through `0x9f`; raw C1 values never transition or terminate an active string. OSC terminates on BEL or 7-bit ST; the other four families terminate only on 7-bit ST. CAN and SUB cancel every control string. An ESC followed by any byte other than `\` cancels the string without OSC dispatch and restarts escape recognition from that ESC. | live |
| J9 | **DanTerm does not support 8-bit ST, raw C1 introducers, or S8C1T mode.** Raw C1 bytes in ground remain malformed UTF-8, while valid UTF-8 scalars U+0080 through U+009F are consumed without a parser action. Active OSC, DCS, APC, PM, and SOS strings continue to own their bytes before UTF-8 decoding. *Amended 2026-08-21:* decoded C1 scalars previously reached grid reduction as printable content despite the absence of 8-bit C1 support. | live |
| J10 | Semantic consumers validate their own fields atomically: malformed OSC 8 URI bytes and malformed decoded OSC 52 text apply nothing, while malformed OSC 8 parameter bytes may discard the optional ID without invalidating a valid URI. | live |
| J11 | Terminal output carries no host authority of its own. A byte stream -- local, tmux, or remote -- can act on the host only through an affordance a decision here grants explicitly, and every such grant states its own bound. A new protocol that would let output reach the filesystem, the clipboard, another application, or the network is a decision this register must make before it is implemented, not a capability inherited from the sequence being supported. J12 is one such grant, stated explicitly rather than inherited. | live |
| J12 | Every pane in the shipped app records a bounded in-memory **flight tape** of the byte transfers that complete across its own PTY boundary in both directions -- the child output it reads, the input it writes, and the geometry it sets. Input is recorded as transmitted, after encoding, and carries the time its originating event occurred as well as the time the write succeeded, so a delay inside the app is distinguishable from a delay in the child; bytes with no origin outside the pane owner, such as terminal replies, carry no origin stamp. Recording input means a tape can contain what was typed, including input a `sudo` or `ssh` prompt did not echo. Recording is unconditional: no build flag, bundle key, environment variable, or preference can produce a pane without a tape, because a symptom seen once in production has to be explainable without reproducing it first. Every recorded event carries a lifetime sequence number that eviction never reassigns, and every event that carries bytes also carries where those bytes sit in its own direction's lifetime byte stream: the feed and write directions are numbered independently, so an offset always names a position in one real stream rather than in an interleaved total no reader can resolve. Sequence and per-direction byte coordinates are part of the tape contract, which is what lets a reader state exactly which events and which bytes of which direction it never received. The tape is bounded per pane by retained payload and event count and never by age, evicts oldest-first while reporting exact event and per-direction byte loss, exists only in memory, and dies with its pane -- nothing writes captured terminal traffic to disk. Reading it over the local control socket is the J11 grant that lets captured terminal output reach another application from a shipped build; that socket's existing local-only reach is the bound. *Superseded 2026-08-12:* recording was previously a dev-build capability, on the rationale that a production recording surface would put capture of verbatim terminal output one flag away for every user. That rationale assumed users; DanTerm has one, and it cost the one incident this facility exists for. | live |

### K. Testing and conformance

| id | Decision | Status |
|---|---|---|
| K1 | "Fully tested" means every behavior in the declared support matrix has a deterministic behavioral proof **at the lowest appropriate layer**, with integration and real-application evidence for the seams between layers. | live |
| K2 | TDD is the development rule: a new supported behavior begins with a test that fails for the expected reason. | elsewhere -- [AGENTS.md](../../AGENTS.md) |
| K4 | Logical terminal snapshots, not screenshots, prove semantic behavior. Pixel snapshots stay narrowly scoped to geometry and rendering claims logical snapshots cannot prove, because they vary with system fonts. | live |
| K5 | Parser proof requires input-chunk-boundary invariance across representative and exhaustive split points, plus arbitrary-byte fuzzing that demonstrates **recovery to later valid input**, not only absence of crashes. | live |
| K6 | Unicode proof uses pinned official segmentation and width fixtures. | live |
| K7 | Reference emulator output is evidence, not authority. A4 owns this decision and states its accepted risk; cite A4. | elsewhere -- A4 |
| K8 | Every named compatibility application has a fixed minimum user task, defined in **Minimum compatibility workflows** below. Each includes launch, representative input and output, resize while active, and clean exit and teardown, with direct, tmux, and ssh variants where those layers materially change behavior. A compatibility claim is not complete until its input, output, resize, and teardown behavior are exercised. | live |
| K9 | Every externally meaningful limit and security policy has boundary coverage. | live |
| K10 | External corpora are pinned at full commit hashes into ignored build storage, and DanTerm-authored replay commands and report expectations are checked in, so **upstream logs or screens are never accepted as DanTerm truth**. | live |
| K11 | Standing constraints that outlive any milestone: never regenerate-and-auto-accept another emulator's output as DanTerm truth, and do not vendor wraptest until its reuse terms are clear. | elsewhere -- [docs/research/1-external-tests.md](../research/1-external-tests.md) |

#### Minimum compatibility workflows

The acceptance scenario behind A2 and K8. Fixture data, automation, and script
mechanics are implementation discretion; these tasks and outcomes are not.

| Application | Minimum user task and expected outcome |
|---|---|
| zsh, bash, fish (each) | Edit and execute a pipeline, exercise completion and foreground/background/stop/resume job control, and return to a usable prompt. |
| ssh | Connect to a controlled host, run colored and Unicode output, resize the remote session, and disconnect without leaving local ownership behind. |
| tmux | Create a session, split and switch panes, resize, use mouse and copy-mode history navigation, then detach or exit with the outer terminal restored. |
| vim, neovim (each) | Open, edit, and save a file containing Spanish, Chinese, and emoji text; switch modes, navigate, resize, and exit with the shell restored. |
| fzf | Filter Unicode candidates, navigate the result list, resize, and accept the intended item. |
| more, less (each) | Page and search a long file, navigate in both directions across a resize, and quit to an intact prompt. |
| btop, htop (each) | Run the updating dashboard, navigate an interactive control, resize without stale regions, and quit cleanly. |
| lazygit | Open a controlled repository, navigate panels, inspect a diff, stage and unstage a change, resize, and quit without display corruption. |
| Claude Code, Codex (each) | Edit and submit a prompt, receive streaming formatted and tool output, operate an interactive choice or approval, browse prior output, resize during activity, interrupt work, and exit cleanly. |

### L. Power and performance

| id | Decision | Status |
|---|---|---|
| L1 | The engine is event-driven: PTY input updates terminal state, state damage requests visible rendering, and AppKit coalesces presentation. There is **no permanent display link and no periodic redraw loop**. | live |
| L2 | Visibility, focus, activation, and damage feed a deterministic scheduling policy. AppKit performs the resulting scheduling and drawing; system callbacks never decide terminal semantics. | live |
| L3 | The power contract: no periodic work for unchanged content; no rendering for hidden or occluded panes; no accidental macOS power assertions; background PTY output consumed and parsed without drawing; sleep/wake resumes IO and redraws current state correctly; idle CPU effectively zero. | live |
| L4 | **No engine component creates a macOS power assertion**, and DanTerm never keeps the display awake for terminal activity. | live |
| L5 | There is no periodic visual behavior. Application-requested cursor blinking retains its semantic preference but renders steadily; timed blink presentation is a deferred enhancement covering focus, visibility, activation, teardown, redraw equivalence, and quiescent timer ownership. | deferred |
| L6 | Correctness takes priority over peak rendering throughput. Heavy visible output must still keep the app responsive and use bounded queues. | live |
| L7 | Teardown cancels every owner-bound timer and scheduled callback, and leaves no AppKit message aimed at a deallocated object. | elsewhere -- [2026-06-09-appkit-lifetime-safety.md](2026-06-09-appkit-lifetime-safety.md) |
| L10 | **Application deactivation alone never suppresses rendering for a visible pane.** Losing frontmost status feeds alert policy, jump mode, drag cancellation, and checkpoint flushing; it reaches nothing on the render-scheduling path, which reads pane visibility, window occlusion, and system sleep. A pane the user still watches in a background window keeps drawing. This is the reading of L2 that a plausible "energy optimization" would break silently, so it is stated rather than inferred. | live |
| L8 | Rejected: a first-version GPU renderer, or maximum benchmark parity with Ghostty. | rejected |
| L9 | Rejected: rendering every intermediate frame of an output burst. | rejected |
| L11 | Rejected: a separate screen-sleep adapter. A 2026-08-06 AppKit probe found that screen sleep clears `NSWindow.OcclusionState.visible`, so the occlusion route already suppresses those panes; a second, narrower signal would duplicate a broader one and could disagree with it. `app/` therefore observes `NSWorkspace` system sleep and wake and window occlusion, and nothing else. Whether system sleep and screen sleep should ever be told apart is still open in `research/29/Q3`. | rejected |

### M. Migration mechanics -- spent

These decisions governed the migration itself. They are recorded because they
explain how the engine reached its current shape, and because several name
alternatives that would otherwise be re-proposed. **None of them describes the
current tree.**

| id | Decision | Status |
|---|---|---|
| M1 | Engine development began on an isolated `experiment/swift-terminal-engine` branch; normal DanTerm development did not depend on it before the viability decision. | spent |
| M2 | DanTerm exposed a narrow, product-specific terminal boundary describing *DanTerm's needs* rather than mirroring libghostty APIs. Both backends could implement it during development. The boundary survives; the coexistence does not. | spent |
| M3 | Backend selection (`DANTERM_TERMINAL_BACKEND`) was a development facility, never a promised user-facing feature. | spent |
| M4 | Development targeted an interactive vertical slice before broad protocol or application parity. | spent |
| M5 | An explicit Milestone 4 interactive viability gate had to pass before the experiment continued, forcing one of four outcomes: abandon, continue, retain only independently useful infrastructure, or commit to the full replacement roadmap. | spent |
| M6 | The Milestone 5 decision was "continue the experiment; do not commit to cutover yet." | spent |
| M7 | The replacement gate required all component invariants proven, compatibility workflows passing, direct/tmux/ssh use working, DanTerm pane/tab/split/alert/persistence/IPC behavior unchanged, inspection and recovery contracts passing, idle/visibility/sleep-wake/teardown passing, and no required behavior depending on Ghostty at runtime or build time. | spent |
| M8 | **Milestone 10 proceeded ahead of Milestone 9 by owner decision.** The power-and-performance gate was never run, and M9's "no required fallback to Ghostty" criterion closed by construction rather than by evidence. | spent, with live consequence |
| M9 | Rejected: developing the unproven engine directly in normal DanTerm development, which could have destabilized the shipping product. | rejected |
| M10 | Rejected: a generic abstraction over every libghostty call -- it would have preserved the shape of the dependency being removed. | rejected |
| M11 | Rejected: shipping two permanent backends -- no product requirement justifies the continuing cost. | rejected |
| M12 | Rejected: completing broad protocol parity before producing an interactive slice, which would have spent most of the project before answering the foundational viability question. | rejected |

## Proof record

Distilled from the dated evidence records that this note replaced. Retained run
artifacts referenced by those records lived under `.build/` and are gone; the
reproduction commands and external pins are checked in.

**Proof class is the load-bearing column.**

- `maintained gate (default)` -- a checked-in executable gate that runs in
  `just test` and fails on regression.
- `maintained gate (opt-in)` -- a checked-in executable gate that fails its
  invocation on regression, but runs only when invoked. Nothing re-runs it
  automatically, so its last recorded result ages: the *gate* is maintained, the
  *result* is dated.
- `historical observation` -- seen once, on one machine, on the date given.
  Evidence that something worked then, not a guarantee it works now, and nothing
  re-checks it.
- `superseded` -- replaced by a later row; cite that row instead.

Do not cite a historical observation, or the last result of an opt-in gate, as
proof of current behavior. Each row states what its gate actually executes,
which is narrower than the workflow the evidence originally described.

| Date | Gate | Proof class | Result and reproduction |
|---|---|---|---|
| 2026-07-20 | Milestone 4 workflow recording replay | maintained gate (default) | `DanTermRecordingFixtureTests.milestone4ViabilityRecording` decodes the captured `milestone-4-viability.json` and replays it through `TerminalCore` under authored, bytewise, and split feed chunking, asserting one final state and every workflow marker. This is **headless terminal-core proof only** -- it pins the engine's response to the recorded byte stream and cannot fail when AppKit or PTY integration regresses. |
| 2026-07-20 | Milestone 4 live interactive viability run | historical observation | One run on MacBookPro18,1 (M1 Pro), macOS 26.5.2, zsh 5.9, `en_US.UTF-8`. A real zsh PTY through the AppKit input and rendering path: typing, dead-key composition, Spanish/Chinese/emoji, Ctrl-C and a background job, `ls`/`cat`/`less`, hidden-pane output and reveal, non-last-pane exit, last-pane quit confirmation, teardown with no owned descendants; marker-bounded reflow byte-identical across 56x25 -> 90x25 -> 56x25; idle window 0.01s CPU with no render-plan events and no DanTerm-owned power assertion; a lid-close sleep of >10s preserved content exactly once, redrew the current frame, stayed interactive, and returned to quiescence. `DANTERM_TERMINAL_ENGINE_TEST_ALLOW_APP_CONTROL=1 just test-terminal-viability` remains a maintained **reproduction facility** -- it can be re-run, but nothing re-runs it, and this 2026-07-20 result is not evidence about the current tree. The maintained sleep/wake proof is the 2026-08-06 session row below for pane state and the 2026-08-06 AppKit row for the `NSWorkspace` adapter, not this run. |
| 2026-07-21 | Workflow compatibility | maintained gate (opt-in) | `nix develop .#terminal-workflows -c just test-terminal-workflows` -- zsh, bash, fish, ssh, fzf, more, less through the real `TerminalPTY`/`TerminalPaneSession` boundary. Last recorded pass 2026-07-21. |
| 2026-07-21 | Asciinema nested PTY | maintained gate (opt-in) | Same harness; record and local replay of an interactive shell through asciinema's intermediate PTY. Last recorded pass 2026-07-21. |
| 2026-07-21 | Terminfo baseline capture | historical observation | The claimed capabilities were captured against two baselines -- macOS 26's `/usr/share/terminfo` `xterm-256color` entry and pinned ncurses `terminfo.src` r1.1261 (2026-07-19) -- which agreed. The v1 JSON manifest, its fixtures, and the build/CI byte-comparison gates that enforced this were **retired**. Nothing now re-compares the tables against either baseline, so a non-key table error would not be caught automatically. The capture is recorded as the provenance note in `docs/terminal-capabilities.md`. |
| 2026-07-21 | Capability key conformance | maintained gate (default) | The nine key rows (`kcuu1` through `knp`) are pinned by an executable behavioral test in `TerminalKeyEncodingTests`. This is what replaced the retired byte-comparison gate; it proves the key encodings, not every table entry. |
| 2026-07-21 | Real-pane protocol probes | superseded | 11 selected esctest2 cases through the production pane-session controller. Replaced by the 2026-07-31 gate; cite that row instead. |
| 2026-07-31 | External terminal gate | maintained gate (opt-in) | `just test-terminal-protocol-probes`. Pins and preflight live in `scripts/terminal-protocol-probes.sh`, so an upstream update cannot silently change expected behavior. Last recorded pass 2026-07-31 on macOS 26.5.2 arm64: esctest2 at `664be3cf2c1e3f06bc93a8bafb48a0db83c607db`, 14 selected cases, 14 passed, 0 known bugs; vttest 2.7 (20251205) at `0229d7171a8574a2bf406c6ce14549f65d810e51` covering VT100 DSR/CPR, VT100 DA1 (decoded DanTerm's exact `CSI ? 1 ; 2 c`), and VT320 DECCPR. Every session launched through `TerminalPaneSessionController` and `PTYSessionBootstrap` and released its pane session, child, PTY owner, descriptors, and dispatch sources. |
| 2026-08-06 | Milestone 9 pane scheduling, sleep/wake, and runtime teardown | maintained gate (default) | `TerminalPaneSessionControllerTests` pins the pane scheduling contract: `visibleCreationRetainsInitialFrame` and `resultOnlyEqualSnapshotSkipsPlanning` publish no repeat frame for unchanged state; `hiddenCreationDefersInitialFrame` and `hiddenOutputAndReveal` keep terminal, semantic, inspection, and recovery state current with no frames, then publish one complete reveal; `burstConflatesToFinalPlan` retains the final state through fewer publications than writes; `systemSleepAndVisibleWake` and `hiddenWakeDefersUntilReveal` prove state continuity across suspension, idempotent transitions, one full frame on visible wake, and a hidden wake deferred to reveal; `applicationExitFenceDrainsAcceptedOutput` pins the exit fence. `RecoveryCheckpointPolicyTests` covers checkpoint freshness, failed-write retry, covering success, idle quiescence, and termination. `AppRuntimeSchedulingLifecycleTests.shutdownEmptiesEveryOwnerCategory` arms all six production owner categories, shuts down twice, observes an empty census, and proves both captured callbacks and every rearm attempt inert. This is **session, policy, and scheduler proof only** -- it asserts frame, event, and callback counts. It runs no AppKit, and it measures no CPU time, power draw, or latency. |
| 2026-08-06 | Milestone 9 AppKit lifecycle adapters and input ordering | maintained gate (opt-in) | `just test-ui`, which `just test` excludes because it needs a WindowServer connection. Two `AppPresentationLifecycleTests` cases drive the real `NSWorkspace.shared.notificationCenter`: one proves `WorkspaceLifecycleObserver` reaches the session rendering-availability seam and goes inert after observer teardown, the other drives `AppDelegate.windowDidChangeOcclusionState` through `AppRuntime.syncPaneVisibility` to exactly one reveal, which is also the screen-sleep suppression route named in L11. One `SwiftTerminalSessionViewTests` case proves a real AppKit `keyDown` reaches the controller before a bounded visible frame stream finishes; it fixes an ordering, not a latency bound. Last recorded pass 2026-08-06 on macOS arm64, 204 of 204 UI tests. |
| 2026-08-06 | Milestone 9 power draw and sparse-clip topology | historical observation | A source audit on this date found no IOPM power-assertion creation in production code; nothing re-checks that. No checked-in test measures CPU time or battery use, so the only measured idle and post-wake CPU windows remain the 2026-07-20 live run above. Sparse-clip topology stays unproved: three independently collected 24-pair A/A screens of the `sparse-spans-max` benchmark gave incompatible calibration outcomes, including a controlled low-load series that selected no rule, so the workload is a descriptive diagnostic with no verdict and DanTerm makes no automated CPU-protection claim. The refusal and the preserved results are recorded as `research/29/F8` and `research/29/D3`. |

One cosmetic divergence found during the 2026-07-31 probes is still open: an
unpaired regional indicator -- half a flag emoji split by tmux's partial redraws
-- renders as a solid black square where Apple text rendering shows a
letter-in-a-box. It does not gate anything.

## Open questions

Deliberately undecided. These are inputs to future decisions, **not** permission
for an implementation to pick a direction silently -- answering one amends this
register. They are carried here rather than in a plan file because a plan is
historical and these outlive any plan.

- **Packaging.** Which boundaries deserve separate SwiftPM packages versus
  internal targets? (Interacts with the cross-module dispatch cost recorded in
  [2026-07-29-cross-module-value-dispatch.md](2026-07-29-cross-module-value-dispatch.md).)
- **Device and mode queries.** Which additional queries beyond the current
  capability contract do later prioritized applications require? I5 currently
  denies DA2, DECRQSS, XTGETTCAP, and 8-bit replies.
- **Notification and progress surface.** Which protocols, if any, justify
  extending past the bounded OSC 9 and OSC 777 forms in I6?
- **DEC coverage.** Which less-common DEC modes and rectangle operations do the
  accepted workflows actually require?
- **Interactivity thresholds.** What measurable latency and throughput numbers
  define "interactive" for the correctness-first renderer? Until this is
  answered, H1's Metal threshold and L6's responsiveness claim have no number
  behind them -- and neither does the Milestone 9 responsiveness seam.
- **OSC 52 reads.** Should the blanket denial in G12 ever gain an explicit
  permission path?
- **Keybindings.** H10 says the format is DanTerm-owned; no keybinding
  configuration exists yet, and its shape is undecided.
- **Custom terminfo.** What evidence would justify a `danterm` terminfo entry,
  given I14 rejected it as an initial choice?

## Consequences

- The engine's acceptance standard is now this document plus the design notes it
  points at. `plan-terminal-engine/` is deleted; its content is either above,
  superseded by a live document, or in git history. `docs/evidence/` is
  superseded by the **Proof record** above and retained as dated evidence
  records, not as a current acceptance standard.
- Amendment rules are in **Keeping the register honest** above. They apply to
  code changes too: a commit that contradicts a `live` row amends that row.
- Milestone 9's criteria were never run as one composite gate. DanTerm ships
  0.1.0 on per-layer proof of the section L contracts, with sparse-clip topology
  the one named seam still unproved.
  [plans/impl/2026-08-06-1143-m9-power-performance-gates.md](../../plans/impl/2026-08-06-1143-m9-power-performance-gates.md)
  owns closing it.
- Undecided *questions* are in **Open questions** above. Undecided *features*
  with a candidate design live in `plans/wip/`; the deferred command journal
  moved there. The shipped ownership rule for terminal-reported facts is
  recorded in
  [2026-08-10-session-owned-terminal-reported-facts.md](2026-08-10-session-owned-terminal-reported-facts.md).
  This document records decisions and the questions that would change one; it
  does not record candidate designs.

## References

- [docs/terminal-capabilities.md](../terminal-capabilities.md) -- the normative capability contract (I2, I3, I4)
- [docs/terminal-sprites.md](../terminal-sprites.md) -- procedural glyph contract (H5)
- [2026-08-01-osc-133-prompt-anchoring.md](2026-08-01-osc-133-prompt-anchoring.md) -- prompt row ownership and reflow (I10)
- [2026-08-10-session-owned-terminal-reported-facts.md](2026-08-10-session-owned-terminal-reported-facts.md) -- session ownership, identity, and reduction for terminal-reported facts (I7, I11, I12)
- [2026-07-29-cross-module-value-dispatch.md](2026-07-29-cross-module-value-dispatch.md) -- hot value types across target boundaries
- [2026-06-09-appkit-lifetime-safety.md](2026-06-09-appkit-lifetime-safety.md) -- owner-bound timer and callback teardown (L7)
- [2026-07-20-terminal-engine-experiment-decision.md](2026-07-20-terminal-engine-experiment-decision.md) -- the Milestone 5 record this note supersedes (M6)
- [docs/research/1-external-tests.md](../research/1-external-tests.md) -- external corpus survey and standing constraints (K11)
- [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md) -- measurement practice and the performance optimization index
- [plans/impl/2026-08-06-1143-m9-power-performance-gates.md](../../plans/impl/2026-08-06-1143-m9-power-performance-gates.md) -- the unclosed power gate (M8)
