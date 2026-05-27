# Plan: document why per-reconcile projection scans are intentionally O(panes x alerts)

## Context

A performance audit flagged (MEDIUM) that the reconcile path rescans `model.alerts`
per pane/tab and rebuilds `model.allPanes` several times per sweep:

- `desiredPaneToolbar` (`app/Projections.swift:211-227`) does `model.alerts.count { $0.paneId == pane.id && $0.isUnread }` per pane.
- `desiredFocusBorders` (`app/Projections.swift:181-190`) does the same per-pane scan via `paneHasUnreadAlert`.
- `desiredSidebar` (`app/Projections.swift:372-395`) is actually the largest: it scans each tab's alerts twice -- once for the tab row (`unreadAlertCount`) and again summed into its group row (`groupUnreadAlertCount`), each building a fresh `Set(allPaneIds(...))`.
- `model.allPanes` (`app/Model.swift:224`) is walked 4x per `reconcile()`: `reconcileSurfaceExistence` (via `allPaneIds`), `reconcilePaneConfig`, `reconcileFocusBorders`, `reconcilePaneChrome`.

The claim is technically correct, but the work is **not worth doing**: `reconcile()`
runs cheaply for two reasons, not one: the only rapidly-firing triggers
(title/cwd/progress) are coalesced to a 75ms sweep (`AppRuntime.reconcileCoalesceInterval`,
`Msg.coalescesReconcile`), while every other message reconciles inline (`.reconcileNow`)
but is human-paced -- so `reconcile()` never runs per render frame or per typed
keystroke. And the heaviest input is hard-capped: `model.alerts` is trimmed to 100 on
insert at `app/Update.swift:731`/`:761`; pane/tab counts have no enforced cap but stay
human-scale in interactive use. Threading a precomputed tally through the pure
projections would couple a deliberately clean, individually-unit-tested layer for no
measurable gain.

The real defect is **locality**: a reader at `Projections.swift:221` has no local signal
that this runs on a cold path, so every perf audit (human or agent) will keep
regenerating this finding. The mitigating rationale lives in another file
(`AppRuntime`/`Msg`) and an impl plan. This change is a docs-only breadcrumb that puts
the rationale where the reader lands and records the accepted tradeoff durably, so the
finding dissolves instead of recurring.

This is non-behavioral (comments + a design-note section). No code path changes, so
there is no failing test to write first.

## Approach

Three touch points. The inline breadcrumb states the conclusion itself (so it is
self-sufficient) and cross-references a new, durable design-note subsection that holds
the full tradeoff and the "measure before optimizing" guidance.

