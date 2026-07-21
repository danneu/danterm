# Milestone 6 slice 8: logical damage and damage-aware redraw equivalence

## Context

Roadmap gate [plan-terminal-engine/14-roadmap.md:230](../../plan-terminal-engine/14-roadmap.md)
-- "Logical damage and full redraw produce the same visible state" -- is
unchecked, and the engine has no damage model at all: every committed frame
invalidates the whole pane view, and neither the core, the planner, nor the
view has any dirty/damage concept. The component contracts already require
one:

- [04-terminal-core.md](../../plan-terminal-engine/04-terminal-core.md):11-14,
  :34-36, :66-69 -- the core "produces ordered output bytes, damage, and
  semantic effects"; determinism and chunk-invariance include damage; the
  representation is implementation discretion provided observable invariants
  hold.
- [09-renderer.md](../../plan-terminal-engine/09-renderer.md):11-13, :38-39,
  :44-45, :54-55 -- the renderer consumes damage but does not own semantics;
  damage outside the visible pane causes no drawing work; a newly visible pane
  can produce a complete frame; and the standing proof obligation: "Damage
  redraw, including after primary- and alternate-screen width or height
  changes, produces the same final frame as a full redraw."
- [13-power-performance.md](../../plan-terminal-engine/13-power-performance.md):43-46
  -- "Damage retention is bounded by active-grid state plus a full-redraw
  marker; output bursts do not create an event-by-event render queue";
  coalescing never loses the final visible state.
- [03-engine-architecture.md](../../plan-terminal-engine/03-engine-architecture.md):25-28,
  :57-58 -- render damage stays on the pane data path and never enters
  DanTerm's top-level Elm model.
- [docs/research/1-external-tests.md](../../docs/research/1-external-tests.md):101-104,
  :282-284 -- the damage seam activates "when damage first becomes
  observable": define DanTerm-owned neutral logical-damage expectations using
  `62screen_damage` as a case source, without adopting libvterm's rectangle
  merging or moverect/callback topology as normative.

This slice unlocks the later idle-work, cursor-blink, and performance proofs
without entering Milestone 7 protocol work.

### Verified premises (against the working tree)

- `Terminal` is a pure `Equatable, Sendable` value that is itself the snapshot
  (Terminal.swift:34); replies already use an accumulate-and-drain channel
  (`drainReplyBytes`, Terminal.swift:332).
- Grid-content mutations funnel through `invalidateInspection(inViewportRows:)`
  / `(inScrollbackRow:)` (Terminal.swift:1119/:1126, guarded by
  `selection != nil || search != nil`); alternate-screen switches, hard reset,
  and cross-screen resize funnel through `clearInspection()`
  (Terminal.swift:1113); a primary-only resize does not (Terminal.swift:389-391).
- The viewport equals the live grid whenever `viewportState == .following`
  (scrollProjection, Terminal.swift:456-483); the alternate screen forces
  following.
- Cursor and selection mutate at many non-funneled sites (print advance, wrap,
  restore, eviction clamps), so producer-site auditing alone cannot guarantee
  coverage -- sufficiency must be proven corpus-wide.
- The pane owner conflates update signals (`bufferingNewest(1)`,
  TerminalPTYHost.swift:143-147) and snaps the viewport to bottom before every
  keystroke (TerminalPTYHost.swift:177), so viewport-state damage must record
  only on actual change or every keystroke dirties the terminal value.
- The pane session gates commits on whole-value inequality, DEC 2026, and
  visibility (TerminalPaneSession.swift:401-415, :322, :211-215); reveal plans
  exactly one complete frame.
- The view is flipped, retains the last plan, and invalidates the whole view
  on every publish (SwiftTerminalSessionView.swift:59, :95-104, :443-450).
- Neutral replay fires an inspection hook at every event
  (NeutralTerminalRecording.swift:517), and a corpus-wide planning property
  test already walks every libvterm fixture
  (RenderCorpusPlanningTests.swift:35-45).
- Whole-value replay-equality tests exist on both the host and session suites
  (e.g. TerminalPaneSessionControllerTests.swift:741) and must stay meaningful.
- The libvterm manifest pins 34 files; `t/62screen_damage.test` is absent. Its
  16 cases almost entirely assert libvterm's internal damage-merge/moverect
  callback machinery; the observable residue is content behavior mostly pinned
  by existing fixtures.
- Roadmap audit: the unchecked reflow-anchor item (14-roadmap.md:218-220) is
  already proven by `TerminalViewportTests.resizePreservesBrowsingAnchor`
  (width and height changes remap a browsing anchor without following), with
  `outputPreservesBrowsingAnchorAndContent` and `evictionClampsBrowsingAnchor`
  pinning the output and eviction legs. It needs a judgment note, not code.

User-settled toggles: damage vocabulary is row-granular (damaged viewport rows
plus a full-redraw marker; finer granularity deferred); the 62screen_damage
adaptation is ledger plus one adapted content fixture, with the corpus
equivalence property and producer tests serving as DanTerm's neutral
logical-damage expectations (no fixture-schema damage field).

