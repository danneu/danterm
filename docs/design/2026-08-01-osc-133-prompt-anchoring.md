# 2026-08-01: OSC 133 Prompt Anchoring

- Status: Accepted
- Date: 2026-08-01

## Context

Shells can repaint a prompt after a terminal resize using text composed for a
width the terminal has already left. A stale-width repaint can wrap onto extra
rows, erase only part of the old prompt, or briefly erase the current prompt's
OSC 133 marks before stamping the replacement. If the terminal treats those
intermediate rows as ordinary content, later reflow can preserve prompt
fragments, splice blank padding into a logical line, or anchor on an older
prompt and erase completed command output.

DanTerm handles this only when the shell declares what it will repaint:
`redraw=1` covers the full prompt block, while `redraw=last` covers only the
final prompt row. The F16/F17 investigation reached the current design through
seven live-pane defects and fixes. The fixes share two general invariants and a
two-phase ownership protocol; this note is their authority rather than any one
incident or shell implementation.

## Decision

DanTerm anchors OSC 133 prompt redraw with per-row semantic stamps. Stamps move
with rows during scrolling and reflow, so ownership needs no separate index
that every row-moving operation must maintain.

### Vacate and reclaim lifecycle

A prompt row follows this lifecycle:

1. An OSC 133 prompt mark stamps a live prompt head or continuation.
2. Before reflow, DanTerm **vacates** the rows the shell promised to repaint:
   it blanks them in place, clears their soft-wrap claims, and records
   `.vacated` rather than discarding their identity. Blanking in place preserves
   the space in which the shell is about to repaint. Height-only resizes do not
   reflow, so they do not vacate the block.
3. The shell either repaints a vacated row, replacing its semantic state, or
   stamps a newer prompt head while the row is still vacated.
4. At that newer head, DanTerm **reclaims** still-empty vacated rows and stale
   soft-wrapped heads by deleting them. Deletion, rather than another in-place
   blank, closes the otherwise permanent gap; the cursor moves by the same row
   count so the shell's relative cursor arithmetic remains coherent.

The terminal owns a row only because its semantic state records the shell's
repaint promise. Empty cells alone never establish ownership. Conversely, a
vacated row that has acquired unmarked content is not free to remove and is
left intact.

### Invariants and domains

**I1 -- Ownership.** Under `redraw=1`, rows from the top of the current prompt
block through its newest head that the shell has promised but not yet repainted
belong provisionally to the terminal. Vacating records that grant explicitly;
every vacated row is eventually repainted or, while still empty, reclaimed.
Cell contents are not evidence of ownership.

**I2 -- Logical-line integrity.** A prompt head stamped at column 0 begins a
logical line. The row above cannot retain a soft-wrap claim into it, and a
soft-wrapped prompt head immediately above a newer head is stale debris. A
prompt stamped mid-line does not sever the preceding row's claim.

**I3 -- Output floor.** The row where the latest command's output began is a
hard upper bound for every search for the current prompt. Vacating or
reclaiming prompt rows never modifies that command output, including when a
resize lands between a shell's erase and its replacement prompt mark.

**I4 -- Total vacating.** Vacating a prompt row clears its wrap claim together
with its cells. An empty row cannot contribute its old width in padding to a
logical line during reflow.

**I5 -- Geometry coherence.** Reclaim moves rows and the cursor together or
does not run. It is confined to the primary screen and to one active scroll
region, with both the reclaimed rows and cursor inside that region; the cursor
remains in bounds.

**I6 -- Redraw-mode scope.** Vacate and reclaim are bounded by the shell's
declared promise. Full-block work runs only under `redraw=1`. Under
`redraw=last`, DanTerm vacates only the final prompt row and never takes rows
above it; disabled redraw takes none. Both enabled modes vacate only in I7's
reflow domain.

**I7 -- Reflow domain.** Vacating is a precondition of reflow, not of resize. A
resize that leaves the column count unchanged modifies no prompt-block cell and
no prompt-block stamp. The vacate remains ahead of both resize legs: during a
combined shrink, moving the head into history first would leave the live-grid
upward walk unable to find the block's ownership boundary.

I7 assumes that no shell expects the terminal to clear the prompt on a resize
that keeps the width the same. Three reasons make this safe. First, the clear
was never a service to the shell: `redraw=1` gives the terminal permission to
clear, and the shell has no way to detect whether the clear happened, so it
cannot depend on it. Second, when the width is unchanged the prompt on screen
is still correct -- no cell or wrap flag changed -- so the worst case is a
shell repainting its prompt without erasing the old one, leaving a short-lived
duplicate that reclaim deletes at the next prompt mark. Third, no shell could
have learned to rely on the clear: mainstream terminals cleared nothing on
resize for decades, and fish, bash, and zsh all clear their own rows on every
SIGWINCH (F22).