Match house style: the existing block at `app/Model.swift:205-211` ("lookups are
O(tree size) but run per-`Msg`, never on a render frame") is the exact precedent for
this rationale shape and length (a few `//` lines, precise about the constraint). Use
`//` for the standalone rationale block, `///` when extending a declaration's doc.
ASCII only (`--`, `->`).

### 1. `app/Projections.swift` -- the breadcrumb(s) (load-bearing)

The alert-scanning + `allPanes`-walking projections span three separate MARK sections,
and a `//` block governs only its own section. So place the full rationale block once,
then a one-line pointer at each of the other two scan clusters -- otherwise the plan's
locality thesis fails for exactly the scans it most needs to cover.

- **Full `//` rationale block** under `// MARK: - View Reconciler (pure projections +
  diff)` (line 154). This section runs to `applyDiff` (~line 278) and governs
  `desiredFocusBorders`, `desiredPaneToolbar`, and `desiredPaneConfig`. It must convey:
  - These projections rescan `model.alerts` per pane and rebuild `model.allPanes` per
    pass -- O(panes x alerts) and several full tree walks per `reconcile()`.
  - This is intentional, not an oversight. Two legs, not one: the only rapidly-firing
    triggers (title/cwd/progress) are coalesced to ~75ms
    (`AppRuntime.reconcileCoalesceInterval`, `Msg.coalescesReconcile`), and every other
    message reconciles inline but is human-paced (tab/pane creation, focus, sidebar
    ops) -- so `reconcile()` never runs per render frame or per typed keystroke. The
    per-pane factor `model.alerts` is hard-capped at 100; pane/tab counts -- while not
    capped -- stay human-scale. So the cost is negligible at the rate the sweep runs.
  - Pointer: see `docs/design/2026-05-27-model-driven-view-reconciliation.md`
    ("Projection Scan Cost").
- **One-line `//` pointer** at `// MARK: - Window Chrome Projection` (line 287), where
  `desiredWindowChrome` scans via `totalUnreadAlertCount` (~line 323). Just the one-line
  scan-cost note + the design-note pointer, not the full block.
- **One-line `//` pointer** at `// MARK: - Sidebar Projection + Row-Op Diff` (line 329),
  where `desiredSidebar` does the per-tab + per-group double-scan (~lines 379/387) --
  the largest scan and ~230 lines from the :154 block, so it most needs a local signal.
  Same one-line note + design-note pointer.

### 2. `app/Model.swift:224` -- one-line note at `allPanes`

Append one sentence to the existing `///` doc on `var allPanes`: it is walked a few
times per `reconcile()` sweep (by `desiredFocusBorders`/`desiredPaneToolbar`/
`desiredPaneConfig`, plus `allPaneIds` in `reconcileSurfaceExistence`), and that is fine
for the same reason the `Pane Access` block at lines 205-211 already gives -- these run
per-`Msg`, never on a render frame. Do **not** attribute this one to coalescing:
`allPanes` is rebuilt on every *inline* (non-coalesced) reconcile too (pane creation,
focus, sidebar ops), so the human-paced leg -- not the 75ms coalescing leg -- is the
correct reason here. Point to the design note for the full rationale. Covers the
"rebuilt per pass" half where the rebuild actually lives.

### 3. `docs/design/2026-05-27-model-driven-view-reconciliation.md` -- durable home

Add one new subsection `## Projection Scan Cost`, placed after
`## Scheduling And External Invalidation` (ends ~line 129) and before `## Non-Goals`
(line 131). It records, in the repo's ADR voice:

- The accepted tradeoff: per-pass projections deliberately rescan alerts and rebuild
  `allPanes` rather than share a precomputed structure; O(panes/tabs x alerts) is
  accepted for two reasons, not one. (a) The only rapidly-firing triggers
  (title/cwd/progress) are coalesced to ~75ms while all other messages reconcile inline
  but human-paced -- cross-reference the existing `## Scheduling And External
  Invalidation` section for the coalescing mechanism rather than restating it, so the
  two notes cannot drift or contradict. (b) The per-pane factor `model.alerts` is
  hard-capped at 100 (trimmed on insert; see `app/Update.swift:731`/`:761`). State the
  asymmetry explicitly so a future reader is not misled: pane/tab counts are **not**
  capped (`createTab`/`splitPane` enforce no ceiling), only expected to stay human-scale
  in interactive use. Name the largest instance honestly: the sidebar's per-tab +
  per-group double-scan, not the cited toolbar/border scans.
- The measure-first guidance (future direction): if a profile ever shows `reconcile()`
  hot, the unification is a single `allPanes` + unread-alert tally computed once in
  `reconcile()` and threaded into the projections -- covering all five alert helpers
  (`paneHasUnreadAlert`, the inline `.count` in `desiredPaneToolbar`, `unreadAlertCount`,
  `groupUnreadAlertCount`, `totalUnreadAlertCount`) plus the sidebar double-scan. Gate
  this on a measurement; do not do it speculatively, because it couples the pure
  projection layer (signature change to `(AppModel, tally)`). Because the pane/tab bound
  is an expectation, not an enforced invariant, a credible high-pane/high-tab
  performance report is itself a legitimate trigger to revisit -- this note must not be
  cited to wave one off.

The note's `## References` (lines 167-178) already links `app/Projections.swift` and
`plans/impl/2026-05-27-coalesce-reconcile-sweeps.md`, so no reference edits are needed.

## Files to modify

- `app/Projections.swift` -- full rationale block under the `View Reconciler` MARK
  (~line 154); one-line pointers under the `Window Chrome Projection` MARK (~line 287)
  and the `Sidebar Projection + Row-Op Diff` MARK (~line 329).
- `app/Model.swift` -- one sentence on the `allPanes` `///` doc (~line 224).
- `docs/design/2026-05-27-model-driven-view-reconciliation.md` -- new `## Projection Scan Cost` subsection (~after line 129).

Out of scope (deliberately, to avoid over-spreading): no note on the alert helpers in
`app/ModelOperations.swift` -- all three Projections.swift scan clusters (focus/toolbar,
window chrome, sidebar) now carry a local pointer, so a reader landing on a helper is
one hop from a call site that links the rationale. No new standalone ADR -- the existing
reconciliation note owns this area.

## Verification

Comments + markdown only; no behavior changes.

- `just build` -- confirm the dev build still compiles (catches a malformed comment or
  an accidental non-comment edit). No new tests: the change is non-behavioral and the
  existing projection unit tests already pin the scan outputs.
- Read-through, all three scan clusters: a reader at the toolbar/border scan (~:221),
  the window-chrome scan (~:323), and the sidebar double-scan (~:387) each sees a local
  signal -- the full block at :154 states the conclusion (coalesced high-freq triggers +
  inline-but-human-paced rest, alerts capped at 100) without leaving the file, and the
  :287/:329 one-liners point to it. Every pointer resolves to the new
  `## Projection Scan Cost` subsection, which cross-references (not restates) the
  existing `## Scheduling And External Invalidation`.
- Confirm the design-note subsection renders under the right heading and that
  `docs/design/index.md` still lists the note (no index entry change needed -- same
  file, new section).