## Decision

**Scope:** the pure core accumulates bounded row-granular render damage with
drain semantics; one drained damage value rides each committed frame through
the pane owner and gated pane-session commits to damaged-row AppKit
invalidation; a pure clip narrows planned work to damaged rows; a corpus-wide
property proves incremental damage redraw reproduces the full-redraw frame at
plan and pixel level; the 62screen_damage ledger is adopted; and the two
roadmap gates are checked. Nothing else.

- **D1 -- Core-owned damage vocabulary.** `TerminalCore` gains a public damage
  value: a set of damaged viewport row indexes plus a full-redraw marker, in
  canonical form (full implies no row set). Damage accumulates inside
  `Terminal`, participates in its equality, and is consumed through a mutating
  drain on the model of the reply-byte channel. A fresh terminal starts fully
  damaged.
- **D2 -- Conservative escalation.** Mutations while browsing, any actual
  viewport-mapping change (browse navigation, follow snap, eviction clamp,
  search reveal), resize, screen switch, and reset drain as full damage.
  Scrollback-only mutations invisible while following drain as nothing.
  Redundant viewport writes (a follow snap while already following) record
  nothing.
- **D3 -- Owner drain.** The pane owner exposes draining reads used by the
  session's consume loop and synchronous fences, so every value reaching the
  commit-dedupe comparison carries an empty accumulator. Existing snapshot
  reads stay non-draining, preserving whole-value replay equality.
- **D4 -- Gated accumulation.** The pane session unions drained damage across
  suppressed commits (DEC 2026, hidden, equality-deduped) and clears it only
  when a plan is actually published. A controller created visible immediately
  retains one complete full-damage frame; creation while hidden defers that
  frame until reveal. A newly planned frame equal to the current one publishes
  nothing.
- **D5 -- Damage-aware planning.** `planFrame` stays stateless and full-frame.
  `TerminalRenderPlanning` gains a pure clip from a full plan and a damage
  value to the damaged-row subset; the committed frame is published to the
  view together with its damage.
- **D6 -- AppKit invalidation.** The view retains the complete plan and can
  always repaint fully (expose, reveal). Row damage maps to exact cell-aligned
  row bands and invalidates only those rects; full damage and geometry changes
  invalidate the whole view. Drawing remains full-plan-under-clip, which is
  pixel-correct for partial rects.
- **D7 -- Ledger and damage seam.** `t/62screen_damage.test` joins the
  manifest (34 -> 35 files) with per-case dispositions: the damage-merge,
  chunking, and moverect machinery is out-of-scope; content-bearing cases are
  superseded by existing fixtures or adapted into one new fixture pinning the
  alternate-screen-switch and DCH+scroll screen-content residue. The corpus
  equivalence property plus the producer tests discharge the research doc's
  damage-seam obligation; the neutral fixture schema gains no damage field.
- **D8 -- Roadmap.** Check 14-roadmap.md:230 with a slice judgment; check
  :218-220 with the audit judgment citing the three existing viewport tests.
  Add the Slice 8 entry under Milestone 6.

## Invariants

- **I1 (deterministic, bounded accumulation)** Damage accumulation is
  deterministic per mutation sequence and independent of feed chunk
  boundaries; the value is canonical and bounded by viewport rows plus the
  full marker.
- **I2 (sufficiency)** Between consecutive drains, every viewport row whose
  planned rendering differs lies inside the drained damage, and any change to
  the column count, row count, frame backgrounds, or viewport mapping drains
  as full damage.
- **I3 (drain canonicality)** After a drain, damage bookkeeping is a function
  of current visible state alone; values crossing the owner boundary through
  the draining reads carry empty accumulators, so commit-dedupe equality means
  visible-state equality, and the non-draining snapshot reads keep existing
  whole-value replay equality intact.
- **I4 (pending coverage)** The pane session's retained damage always covers
  every visible difference between the last published plan and the current
  terminal, and only publishing clears it.
- **I5 (composition and completeness)** Published damage composes under union
  across display passes, and the view can always produce a complete correct
  frame from retained state alone -- window expose, reveal, and a newly
  visible pane each yield a full frame.
- **I6 (planning purity)** `planFrame` is unchanged, stateless, and
  deterministic; the clip is pure, preserves canonical form, and ignores
  damage outside the visible viewport, which causes no planned work.
- **I7 (containment)** Damage flows only Terminal -> pane owner -> pane
  session -> view; nothing damage-shaped enters the top-level Elm model.

## Proof obligations

- **PO1 (I2, I6; primary proof; discharges 09-renderer.md:54-55 and roadmap
  :230)** A corpus property over every neutral fixture (libvterm and danterm
  directories), at every replay event: the undamaged rows of the new full plan
  equal the previous full plan's rows, and overlaying the damage-clipped new
  plan onto the previous plan reproduces the new plan exactly. The resize and
  alternate-screen fixtures discharge the width/height-change clause.
