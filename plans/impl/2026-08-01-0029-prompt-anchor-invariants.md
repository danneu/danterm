# Encode the prompt-anchor invariants: executable oracle, resize-injection sweep, and design record

## Context

The seven F16/F17 fixes to `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`
(e97345e..53cedd3) converged on a deliberate design for OSC 133 prompt anchoring:
a vacate/reclaim two-phase protocol over rows the shell has promised to repaint,
and a logical-line-integrity rule for prompt heads. The investigation that
audited the arc concluded the anchor code is sound but the design is encoded
only as distributed code comments, and its invariants are enforced yet not
executable: every one of the seven bugs was found by a live-pane recording, and
each recorded fixture today pins only the incident it captured. The general
lesson of the research doc (`docs/research/24-osc-133-dialect/`) is that
recordings are the right stimulus and the missing piece is a general oracle --
so that every recording, present and future, tests every invariant, not just
the one it was recorded for.

Desired outcome: the invariants are stated once, authoritatively, for future
developers; they run as executable checks over every recorded fixture replay;
and a deterministic resize-point-injection sweep probes the timing windows
(a resize landing between a shell's erase and its re-mark) that hand-built
synthetic cases missed twice.

Load-bearing premises, with evidence:

- The anchor design reduces to two invariants that explain all seven fixes
  (investigation of 2026-07-31; commit messages of e97345e..53cedd3).
- `NeutralTerminalRecording.replay` already exposes a per-event `inspect` hook
  that nothing uses (`lib/TerminalCore/Sources/TerminalCoreRecording/NeutralTerminalRecording.swift#replay`).
- Per-row prompt stamps are `private` to `Terminal`; no inspection surface
  reaches them, so tests currently assert on rendered text only.
- The repo has an established deterministic seeded-generator pattern
  (`lib/TerminalCore/Tests/TerminalCoreTests/TerminalScrollbackBudgetTests.swift#seededTwinOracleAndChunkInvariance`).
  It is precedent for the generator only: it prints diagnostics, not a
  targeted rerun selector, which PO3 requires beyond it.
- Recorded fixtures preserve real PTY chunk boundaries and are never merged,
  split, or reordered on disk (`scripts/terminal-tape-to-fixture.py`; tape docs).

## Decision

Three deliverables, in one arc:

**D1 -- Design record.** A new ADR-style note in `docs/design/` states the
prompt-anchor design as the authority future work cites: the two invariants
below, the vacate/reclaim protocol (who owns a row in each state, why vacating
blanks in place while reclaiming deletes), the scrollback boundary (AR1), and
the rejected alternatives (RI1-RI3). Indexed in `docs/design/index.md`. The
`SemanticPromptRow` enum doc in `Terminal.swift` gains the state lifecycle
(prompt -> vacated -> repainted-or-reclaimed) and points at the ADR; the four
existing comment sites shrink to their local deltas rather than each
re-narrating the protocol.

**D2 -- Executable oracle.** The shared test assertions
(`lib/TerminalCore/Tests/TerminalCoreTests/TerminalGridAssertions.swift`) gain
semantic-prompt snapshot checks for I1, I2, and I4. Universal coverage comes
from a corpus test that discovers every recording in `Fixtures/danterm/` by
directory enumeration (extending the `TerminalFixtureTests#recordingFixtureURLs`
precedent) and replays each through the oracle per event via
`replay(inspect:)` -- a fixture added later is covered without any test edit.
Replay loops that transform the authored stream before feeding it (the dialect
suite rewrites `redraw=` bytes, the truncation cases replay a prefix)
additionally run the oracle directly. The transition invariants I3, I5, and I6
are proven by targeted behavioral tests instead (see the proof-shape rule
below). Prompt-stamp state becomes visible to the test target through a
test-facing internal accessor following the `withUnlimitedScrollbackForTesting`
precedent -- a computed property that costs nothing unless a test calls it; the
public geometry surface does not change, and no observation state, snapshots,
or hooks live on production paths.

**D3 -- Resize-injection sweep.** A seeded, deterministic replay mode injects
synthetic resize events into decoded fixture event streams at chosen points --
including byte offsets inside a feed chunk, which is where the real windows
open -- and runs the snapshot oracle per event alongside observable-outcome
assertions: completed command output preserved, cursor and content coherent,
fixture-specific prompt outcomes intact. It does not claim to reconstruct an
internal mutation from coarse before/after deltas. Recorded fixtures are never
edited; the transform operates on the decoded events at replay time.

Decisive constraints:

- No public API change: `TerminalGeometry`/`TerminalScrollbackRow` keep their
  fields and `Equatable` behavior.
- Determinism: no wall clock or system randomness anywhere in the sweep; the
  failure message alone must suffice to reproduce a failure (seed, injection
  point, fixture).
- `just test` runtime stays acceptable: the per-event check is a cheap
  geometry-level pass; the expensive whole-terminal validation
  (`expectValidGrid(_ terminal:)`) remains end-of-scenario.
- Docs travel with the behavior they describe, per repo convention.

## Invariants

The behavioral contract of the anchor design. I1-I2 are the two general
invariants; I3-I6 are their load-bearing corollaries as enforced today.

- **I1 (ownership).** Rows between the top of the current prompt block and the
  newest prompt head, which a `redraw=1` shell has promised to repaint and has
  not yet, belong to the terminal. Vacating them is a provisional grant
  recorded as explicit state, never inferred from cell contents; a vacated row
  is either repainted by the shell or, while still empty, reclaimed when the
  next prompt head is stamped.
- **I2 (logical-line integrity).** A prompt head stamped at column 0 begins a
  logical line: no row above it may retain a soft-wrap claim into it, and a
  soft-wrapped prompt row sitting directly above a newer head is stale debris.
- **I3 (output floor).** No prompt blanking or reclaim ever modifies the last
  command's output: the row where output began is a hard floor for every
  upward prompt-block search.
- **I4 (vacating is total).** Emptying a prompt row clears its wrap claim along
  with its cells, so reflow never splices a vacated row's width in blanks into
  a live logical line.
- **I5 (geometry coherence).** A reclaim moves rows and the cursor together,
  only within a single scroll region, never on the alternate screen; the
  cursor remains in bounds afterward.
- **I6 (mode scope).** Vacate and reclaim run only under the redraw mode the
  shell declared; under `redraw=last` nothing above the final prompt row is
  ever taken.

Every I-entry gets an explicit proof shape, and the shape must match what the
invariant quantifies over:

- **State invariants** -- properties of the grid after an event -- get
  snapshot checks in the oracle.
- **Transition invariants** -- properties of what a mutation was allowed to
  change (I3: the last command's output survives blanking and reclaim; I5: a
  reclaim moves rows and cursor together or not at all; I6: nothing above the
  final prompt row is taken under `redraw=last`) -- get controlled behavioral
  tests that bracket the relevant operation precisely: the pre-`d1eb808`
  output-loss shape, permitted and guard-blocked reclaims, and resize
  blanking under each declared redraw mode. A snapshot cannot prove these:
  the pre-`d1eb808` bug deleted finished output and left structurally valid
  rows, stamps, and an in-bounds cursor behind. But a universal external
  trace cannot prove them either: one feed event reduces to many parser
  actions, so a later action in the same event can mask a faulty reclaim
  delta; resize blanking is followed by reflow inside the same `resize()`
  call, so external before/after snapshots bracket blanking plus reflow, not
  the blanking alone; and a mutation that incorrectly never fires produces no
  delta to validate. Mutation-anchored observation from inside production
  code closes those gaps but was implemented and withdrawn: it cost two
  full-grid deep snapshots per resize in release builds to serve a test-only
  need. The transition guarantees stay executable through the behavioral
  brackets; they are deliberately not advertised as mutation-level checks
  over every authored feed chunk.

Only genuinely unobservable intermediate parser states may fall back to a
documented domain statement instead of a check (AR2); an observable resize or
reclaim transition never qualifies. Reflow re-packing content into a row still
stamped vacated (which the reclaim then declines) is the known case to state
precisely.

## Proof obligations

- **PO1.** The oracle passes per-event over every `Fixtures/danterm/`
  recording, discovered by enumeration rather than named lists, so a future
  fixture cannot be silently excluded. This proves that the snapshot
  invariants I1, I2, and I4 describe the shipped behavior; targeted behavioral
  tests prove the transition invariants I3, I5, and I6.
- **PO2.** Every check in the oracle can fire: for each, a test demonstrates a
  stream or state that violates it and is caught. An oracle that cannot fail
  proves nothing.
- **PO3.** The resize-injection sweep is reproducible: the same seed yields the
  same injection schedule, and every failure message carries a concrete rerun
  selector -- fixture, seed, injection point -- sufficient to rerun that
  single case. The sweep must be able to place a resize inside a feed chunk's
  byte stream, since the F16-round-5 window (erase to re-mark) exists only
  there.
- **PO4.** The sweep passes over the dialect fixtures at the committed seed
  budget -- the regression gate this plan exists to create.
- **PO5.** Existing behavior stays fixed: the current dialect, fixture, and
  resize suites pass unchanged.
- **PO6.** I5's guard domain is exercised behaviorally, not only via the
  checker: tests drive the production reclaim path with a reclaim candidate
  under the alternate screen and under a mismatched DECSTBM scroll region and
  verify no reclaim occurs, plus a permitted reclaim verifying rows, cursor,
  and content move together.

## Non-goals

- Kitty-style copy-back anti-flicker (restoring old prompt content verbatim
  after reflow). Deferred until flicker is actually observed; it would put
  content back into rows the reclaim identifies by emptiness.
- Reclaiming debris from scrollback (see AR1).
- Restructuring the anchor code itself: no unification of the resize and
  stamp paths, no logical-line-first grid model. The investigation found the
  code sound; this plan encodes and verifies it.
- Extending the capture harness or fixture schema; recorded fixtures are
  stimulus authority and stay byte-identical.

## Accepted risks

- **AR1 (scrollback boundary).** A stale head or vacated blank that scrolls
  out of the live grid before its reclaim runs is permanent history. The
  window is one repaint burst wide, and rewriting scrollback would be worse
  than the debris. Documented in the ADR, not fixed.
- **AR2.** Genuinely unobservable intermediate parser states -- and only
  those -- are documented with their domain rather than checked; a violation
  confined to such a state would not be caught by the oracle. Observable
  resize and reclaim transitions never fall under this entry (they carry
  targeted behavioral tests per the proof-shape rule). The ADR states each documented
  domain so the gap is deliberate and visible.

## Rejected ideas

- **RI1 -- stored prompt-block anchor** (an index instead of per-row stamps):
  requires maintenance at every row-shifting operation; stamps travel with
  rows for free. This is why the walks stay.
- **RI2 -- exposing prompt stamps on the public geometry types**: changes
  public `Equatable` behavior and taxes every geometry consumer for a
  test-only need.
- **RI3 -- erase-shaped heuristics** (keying cleanup on shell erase patterns
  instead of marks): already rejected with cause in 53cedd3 -- zsh runs the
  same pad-and-wrap without the trailing erase. Marks are the contract.

## Implementation discretion

- The exact executable phrasing of each invariant check within its assigned
  proof shape (snapshot vs transition), provided every I-entry is checked in
  the matching shape or falls under AR2's narrow domain.
- The exact bracket each transition-invariant behavioral test drives, provided
  the bracketed operation is the one the invariant constrains and no
  observation state, snapshots, or hooks are added to production paths to
  serve it.
- The injection schedule's shape: seed count, width sequences, and how
  injection points are drawn -- provided PO3/PO4 hold and runtime stays inside
  the decisive constraint.

## Verification

- `just test` -- the full local gate; PO1/PO4/PO5 all live inside it.
- Targeted: `swift test --package-path lib/TerminalCore --filter
  TerminalShellDialectTests` and the new suites.
- For PO2, run the oracle's can-fire tests and confirm each check reports the
  violating event index.
- Docs: `docs/design/index.md` links resolve; `scripts/core-purity-lint.sh`
  still passes (comment edits in `Terminal.swift` touch lint-guarded ground).

## Commit progress

- [x] **1. docs(design): record the prompt-anchor design as an ADR** -- the
  invariants I1-I6 with their domains, the vacate/reclaim lifecycle, AR1, and
  RI1-RI3; index entry; `SemanticPromptRow` lifecycle doc pointing at it;
  existing comment sites reduced to local deltas. Doc-only, no behavior
  change; lint-clean.
- [x] **2. test(terminal): execute the invariants over every recorded
  fixture** -- test-facing access to per-row prompt stamps, the semantic
  oracle (snapshot checks in `TerminalGridAssertions`, mutation-anchored
  transition checks through the test-facing seam), the
  directory-enumerating corpus test plus direct wiring into the transforming
  replay loops, the can-fire tests, and the I5 guard-domain behavioral tests.
  Discharges PO1, PO2, PO5, PO6.
- [x] **3. test(terminal): scope the corpus oracle to snapshot invariants and
  prove transitions behaviorally** -- remove the production observation
  state, transition snapshots, and mutation hooks that commit 2 threaded
  into `Terminal.swift` (two full-grid deep snapshots per resize, in release
  builds, to serve a test-only need); keep the zero-cost stamp accessor and
  the universal snapshot oracle for I1/I2/I4; add the I3 output-floor and I6
  redraw-scope behavioral brackets beside the existing I5 guard-domain
  tests. Re-proves PO2, PO5, PO6 under the revised proof-shape rule.
- [ ] **4. test(terminal): sweep resize injection points over the dialect
  recordings** -- seeded deterministic event-stream transform with
  intra-chunk placement, snapshot oracle per event, observable-outcome
  assertions (preserved completed output, coherent cursor and content,
  fixture-specific prompt outcomes), and a rerun selector (fixture, seed,
  injection point) in every failure message. Discharges PO3, PO4.

## Implementation notes

- The three pre-schema live-pane recordings in `Fixtures/danterm/` retain their
  original provenance bytes. The corpus oracle substitutes valid DanTerm
  provenance only in memory before using `NeutralTerminalRecording.replay`, so
  provenance validation does not exclude their authored event streams.