I1, I2, and I4 are state properties and can be checked on a terminal snapshot,
so a universal oracle can replay every recording and check them after every
event. I3, I5, I6, and I7 constrain mutations, and no external per-event trace
can prove them in general: later parser actions in the same feed can hide an
invalid intermediate change, resize blanking is followed by reflow inside the
same resize call, and a mutation that wrongly never fires leaves no delta to
inspect. Their proof is instead targeted behavioral tests that bracket the
specific blanking or reclaim operation and assert observable outcomes.
Observing the mutation from inside production code would close the remaining
gap but is rejected for its cost: it would charge every release-build resize
full-grid snapshots for a test-only need.

The primary-screen resize plan's D1 decomposition claim is scoped to terminals
without a live prompt block. With a prompt block, a combined shrink vacates
before moving rows, while decomposing it into height-only then width-only calls
can move the head into history before the second call can find it. This was
already true of the vacate walk; I7 makes the relevant domain explicit.

### Scrollback boundary

Prompt anchoring operates only on the live grid. A stale head or vacated blank
that scrolls into history before reclaim remains there permanently. The window
is one repaint burst wide, and rewriting retained history would violate the
terminal's stronger promise that scrollback is stable user-visible output.

A height-only shrink can now move an unvacated prompt row into history, where it
remains as accepted stale-head debris. This changes which already-accepted
debris variant can occur, not whether the boundary can retain one. The open
tail's last partial row can later return across the seam with its prompt stamp;
that pre-existing path may present stale-width prompt cells to a later reflow.
Avoiding it in place would require discarding bytes already retained by the
logical-line store, so it remains an accepted boundary risk rather than part of
the height-only fix.

## Consequences

- Prompt semantic state remains internal to `Terminal`; public geometry and
  its equality contract do not carry test-only stamps.
- Reflow and row movement must preserve semantic stamps just as they preserve
  cells and wrap state.
- A vacated row may return from reflow containing content when it was packed
  into another logical line. Reclaim deliberately checks emptiness and declines
  that row. This parser-internal packing state is the only current case not
  expressible as a stable snapshot invariant; its domain is documented here
  rather than approximated with a cell-content ownership heuristic.
- The design depends on OSC 133 marks, not erase sequences. fish and zsh can
  perform the same pad-and-wrap transition with different trailing erases, but
  both emit the prompt mark that states the new logical-line boundary.
- Tests may expose internal stamps to the TerminalCore test target through
  computed accessors that cost production nothing unless a test calls them;
  the production public API does not change and production paths carry no
  observation state or hooks.

## Rejected alternatives

### Stored prompt-block anchor

A single row index looks simpler than a walk, but every scroll, insert, delete,
height change, and reflow would have to update it. Per-row stamps travel with
the rows under the existing movement primitives and retain each row's state
through the erase-to-repaint window.

### Prompt stamps in public geometry

Adding stamps to `TerminalGeometry` or `TerminalScrollbackRow` would change
public equality and charge every renderer and inspection consumer for a
test-only need. Internal test-facing access gives the oracle the required state
without widening the product contract.

### Erase-shaped cleanup heuristics

Keying cleanup on a shell's erase pattern describes an incident rather than
the contract. zsh performs the same pad-and-wrap transition without fish's
trailing erase. OSC 133 prompt marks and redraw declarations are the portable
signals for ownership and repaint scope.

## References

- [OSC 133 dialect findings](../research/24-osc-133-dialect/findings.md) -- F16
  derives the vacate/reclaim protocol and output floor; F17 derives the
  logical-line boundary and its ordering constraint; F22 records the
  height-only content loss and shows fish, bash, and zsh clearing their own
  rows on SIGWINCH.
- [OSC 133 dialect decisions](../research/24-osc-133-dialect/decisions.md) --
  the shell-specific `redraw=1` and `redraw=last` promises this design consumes.
- [OSC 133 prompt redraw implementation plan](../../plans/impl/2026-07-22-1422-osc-133-prompt-redraw.md)
  -- the original parser and resize contract.
- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#SemanticPromptRow`
  -- the row states implementing this lifecycle.
- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#clearPromptForResizeIfNeeded`
  and `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#reclaimStalePromptHeads`
  -- the vacate and reclaim phases.