- **PO2 (I1, I2)** Producer behaviors: damage for printing, cursor movement
  (old and new position), selection set/drag/clear (old and new spans), erase,
  and scroll-region edits confined to the region; full escalation for
  alternate-screen switch, reset, resize, browsing-time mutation, and viewport
  navigation; no spurious damage for a redundant follow snap or a drain with
  no intervening mutations. Chunk-invariance of damage rides the existing
  fixture replay because damage participates in terminal equality.
- **PO3 (I3, I4; discharges 13-power-performance.md:43-46 and
  09-renderer.md:39)** Consecutive owner drains yield empty damage the second
  time; DEC 2026 suppression accumulates and releases one commit whose damage
  covers the suppressed span; a controller created visible retains exactly one
  complete full-damage frame before any terminal mutation, and a later no-op
  synchronization creates no additional commit; a controller created hidden
  and revealed before any terminal mutation publishes exactly one complete
  full-damage frame, and repeating the visible state publishes nothing; hidden
  output plus reveal also publishes exactly one complete full-damage frame;
  plan-equal commits publish nothing; the existing whole-value replay-equality
  suites stay green with at most a drain-normalization adjustment on each side
  of the comparison.
- **PO4 (I5, I6)** Clip properties: determinism, identity under full damage,
  out-of-viewport rows ignored. Pixel equivalence: drawing the previous frame,
  then the new full plan clipped to the invalidated bands, is byte-identical
  to a fresh full render of the new frame (reusing the executor suite's bitmap
  support).
- **PO5 (D7)** Manifest coverage passes with 35 files and all 16 dispositions
  carrying rationales; the adapted fixture passes replay under all chunk
  strategies.
- **PO6 (I7)** The existing purity and boundary lints in `just test` stay
  green.

**Slice exit gate:** `just test` green; `just build-run` sanity check that a
live pane still renders output, selection, browsing, and resize correctly
(the AppKit invalidation leg has no automated harness -- see AR4).

## Non-goals

- Scroll blitting or any moverect analog.
- Column-span or rectangle damage granularity.
- Render-time diffing or partial plan construction inside `planFrame`.
- A damage expectation field in the neutral fixture schema.
- Executor draw-call culling by dirty rect beyond the AppKit clip.
- Coalescing timers, frame pacing, cursor blink, or idle-work scheduling
  (later Milestone 6/9 work that this slice unlocks).

## Accepted risks

- **AR1** Damage-only value changes can cause extra owner wakeups and
  replans; bounded by signal conflation and the plan-equality dedupe.
- **AR2** Planning still walks the whole viewport per commit; this slice
  reduces invalidation and rasterization, not planning CPU.
- **AR3** Retained pending damage across suppressed commits can over-repaint;
  the cost is one over-broad invalidation, never a stale frame.
- **AR4** The view-level invalidation path is proven at the executor-pixel
  level plus manual verification, not through an AppKit harness that observes
  invalidation rects.

## Rejected ideas

- **RI1** Excluding damage from `Terminal` equality -- requires a manual `==`
  over dozens of stored properties (silent-drift hazard), and equality
  participation is what makes damage chunk-invariant and replay-testable for
  free.
- **RI2** Draining inside the existing snapshot reads -- breaks the
  whole-value replay-equality symmetry the host and session suites rely on.
- **RI3** A damage-parameterized `planFrame` -- couples the stateless planner
  to cross-frame state; the pure clip keeps planning deterministic.
- **RI4** Per-checkpoint damage fields in the neutral schema -- lower-bound
  assertions are redundant with the corpus property, and exact assertions pin
  discretionary conservatism the contracts deliberately leave open.
- **RI5** An event-by-event render queue -- forbidden by
  13-power-performance.md:45; the bounded union plus full marker is the
  sanctioned coalescing form.

## Implementation discretion

- Damage set representation and producer wiring (funnel hooks versus
  drain-time diffing of cursor/selection references) provided I1-I3 hold.
- Naming: avoid overloading "invalidate", which the core already uses for
  inspection-anchor invalidation.

## Commit progress

- [x] 1. feat(engine): add bounded logical damage accumulation
- [x] 2. feat(pty): carry damage through gated pane commits
- [ ] 3. feat(renderer): redraw only damaged terminal rows
- [ ] 4. test(engine): adopt damage fixtures and close roadmap gates

## Implementation notes

- Core damage uses the existing grid-mutation funnels plus constant-time
  cursor, selection, and viewport snapshots around parser actions. A full
  visible-grid snapshot per action preserved correctness but made sustained PTY
  output scale with viewport size per character and violated the timing suite.
- The pane session publishes damage through a new frame callback while retaining
  the plan-only callback until the renderer slice moves the AppKit consumer.
  This keeps the PTY commit independently buildable without prematurely changing
  view invalidation behavior.
