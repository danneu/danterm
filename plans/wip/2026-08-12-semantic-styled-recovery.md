---
state: parked (2026-08-13)
why: the behavioral contract is converged -- two review rounds, no blocking
  findings, accepted risk AR1 recorded -- but the user has not yet chosen
  which delivery trade-off to buy. See "Open decision - how much of this to
  buy" for the options (A-D) and their costs.
implemented: nothing. No code, test, or shell-integration change exists for
  this plan; the sections below past the open decision describe option D
  unchanged.
resume: pick an option in the open-decision section, revise the contract to
  match (C deletes I4/I10, PO3/PO9/PO10, and the shell changes), then slice
  and implement.
stale-if: the checkpoint capture path, restore `cat` path, or recovery format
  has materially changed since 2026-08-13, or styled recovery shipped another
  way. Otherwise this file is current and waiting on a decision, not
  abandoned.
---

# Restore terminal history from semantic content, not plain text or PTY bytes

## Status

Parked. The behavioral contract below has been through two review rounds and
has no blocking findings, but it encodes the most expensive of several viable
deliveries. Continuing requires the user to pick a trade-off in
`## Open decision: how much of this to buy`. Until that decision is made, do
not implement any part of this plan.

## Open decision: how much of this to buy

The plan decomposes into three separable pieces with very different
cost-to-gain ratios:

1. **Semantic capture, snapshot format, and terminal-owned import** (Candidate
   decision; I1, I5, I7). Irreducible: any styled recovery, including the
   cheaper fallback, needs capture to stop projecting through the
   style-discarding plain-text path. The format is a permanent maintenance
   surface, but the no-migrations non-goal keeps that cheap.
2. **Bounded admission** (I6, I8). Justified in kind -- `--init` and Import
   accept arbitrary files, and today's load path has no size limit at all --
   but the ceremony (allocation-multiple proofs, measured worst-shape corpus)
   could be scaled down without touching the invariant.
3. **The first-prompt boundary and pending-recovery machinery** (Restore
   ordering; I4, I10; PO3, PO9, PO10; edits to all three shell integrations).
   Roughly half the contract: a timely/late/duplicate/expiry state machine,
   the carry-forward checkpoint rule, and real-PTY test rigs per shell. Review
   round 2 established that its protection is partial: a hostile hook
   registered after the integration's still runs post-boundary at the first
   prompt, so an explicit post-boundary history erase remains an accepted
   risk (AR1) with or without the boundary.

The realistic options, from cheapest to most expensive:

| Option | Gains | Permanent cost |
|---|---|---|
| A. Status quo (plain text) | none | zero |
| B. Cheaper fallback: SGR stream via existing `cat` | most visible styling | semantic capture plus a resets-must-be-perfect encoder |
| C. Semantic import at pane creation, no boundary | full fidelity, links, reflow | pieces 1 and 2 only |
| D. Full plan as written (boundary import) | C plus partial ordering protection | pieces 1, 2, and 3 |

The case for C over D: the hazard the boundary defends against -- startup
output disturbing the restore -- is the risk the shipped `cat` path already
carries today, imported content joins primary history so a realistic clear
(ED 2, redraws) cannot destroy it, and only an explicit pre-prompt ED 3 can --
the same risk D already accepts as AR1. C deletes I4, I10,
PO3, PO9, PO10, the expiry rules, and every shell-integration change, and it
places old history above the fresh banner rather than below it. If a real
framework is later observed eating restores during startup, the boundary can
be added then; the snapshot and import seam keep the same shape either way.

The case for D over C: it is the only option that gives any in-band ordering
guarantee, and its pending-durability rule (I10) is already worked out to be
lossless across restart chains.

The case for B over both: smallest new code. Against it: the encoder must
emit resets and transitions perfectly, fidelity is capped by the allowlisted
sequences, and it still requires piece 1's capture side -- so it is a
mediocre middle rather than a cheap exit.

