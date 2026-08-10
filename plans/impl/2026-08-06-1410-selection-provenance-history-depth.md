# Make selection provenance capture independent of history depth

## Context

The selection-overwrite fix (commit caa75e6a) records, at selection creation,
whether the selection covered non-empty text, so width reflow can drop a
formerly non-empty selection whose anchors collapse. It captures that
provenance as `selectedText?.isEmpty == false`, and `selectedText` walks the
entire history projection (`activeProjectionRows()` /
`allPaintedDisplayRows()`). `setSelection` runs on every pointer-move of a
drag, so with saturated scrollback each mouse move materializes and frees the
whole scrollback on the serial PTY host queue. A 20s `sample` under
`saturate-scrollback.sh --stream` shows ~14.7k/15k of that queue's samples in
this walk and the main thread blocked behind it on the frame fence:
multi-second pane freezes while dragging.

The engine already states the invariant this violated, at
`Terminal.swift#activeProjection`: every point-local query reads through the
`ProjectionRows` facade, which is what keeps a pointer gesture's cost
independent of retained history. The same defect class exists at
`TerminalPaneSession.hasSelection`, which answers a boolean for menu
validation by materializing the whole projection (`selectedText != nil`).

## Decision

Capture the provenance with a bounded early-exit probe: does the range contain
any projection unit with text? The probe reads rows only through the
point-query facade (`activeProjection()`), inspects only rows the selection
covers (plus, at worst, the already-accepted blank-tail degenerate that
existing point queries like `terminalTokenRange` share), and reuses the
existing single definition of row-unit emission (`forEachRowTextUnit`) rather
than re-deriving wide/padding/truncation rules. `selectAll` derives the flag
from the projection units it already holds instead of walking again.
`TerminalPaneSession.hasSelection` becomes a read of selection presence
(`selectionRange != nil`), which is equivalent because a present-but-empty
selection deliberately reports a non-nil empty `selectedText`.

This is a pure performance change: the flag's value, the reflow-collapse
behavior it drives, and Copy enablement are unchanged in every reachable
state. No new cached state is introduced — a cached "last content row" would
add an invariant every grid mutation must maintain, for a probe that
early-exits in the common case anyway.

## Invariants

- **I1.** For every reachable selection — both `setSelection` overloads and
  `selectAll`, including erased content, blank buffers, seam-spacer rows,
  soft wrap, wide characters at range edges, padding runs, selections
  covering only a line break, and the alternate screen — the provenance flag
  equals what `selectedText?.isEmpty == false` computes. The reflow-collapse
  behavior of the prior plan is untouched.
- **I2.** `setSelection` performs no whole-projection materialization, and its
  point-query (locate) cost is independent of retained history depth: bounded
  by the rows the selection covers plus the blank-tail degenerate.
- **I3.** `hasSelection` performs no whole-projection materialization and is
  true exactly when a selection exists, including a present-but-empty
  selection (Copy enablement unchanged).
- **I4.** The probe reads rows only through the point-query facade, and no
  new cached projection state (last content row, cached flag) is added.

## Proof obligations

- **PO1 (I1).** Property-style equivalence sweep: over a fixture matrix
  covering every projection-emission branch named in I1, iterate anchor pairs
  (including out-of-range anchors, which exercise boundary clamping) and
  assert the flag equals `selectedText?.isEmpty == false`; assert `selectAll`
  once per fixture. The assertion reads the real flag from the engine, not a
  reimplementation.
- **PO2 (I2).** Counter-based, per `agent-docs/measurement-discipline.md`: no
  wall-clock gate. Assert zero whole-projection materializations during each
  of the two `setSelection` overloads — `setSelection(_:)` as the pointer-drag
  path and `setSelection(from:to:)` on its own — and a locate count that is
  equal at shallow and deep history for a drag anchored in history rows.
  `selectAll()` performs exactly one whole-projection materialization, its
  inherent one; two would mean the flag walked again. Each instrument carries a calibration
  arm proving it is wired (the existing `LocateCounter` reads zero against
  today's defect, so the whole-projection instrument must observe
  `activeProjectionRows()` itself). Verify red-first: the materialization
  gate must fail against the pre-fix implementation before the fix lands.
- **PO3 (I3).** A present-but-empty selection (Select All on a blank buffer)
  still reports `hasSelection` true, and the read performs no
  whole-projection walk.
- **PO4 (I1).** The caa75e6a pins stay green by their own mechanism:
  `erasedSelectionDropsOnlyOnCollapsedReflow`,
  `promptSelectionUsesReflowDomain`,
  `heldDragSelectionNeverFlickersAcrossRepaints`.

## Non-goals

- Bounding `text(in:)` itself. Explicit Copy remains a one-shot whole-history
  walk; it is a cold path and its correctness is not worth coupling to a
  performance fix. (Also rejected as the fix here: even bounded to the range,
  building the selection's text per pointer-move is O(selection) per move —
  quadratic across a long drag — where the probe is early-exit.)
- Any change to what the provenance flag means or when reflow drops a
  selection.

## Accepted risks

- **AR1.** A selection over blanks above an all-blank history tail costs one
  locate + one row materialization per blank row. This is the same degenerate
  already accepted for existing point queries, and strictly better than the
  status quo's unconditional full walk.
- **AR2.** No wall-clock benchmark is claimed; counters are the gate.
  `measurement-discipline.md` documents the ratio-flake history that rules
  timing out.

## Rejected ideas

- **RI1.** Anchor-distance provenance (`start != end`): cannot distinguish a
  deliberate selection over blank cells from selected content later erased —
  the reason the prior plan chose content provenance.
- **RI2.** Deferring the capture to reflow time: the content has already
  changed by then (erase precedes the width change); provenance must be
  captured at creation.
- **RI3.** Caching last-content-row or maintaining the flag incrementally:
  new state with a maintenance invariant on every grid mutation, bought to
  optimize a probe that already early-exits.

## Implementation discretion

- Probe decomposition, naming, and traversal strategy (including how lazily
  the last-content-row gate is computed), provided I4 holds.
- How the flag is exposed to the equivalence test, the exact locate-count
  bound, and whether the PTY-target `hasSelection` assertion uses counters or
  a seam.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` — the three flag
  sites (`setSelection(from:to:)`, `setSelection(_:)`, `selectAll()`), the
  new probe, the whole-projection instrument site.
- `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift` —
  `hasSelection`.
- Tests: `lib/TerminalCore/Tests/TerminalCoreTests/` (equivalence sweep;
  perf pin follows the `TerminalFrameLocateTests` shape).

## Verification

- `just test` green, including the new equivalence sweep and counter pin;
  red-first check for PO2 recorded during implementation.
- Targeted: `swift test --package-path lib/TerminalCore --filter
  TerminalSelectionTests` (and the new test suites).
- Manual, the reported scenario: `just launch-slot`, run
  `./scripts/saturate-scrollback.sh --stream`, click-drag repeatedly while
  streaming — selection tracks the pointer with no multi-second freeze; Copy
  still yields the text under the highlight; menu Copy enablement unchanged
  on an empty-buffer Select All.