Choosing C reverses the `Import recovery before feeding the first PTY byte`
entry under `Rejected ideas`; the round-2 evidence above (risk parity with
the shipped `cat`, PO9's partial protection) is the grounds for reopening it.
Everything below this section describes option D unchanged, so the contract
is not lost if D is chosen.

## Problem

DanTerm's live terminal retains styling correctly, but recovery checkpoints
discard it. The loss happens during checkpoint capture, before persistence or
rendering:

1. `Terminal.primaryHistoryTailText` projects retained primary history and the
   primary screen into a `String`. This preserves logical text and hard versus
   soft line boundaries, but it does not carry each cell's `TerminalStyle` or
   hyperlink.
2. The checkpoint pipeline truncates that string to at most 4,000 logical
   lines and 400,000 grapheme clusters and stores it in the pane snapshot's
   `scrollback` field.
3. Restore writes the string to a temporary text file and passes its path to a
   fresh shell.
4. The shell integration runs `cat` on that file. The resulting PTY bytes are
   ordinary UTF-8 text with no SGR presentation sequences, so the new terminal
   paints every restored cell with its current default style.

The renderer is not losing style. The live engine still owns semantic style
per cell, including indexed and RGB colors, background color, bold, dim,
italic, underline and underline color, reverse, hidden, and strikethrough.
The persistence projection throws that information away.

This is the intended current contract, not an accidental omission.
`docs/design/2026-08-06-swift-terminal-engine.md E9` says recovery restores
plain text only, and E12 defers persisting presentation attributes. Any styled
recovery implementation therefore amends that design document in the same
change.

## Desired outcome

A restored pane presents the retained primary transcript with the same
semantic appearance and logical line structure it had at checkpoint time,
subject only to the checkpoint's retention bound and reflow at the restored
pane's width.

Recovery still starts a new shell in a new PTY. It does not reconnect to the
old process or restore the old terminal's transient control state.

The governing distinction is:

> Recovery restores the displayed primary transcript while starting a fresh
> process and fresh terminal control state.

## Candidate decision

Make recovery a first-class semantic snapshot and import operation owned by
`TerminalCore`. Persist the final content that the terminal has already
interpreted, not the operations that happened to produce it.

The durable snapshot represents logical primary content independently of the
engine's private storage layout. It carries enough information to reconstruct:

- Grapheme cells, including explicitly written spaces and styled blank cells
  whose background is visible. Unwritten outer padding is omitted; written
  spaces and styled blanks are content even when the whole transcript is
  otherwise whitespace.
- Semantic style runs: foreground and background colors, bold, dim, italic,
  underline shape and color, reverse, hidden, and strikethrough.
- Hard line endings, soft continuation, an open final line, and retained-prefix
  truncation needed for correct reflow.
- OSC 8 URI and explicit identity. Restored links remain interactive under the
  existing URI-validation policy and receive fresh activation identities on
  import.

The snapshot does not serialize private style ids, packed history records,
arena offsets, content-generation ids, or other implementation details. On
import, `TerminalCore` validates the snapshot, mints fresh internal identities,
interns styles and hyperlinks into the receiving terminal, applies the current
history budget, and folds the logical content for the restored geometry.

The imported transcript joins the receiving terminal's primary history through
a terminal-owned operation. It does not pass through the escape-sequence
parser. Ordinary output from the new PTY then continues after it.

## Restore ordering

Semantic import alone is insufficient. A fresh shell can emit output, clear
the screen, or change modes during startup. Importing at an arbitrary point can
therefore reorder or erase recovered content even when the checkpoint is
lossless.

Restore uses a dedicated first-prompt recovery boundary emitted by an
integration-enabled shell from the path that is about to produce its first
prompt. The existing `integration-ready` event is not this boundary: it only
reports that the integration file finished loading, while later startup code
may still print or clear.

Pending recovery is `Terminal`-owned state installed before PTY feeding begins.
When the parser encounters the first-prompt boundary, `Terminal` imports the
snapshot inline and adds any validated agent recovery hint as fresh session
output before parsing the next byte. The marker does not enter terminal
content. Prompt bytes in the same `feed` call therefore cannot overtake import,
and no byte can split the transaction.

Only the first timely boundary can consume pending recovery. Duplicate markers
are inert for recovery. A marker is late only after in-band evidence makes
insertion unsafe: the parser receives an OSC 133 prompt mark or a DanTermShell
command-start or command-end event without the boundary. That parser-observed
evidence drops pending semantic history and its agent hint. User input and
elapsed time never expire recovery, so an arbitrarily slow but correctly
integrated shell can still restore. A shell that never emits either the
boundary or expiry evidence remains fully usable because pending recovery
neither blocks nor defers PTY bytes; its bounded snapshot may remain held for
the pane's lifetime. This fallback preserves current no-recovery behavior for
absent or incompatible shell integration rather than inventing an unsafe
insertion point.

While recovery remains pending, it is authoritative for that pane's checkpoint
capture. A checkpoint forms its new pending payload by placing the existing
pending semantic snapshot first and the pane's currently displayed primary
transcript after it. The ordinary retention and admission policy then keeps the
newest valid suffix. Repeated checkpoints in one pending window recompute this
payload from the same live pending snapshot and current display; they do not
append an already captured display again. The validated agent hint remains a
separate pending value and is carried exactly once. Consuming recovery at the
boundary, or dropping it after parser-observed prompt or command evidence makes
insertion unsafe, atomically ends this carry-forward rule. Later checkpoints
then capture the terminal's displayed primary transcript normally. Restarting
any number of times during the pending window therefore preserves all retained
output in order without duplicating content or the hint.

This seam replaces the temporary text file and `cat` replay path. The agent
hint is not part of the persisted terminal transcript and never becomes old
checkpoint content.

## End-to-end admission

One recovery admission policy governs the writer, file boundary, decoder, and
`TerminalCore` importer. Validation after ordinary `Data(contentsOf:)` and
unbounded `Decodable` construction is too late: a hostile file must not be
materialized before its limits are known.

The policy has these externally meaningful limits:

- The encoded checkpoint is at most 256 MiB. The file boundary rejects a larger
  file before allocating its contents, and the decoder cannot read beyond that
  ceiling if the file changes after the size check.
- Each pane retains at most 4,000 logical lines and 400,000 grapheme clusters,
  as today, and its decoded semantic history cannot exceed the terminal's
  existing 16 MiB scrollback charge.
- Each pane's retained hyperlink metadata shares the terminal's existing 256
  KiB metadata ceiling; an individual URI remains limited to 64 KiB. Style
  cardinality cannot exceed retained cells because every style entry must be
  referenced, and style values are fixed-size.
- Total decode-time allocation is bounded by a fixed multiple of the 256 MiB
  encoded ceiling, and structural nesting cannot exhaust the stack.

The writer applies the same policy and never emits a checkpoint its reader
would reject. When the whole-checkpoint ceiling binds, it shortens pane
transcripts from their oldest ends at valid semantic boundaries; it does not
drop current app structure or produce a partially valid file. The allocation
across panes is implementation discretion, but it must be deterministic and
must not exceed any pane's individual limits. If app structure and other
non-transcript fields alone exceed the ceiling, that checkpoint write fails
and leaves the preceding valid checkpoint intact.

The 256 MiB ceiling allows sixteen panes at the live engine's full 16 MiB
history budget before accounting for structural overhead. Its proof obligation
measures real encoded worst-shape snapshots before the value ships; if that
evidence rejects the ceiling, the plan must be revised rather than silently
changing the bound during implementation.

## Concurrency placement

Recovery keeps the checkpoint pipeline's Swift 6 isolation contract. The main
actor synchronizes each live pane and copies its value-semantic `Terminal` into
the checkpoint capture. It does not project semantic content, apply retention,
graft pane payloads, or encode the checkpoint. Those operations remain deferred
until the serial checkpoint writer invokes the capture's `@Sendable` work.
Periodic checkpoints and asynchronous state exports execute that work off the
main thread. The synchronous quit checkpoint keeps its existing writer fence;
it does not move payload assembly back into the main-actor capture.

The semantic snapshot and pending-recovery payload are checked `Sendable`
values. They cross between the main actor, the `TerminalPTYHost` actor, and the
checkpoint writer without `@unchecked Sendable` or `nonisolated(unsafe)` escape
hatches. The writer's completion remains `@MainActor @Sendable`, so recovery
policy state is updated on its existing owner.

## Invariants

- **I1 (semantic fidelity).** Every retained grapheme, written space, visible
  blank, style, logical line boundary, and retained hyperlink has the same
  semantic value before capture and after import. Only unwritten padding is
  omitted; whitespace-only written or styled content remains recoverable.
- **I2 (fresh control state).** Recovery imports no parser state, modes, cursor
  state, pen state, margins, tab stops, synchronized-update state, selection,
  search state, hover state, alternate screen, pending replies, or semantic
  event queue from the old terminal.
- **I3 (fresh process).** Recovery creates a new shell and PTY and never
  preserves, reconnects to, or replays input into the old process.
- **I4 (ordered continuation).** A timely first-prompt boundary imports the
  transcript and then emits any agent hint atomically in the pane's serialized
  terminal transition order. Fresh prompt and command output follow them; PTY
  output cannot split the transaction. A missing, late, or duplicate boundary
  never blocks or reorders the fresh shell, and elapsed time alone never makes
  a boundary late.
- **I5 (geometry independence).** A width change between checkpoint and restore
  reflows logical content without changing its graphemes, styles, hard
  boundaries, or explicitly written spaces.
- **I6 (bounded recovery).** File admission, decode, capture, and import obey one
  policy bounded both for the whole checkpoint and per pane. Oldest logical
  content is discarded at valid grapheme and logical-record boundaries when a
  content budget requires it.
- **I7 (representation independence).** A compatible snapshot remains valid
  when the engine changes its style interning, history packing, indexing, or
  renderer implementation.
- **I8 (untrusted input).** A malformed or oversized file is rejected before
  unchecked read or decoded-model construction. Valid decoded input cannot
  violate grid, grapheme, wide-cell, style-table, hyperlink, nesting, or
  memory-budget invariants.
- **I9 (primary transcript only).** Alternate-screen content remains transient.
  Recovery does not present it as ordinary primary scrollback.
- **I10 (pending durability).** Until pending recovery is consumed or dropped,
  every checkpoint carries the pending semantic snapshot followed by the
  pane's currently displayed primary transcript as the next pending payload,
  subject to the ordinary retention bounds. Displayed output appends after
  pending content and never replaces, reorders, or duplicates it. The agent
  hint remains separate and appears at most once.
- **I11 (off-main checkpoint work).** A periodic checkpoint performs no
  semantic projection, retention, grafting, or encoding on the main thread.
  Main-actor capture only synchronizes and copies live terminal values; payload
  assembly runs in the checkpoint writer's deferred work. Every value crossing
  an actor or queue boundary has checked `Sendable` conformance.

## Proof obligations

These obligations cover both the behavior this direction adds and the claims
it relies on about existing behavior.

- **PO1 (I1).** A transcript containing every supported style attribute,
  indexed and RGB colors, style transitions within a line, wide graphemes,
  combining graphemes, written spaces, styled blanks, hard endings, soft wraps,
  and hyperlinks is semantically equal after capture, encode, decode, and
  import. A whitespace-only transcript made of written spaces and colored
  blanks survives, while an equivalent extent of unwritten padding does not.
- **PO2 (I2, I3, I9).** A source terminal with non-default modes, cursor and pen
  state, active selection and search, pending semantic state, and alternate
  screen restores only its primary transcript into a terminal with fresh
  defaults and a newly launched process.
- **PO3 (I4).** Shell startup output, a timely boundary, semantic import, agent
  hint, first prompt, and immediate post-prompt output have one deterministic
  order under delayed, split, and same-buffer PTY delivery. Missing and late
  boundaries do not block fresh shell progress; an OSC 133 prompt mark or a
  DanTermShell command-start or command-end event before the boundary expires
  pending recovery without reordering the stream; duplicate boundaries neither
  duplicate import or hint nor reorder later bytes. User input does not expire
  recovery. A boundary arriving after arbitrary wall-clock delay, with none of
  that parser-observed expiry evidence before it, still restores.
- **PO4 (I5).** Restoring the same snapshot at narrower, equal, and wider widths
  preserves its logical projection and semantic style sequence while changing
  only its visual fold.
- **PO5 (I6, I8).** An oversized encoded file is rejected before its contents or
  decoded model are allocated. Incremental input cannot pass the file ceiling;
  oversized strings, collections, nesting, style tables, hyperlinks, cells, and
  pane payloads fail at the shared admission boundary. Writer-produced
  multi-pane checkpoints stay within the same total and per-pane limits and
  retain valid newest suffixes without splitting a grapheme; structure-only
  overflow leaves the preceding checkpoint intact. A measured corpus containing
  maximum-width Unicode, per-cell truecolor styles, maximum link metadata, and
  multiple full panes confirms or rejects the 256 MiB ceiling before it ships.
- **PO6 (I7).** The persistence tests compare the public semantic snapshot, not
  private ids or encoded storage layout. A test-only reconstruction through a
  differently interned style table produces the same result.
- **PO7 (existing behavior).** Unstyled checkpoints, panes with no retained
  content, checkpoint merge, clean-termination flush, and recovery freshness
  retain their current observable behavior except where the new format
  intentionally supersedes plain-text storage. Written or styled
  whitespace-only content now survives; unwritten padding still does not. A
  valid agent hint appears exactly once after imported history and before the
  first prompt, while an invalid hint remains absent.
- **PO8 (existing projection claim).** Inspection, search, selection copying,
  and `danterm pane read` continue to share the current logical-text projection;
  styled persistence does not create a competing text interpretation.
- **PO9 (shell-boundary premise).** Each supported integration -- zsh, Bash,
  and fish -- is run as a real binary in a real PTY and emits exactly one
  recovery boundary before any first-prompt bytes. The proof covers ordinary
  startup and each shell's prompt-hook repair path rather than inferring order
  from integration source. A hostile hook registered after the integration's
  hook emits screen erasure, cursor movement, and redraw sequences between the
  boundary and the first prompt; imported content remains present in primary
  history after the prompt renders.
- **PO10 (I10).** Restore a pane, checkpoint it before the boundary, and restore
  that checkpoint again. The eventual boundary imports the original pending
  transcript followed by each interrupted attempt's displayed primary output in
  order, subject to retention, and the agent hint appears exactly once. Multiple
  checkpoints during one attempt do not duplicate that attempt's displayed
  output. Repeating the restart cycle preserves each cycle's newly displayed
  output instead of replacing it with the older pending snapshot.
- **PO11 (I11, existing behavior).** Building a checkpoint capture and obtaining
  its encoder performs no semantic pane read, projection, retention, graft, or
  encode. A periodic writer-queue probe observes that those operations begin
  only when the deferred encoder runs and never run on the main thread. The
  Swift 6 build checks the semantic snapshot and pending payload across their
  real main-actor, `TerminalPTYHost`, and `@Sendable` writer boundaries without
  an unchecked isolation escape. The checkpoint off-main gate recognizes the
  new semantic projection path, and writer completions still arrive on the main
  actor.

## Why not preserve the original PTY stream

PTY bytes are operations, not terminal content. Replaying the original stream
can repeat cursor movement, erasure, mode changes, alternate-screen switches,
queries and replies, clipboard operations, notifications, titles, bells, and
hyperlink control sequences. Its result can also depend on the old geometry
and on mode state established before the retained byte suffix began.

A bounded byte suffix is not self-contained, while an unbounded recording is
not an acceptable recovery format. Replaying arbitrary historical output into
a new shell also confuses recovered display with new process output.

The terminal has already reduced those operations to the final semantic state
the user wants. Persisting that state removes historical side effects by
construction.

## Cheaper fallback

A smaller change could persist semantic style runs and encode them as a
sanitized stream containing only printable content, line boundaries, SGR, and
optionally OSC 8. The current shell integration could `cat` that stream at the
existing restore point.

This would preserve most appearance without replaying the original PTY bytes,
but it remains an indirect reconstruction through shell startup and the parser.
Its fidelity is limited to state representable by the allowlisted sequences,
and correctness depends on emitting resets and transitions perfectly. It is a
conscious cost trade-off, not the ideal architecture.

## Non-goals

- Preserving or reconnecting to the old child process.
- Restoring the alternate screen, cursor, modes, selection, search navigation,
  hover state, or pending terminal effects.
- Styled HTML export or a general terminal-session archival format.
- Making private `Terminal` storage Codable.
- Keeping old checkpoint formats through migrations or compatibility shims.
- Recovering history or an agent hint when the dedicated first-prompt boundary
  arrives after an OSC 133 prompt mark or DanTermShell command event has made
  insertion unsafe.

## Accepted risks

- **AR1.** An explicit history erase after the recovery boundary, including ED
  3 from a later prompt hook, removes imported history. DanTerm continues to
  honor the child application's clear-scrollback request; the shell
  integrations cannot guarantee that their hook runs after every other hook.

## Rejected ideas

- **Store the original PTY byte stream.** It preserves historical operations
  and side effects rather than the final content, and a retained suffix is not
  self-contained.
- **Serialize the entire `Terminal` value.** It couples disk compatibility to
  private storage and accidentally preserves transient state recovery should
  reset.
- **Add ANSI escapes to the existing plain-text projection without a semantic
  model.** An encoder cannot reproduce styles after the projection has already
  discarded them.
- **Treat renderer output as the checkpoint.** Pixels or attributed glyph runs
  lose logical lines, grapheme cells, reflow behavior, and terminal color
  semantics.
- **Reuse the first OSC 133 `A` prompt mark as the recovery boundary.** In zsh,
  a framework can replace `PS1` after the precmd hook installs the mark; the
  line-init repair then emits the first `A` only after unmarked prompt bytes have
  already painted. The recovery boundary must be unconditional and earlier than
  every first-prompt byte.
- **Import recovery before feeding the first PTY byte.** Startup code can erase
  the primary screen in place or clear history before the first prompt, so an
  early import does not guarantee that the restored transcript is still
  presented. Import must follow startup output at the dedicated boundary.

## Implementation discretion

- The binary or JSON encoding, style-table compression, and run-length encoding
  are implementation choices as long as the semantic format is versioned,
  incrementally admitted within the end-to-end policy, and independent of
  private engine storage.
- The internal import algorithm may rebuild history records directly or use a
  dedicated semantic builder, provided it does not route recovery through the
  escape-sequence parser and satisfies the ordering and fidelity invariants.
