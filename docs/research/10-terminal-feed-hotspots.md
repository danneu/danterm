# Terminal.feed hotspots

Research started: 2026-07-28.

## Purpose

This file owns the investigation into CPU cost on DanTerm's **byte-consumption
path** -- `Terminal.feed` and everything it reaches: the escape parser, grid
mutation, damage recording, and inspection invalidation. It was opened by a
whole-app comparison in which the Swift backend used roughly twice the CPU of
the libghostty backend on the same interactive workload, and by the observation
that `Terminal.feed` is the single largest consumer in the app profile while
sitting entirely outside the scope of
[9-plan-render-allocation-hotspots.md](9-plan-render-allocation-hotspots.md).

Scope split from doc 9, which stays authoritative for the plan and draw paths:

| Path | Thread | Owned by |
| --- | --- | --- |
| `Terminal.feed` -> parse, grid, damage | `terminal-pty-host` queue | **this file** |
| `planFrame` | main | doc 9 |
| `drawRenderFrame` | main | doc 9 |

Doc 9 explicitly set feed aside ("sits entirely on the
`com.danneu.danterm.terminal-pty-host` queue and is off this path"). That was
correct for its question and wrong for total process CPU, which sums every
thread. This file exists to carry the part doc 9 excluded.

The evidence boundary it must preserve: everything here is **diagnostic sample
profiling**. No number in this file is a benchmark result, and none of them may
be quoted as one. A directional performance claim requires a paired
`terminal-benchmark-compare.py` run against an explicitly named pre-change
revision, per
[agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md).

IDs (`H*`, `F*`, `D*`) are file-local. References to doc 9 are written as
`9/F3`, `9/D2`, and so on.

## Investigation rules

- **Sample shares are attribution, not timings.** Report every share as a
  percentage of a named inclusive root -- for this file, normally the harness
  root or `Terminal.feed` itself -- and always name the profile artifact.
- **The headless feed harness is the primary instrument.**
  `just benchmark-feed-sample` isolates feed on one thread with no display, no
  PTY, and no AppKit, which is what makes its tree readable as a straight
  breakdown. Use it for attribution and iteration.
- **Anything the harness cannot see must be measured in the app.** The harness
  holds exactly one `Terminal` value, so it does not reproduce the app's
  copy-on-write pressure from retained snapshots (F3). Any claim about that
  class of cost cites an app profile from
  `scripts/terminal-benchmark-profile.sh`, never the headless one.
- **Two profiles minimum before a stack is treated as stable**, and the repeat
  must be of the same workload. The styled pair below satisfies this;
  `incremental-screen-updates` currently has one capture and its numbers are
  directional only.
- **Every change re-posts the feed call tree**, on the same workloads, into the
  finding for that change. A change is not verified by an aggregate moving; it
  is verified by the targeted node shrinking *and* by nothing else inflating to
  absorb the work. Post the tree even when the result is disappointing -- doc 9's
  `9/F4` is the standing example of a real win that quietly gave a fifth of
  itself back to a sibling, and only the tree showed it.
- **Workload shape is part of every claim.** `styled-screen-redraw` is
  redraw-shaped (cursor-home frames, dense SGR, `EL` per row) and is the
  standing proxy for the btop/htop scroll that opened this file.
  `incremental-screen-updates` is localized-edit-shaped. They rank the same
  nodes very differently, so a share without a workload name is meaningless.
- **Correctness first on damage.** Every candidate here touches damage
  recording, where the failure mode is a *missing* repaint -- invisible in a
  benchmark and invisible in most tests. `Terminal.swift`'s own comment on the
  non-bumping damage variants states the invariant: bumping stays the default so
  a miscategorized call site costs a redundant write, never a lost one. Any
  change that narrows when damage is recorded must carry a behavioral test that
  fails without it.

## The instrument

```
just benchmark-feed-sample                                  # styled-screen-redraw, 20s
just benchmark-feed-sample incremental-screen-updates 20
just benchmark-feed-sample all 30
```

`scripts/terminal-feed-profile.py` builds `TerminalCoreBenchmark` in release,
frames a committed corpus workload into the length-prefixed stream the harness
decodes, runs its pre-existing `--profile` mode (a sustained `measureFeedBatch`
loop), attaches `sample`, and writes `sample.txt` plus an `identity.json`
recording commit, dirty state, and workload identity.

What it deliberately includes: the real release-mode parse and grid path, at the
real 179x66 geometry, on committed fixture bytes.

What it deliberately excludes, and therefore cannot be used to argue about:

- the app's retained-snapshot copy-on-write pressure (F3),
- planning, drawing, AppKit, and the dispatch source,
- anything about wall-clock performance -- it is a profiler driver, and unlike
  `terminal-benchmark-compare.py` it builds from the operator's working tree on
  purpose, so it can show where time goes while code is being edited.

## Trigger and current evidence

Three profiles collected 2026-07-28 at commit `557dd4f`, working tree carrying
only the new harness (`scripts/terminal-feed-profile.py`, `justfile` recipe) plus
untracked `notes.md` / `plans/wip/*` files that enter no build.

| Artifact | Workload | Root samples |
| --- | --- | ---: |
| `.build/terminal-feed-profiles/2026-07-28-091444/sample.txt` | `styled-screen-redraw` | 16714 |
| `.build/terminal-feed-profiles/2026-07-28-091624/sample.txt` | `styled-screen-redraw` (repeat) | 16623 |
| `.build/terminal-feed-profiles/2026-07-28-091647/sample.txt` | `incremental-screen-updates` | 16670 |

`.build/` is disposable, so those paths are pointers only; the decision-bearing
numbers are transcribed into F1.

The app-side trigger, from doc 9's own artifact
`.build/terminal-benchmark-profiles/2026-07-27-212440-75867/sample.txt`
(`full-screen-content-churn`, commit `6c58c45`): `Terminal.feed` is 4310 samples
on the pty-host queue against 6088 non-idle main-thread samples, of which
planning is 35.4% and drawing 27.7%. Feed is therefore **roughly 40% of the
app's busy CPU** and was the largest single consumer even before doc 9's
`9/F4` change reduced plan time.

## Current hypotheses

### H1 -- feed pays for a full damage snapshot twice per action, including per printed character

`Terminal.feed` (`Terminal.swift:700`) wraps every decoded action in a snapshot
pair:

```swift
for action in inputStream.feed(bytes) {
    let before = damageActionSnapshot
    switch action { ... }
    recordDamage(since: before)   // builds `after` internally
}
```

`.print(scalar)` is an action, so a plain character costs two
`DamageActionSnapshot` materializations. The getter (`Terminal.swift:537`)
recomputes `scrollProjection`, derives the cursor window row from
`scrollbackRows.count`, and copies `selectionRange`, `activeSearchMatchRange`,
`hoveredLink`, and `presentation`. `hoveredLink` is a `TerminalResolvedLink`
carrying a String-bearing `TerminalHyperlink`, and `recordDamage` only ever
compares it for equality and reads its `.range` (`Terminal.swift:601`).

Supporting evidence: F1 puts `recordDamage(since:)` at 22.0% / 23.1% of the
harness root on styled with `damageActionSnapshot.getter` a further 8.6% / 9.1%;
1103 samples of raw `_platform_memmove` sit directly beneath `recordDamage`, and
`___chkstk_darwin` appears in its subtree, meaning a stack frame past a page.

Competing explanation: the cost is the diffing logic in `recordDamage`, not the
snapshot construction. Distinguished by the subtree -- the memmove and the getter
sit on the construction side, while `recordPresentationDamage` and
`TerminalDamageAccumulator.record` together stay under 1%.

Confirmed if removing the per-`.print` snapshot, or reducing the snapshot to POD,
collapses both nodes without inflating a sibling.

### H2 -- `invalidateInspection` pays copy/destroy traffic to evaluate a guard that usually rejects

`printNarrow` calls `invalidateInspection(inViewportRows:)` per character. That
function records row damage and then runs a four-way nil guard
(`Terminal.swift:2627`) over `selection`, `search`, `hoveredLinkState`, and
`armedLinkState`, returning immediately when all are nil -- the state of every
benchmark run and of most real use.

Supporting evidence: F1 puts the function at 19.4% / 19.2% of root on styled
while the damage accumulation it actually performs is under 1%
(`TerminalDamageAccumulator.record` = 0.8%). Its subtree is dominated by
`outlined destroy of Terminal.InteractionLinkState?` (9.4% / 8.8%) and
`outlined init with copy of Terminal.InactivePrimaryScreen?` (7.9% / 8.4%) --
copies, in a function whose common-case logic is a tag check.

Competing explanation: those `outlined ...` symbols are linker-deduplicated, so
the type names may not be literal and the copies may belong to a different field
of the same layout. This weakens the *attribution* but not the hypothesis: the
node is large and its stated work is tiny either way.

Confirmed if maintaining a precomputed `hasInteractionState` flag, tested before
any optional field is touched, collapses the node.

### H3 -- `Terminal` is large enough that ordinary field access is expensive

`MemoryLayout<Terminal>.size` is **932 bytes** (F2), across roughly fifty stored
properties including arrays, dictionaries, and optional String-bearing structs.
A struct that size makes every partial copy the optimizer cannot eliminate cost
real memmove, and it is the most plausible common cause behind both H1's and
H2's copy traffic and the 16.5% / 16.7% of root that `_platform_memmove`
accumulates across the tree.

Supporting evidence: the measured size; the presence of `___chkstk_darwin`
(stack-probe calls emitted only for frames past a page).

Competing explanation: the memmove is dominated by grid row writes, which are
legitimate work. Partly testable by workload -- memmove falls to 5.8% on
`incremental-screen-updates`, which writes far fewer cells but also takes far
fewer actions, so this does not cleanly separate.

Confirmed if boxing the cold fields shrinks the struct and moves the aggregate
memmove share. Deliberately **not** scheduled ahead of H1 and H2: it is the
largest change of the three and would confound their measurement.

### H4 -- retained terminal snapshots make the app's grid writes copy-on-write

`TerminalPaneSession` holds `cachedTerminal` and `lastPlannedTerminal`
(`TerminalPaneSession.swift:51,53`) alongside the host's own value, so the grid's
row storage is not uniquely referenced when the host next mutates it.
`lastPlannedTerminal`'s only use is the `terminal != lastPlannedTerminal` guard
in `planIfNeeded` (`:581`), which is itself a whole-grid `Equatable` walk per
frame.

Supporting evidence: F3 -- `_ArrayBuffer._consumeAndCreateNew` under
`clearCellAndPair` is 1.0% / 0.8% of root headless but 4.7% of feed in the app
profile, on comparable workloads. The harness holds one `Terminal` and no
snapshot, so the delta is attributable to the retained references.

Competing explanation: the two profiles use different workloads
(`styled-screen-redraw` vs `full-screen-content-churn`), so the delta is not a
controlled comparison. Bounding this properly needs an app profile on a
redraw-shaped workload, or a headless variant that deliberately retains a
snapshot.

Confirmed if replacing `lastPlannedTerminal` with a generation counter removes
the node from an app profile.

## Candidate direction, pending evidence

Provisional, ordered by measured size against implementation risk. Nothing here
is committed until the gate in Phase 2 is answered.

1. **H1(b) -- shrink `DamageActionSnapshot` to POD.** Replace the String-bearing
   `TerminalResolvedLink?` with the `activationIdentity: Int` and range it
   already carries. Pure representation change, no behavior surface, no change
   to when damage is recorded. Smallest and safest first step.
2. **H1(a) -- stop snapshotting for `.print`.** Larger win, but it narrows when
   damage is recorded and therefore needs behavioral tests under the correctness
   rule above.
3. **H2 -- precomputed interaction-state flag.** Self-contained, and it doubles
   as the experiment that confirms or refutes H2's attribution.
4. **H4 -- drop `lastPlannedTerminal`.** App-only, removes a per-frame
   whole-grid compare as well as the copies.
5. **H3 -- box the cold fields of `Terminal`.** Largest, last, and only once the
   above have been measured against a clean baseline.

`eraseLine` / `eraseCells` / `clearCellAndPair` (11-14% combined) is real but
unanalyzed; it is a Phase 3 item, not a candidate yet.

## Task ledger

### Phase 1 -- establish evidence

- [x] Build a headless feed profiler so the path can be read without a GUI or a
  btop-by-hand reproduction. Result: `scripts/terminal-feed-profile.py` +
  `just benchmark-feed-sample`.
- [x] Capture two `styled-screen-redraw` profiles and one
  `incremental-screen-updates` profile. Result: F1.
- [x] Measure `MemoryLayout<Terminal>.size`. Result: F2.
- [x] Establish whether the app's copy-on-write pressure is visible headlessly.
  Result: F3 -- it is not, and the delta is the evidence for H4.
- [ ] Capture a second `incremental-screen-updates` profile so its column meets
  the two-profile rule.

### Phase 2 -- direction gate

- [ ] **Gate: confirm the ordering in "Candidate direction" before implementing.**
  Acceptance: the operator picks a first change, or replaces the ordering. The
  open question is whether H1(a) is worth its correctness risk given that H1(b)
  may recover much of the same cost with none.

### Phase 3 -- implement and verify, one change at a time

- [ ] H1(b): POD `DamageActionSnapshot`. Re-post trees; paired verdict against a
  named baseline.
- [ ] H2: interaction-state flag. Doubles as the H2 attribution experiment.
- [ ] H1(a): skip the snapshot for `.print`, with behavioral damage tests.
- [ ] H4: replace `lastPlannedTerminal` with a generation counter; verify on an
  **app** profile, not the headless one.
- [ ] H3: box the cold fields of `Terminal`.
- [ ] RESEARCH: `eraseLine` / `eraseCells` / `clearCellAndPair`, 11-14% of root
  on both workload shapes. Not yet attributed to a mechanism.

## Findings log

### F1 -- feed is dominated by damage snapshotting and inspection invalidation, not by parsing

- Status: recorded; stable across the two styled profiles, single-profile and
  directional-only for incremental.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: `557dd4f`, plus the new harness and untracked
  `notes.md` / `plans/wip/*` that enter no build.
- Commands: `just benchmark-feed-sample styled-screen-redraw 20` (twice),
  `just benchmark-feed-sample incremental-screen-updates 20`.
- Artifacts: the three `.build/terminal-feed-profiles/2026-07-28-*` paths listed
  above.
- Measurements -- share of harness root inclusive:

  | Node | styled 1 | styled 2 | incremental |
  | --- | ---: | ---: | ---: |
  | `Terminal.feed(_:)` | 97.1% | 96.8% | 98.9% |
  | `Terminal.printNarrow(_:breakClass:)` | 29.2% | 29.3% | 8.8% |
  | `Terminal.recordDamage(since:)` | 22.0% | 23.1% | 8.2% |
  | `Terminal.invalidateInspection(inViewportRows:)` | 19.4% | 19.2% | 6.6% |
  | `_platform_memmove` | 16.5% | 16.7% | 5.8% |
  | `Terminal.clearCellAndPair(...)` | 14.4% | 14.0% | 11.5% |
  | `Terminal.eraseLine(mode:)` | 11.4% | 11.1% | 12.4% |
  | `outlined destroy of Terminal.InteractionLinkState?` | 9.4% | 8.8% | 3.1% |
  | `Terminal.damageActionSnapshot.getter` | 8.6% | 9.1% | 3.3% |
  | `outlined init with copy of Terminal.InactivePrimaryScreen?` | 7.9% | 8.4% | 3.0% |
  | `TerminalInputStream.feed(_:)` | 7.1% | 6.8% | 11.1% |
  | `destroy for ClosedRange<>.Index` | 6.9% | 6.3% | 2.2% |
  | `EscapeAbsorber.consume(_:)` | 2.6% | 2.4% | 5.6% |
  | `_ArrayBuffer._consumeAndCreateNew(...)` | 1.0% | 0.8% | 2.7% |

  styled run 1, pruned to nodes at or above 130 samples:

  ```
  16713  measureFeedBatch(chunks:executionCount:makeTerminal:now:)
     4962  Terminal.feed(_:)
       3243  Terminal.printNarrow(_:breakClass:)
          715  Terminal.invalidateInspection(inViewportRows:)
            530  outlined destroy of Terminal.InteractionLinkState?
              378  destroy for ClosedRange<>.Index
          691  Terminal.invalidateInspection(inViewportRows:)
            486  outlined init with copy of Terminal.InactivePrimaryScreen?
              185  _platform_memmove
              180  initializeWithCopy for ClosedRange<>.Index
          668  Terminal.invalidateInspection(inViewportRows:)
            431  outlined init with copy of Terminal.InactivePrimaryScreen?
          494  Terminal.invalidateInspection(inViewportRows:)
            342  outlined destroy of Terminal.InteractionLinkState?
        968  Terminal.printNarrow(_:breakClass:)
          305  Terminal.clearCellAndPair(...)
     3899  Terminal.feed(_:)
       1144  Terminal.recordDamage(since:)
         1103  _platform_memmove
        583  Terminal.recordDamage(since:)
          176  Terminal.damageActionSnapshot.getter
        366  Terminal.recordDamage(since:)
          232  outlined init with copy of Terminal.DamageActionSnapshot
        357  Terminal.recordDamage(since:)
          197  outlined destroy of Terminal.InteractionLinkState?
        193  Terminal.recordDamage(since:)
          193  ___chkstk_darwin
     1950  Terminal.feed(_:)
       1893  Terminal.eraseLine(mode:)
         1557  Terminal.eraseCells(row:columns:)
     1275  Terminal.feed(_:)
       1238  _platform_memmove
     1203  Terminal.feed(_:)
        430  TerminalInputStream.feed(_:)
          256  EscapeAbsorber.consume(_:)
            222  EscapeAbsorber.dispatchCSI(final:)
  ```

- Observation: the escape parser and byte decoder (`TerminalInputStream.feed` +
  `EscapeAbsorber.consume`) total roughly 10% on styled and 17% on incremental.
  Everything above them is grid mutation and value copying. The two largest
  nodes, `recordDamage(since:)` and `invalidateInspection`, are both bookkeeping
  around the mutation rather than the mutation itself, and both are entered once
  per action or once per character.
- Repeatability: the two styled runs agree within 0.7 points on every node in the
  table, which is a far tighter spread than doc 9's plan-side captures. Treat
  styled shares as stable; treat the incremental column as one capture.
- Inference: supports H1 and H2 directly. Also establishes the negative result
  that matters most for prioritization -- **parsing is not the bottleneck**, so
  work aimed at the state machine would be misdirected.
- Competing interpretations: the harness recreates a fresh `Terminal` per
  execution, so construction cost is included; it is amortized over 3500 frames
  per execution on styled and is not visible as a node, but it is not zero.
- Uncertainty: low on styled attribution, moderate on incremental (one profile),
  moderate on the identity of the `outlined ...` symbols (see H2).
- Next action: Phase 2 gate.

### F2 -- `Terminal` is a 932-byte struct

- Status: recorded. Structural measurement; no profile needed.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: as F1.
- Command: a throwaway executable linked against the release object files,
  printing `MemoryLayout<Terminal>.size`.
- Measurements: `Terminal` size 932, stride 936. `TerminalCell` size 72.
  `TerminalPresentation` size 4.
- Observation: roughly fifty stored properties, several of them arrays,
  dictionaries, or optionals wrapping String-bearing structs.
- Inference: supports H3, and supplies the common mechanism that makes H1's and
  H2's copies expensive rather than free. Also explains the `___chkstk_darwin`
  frames, which the compiler emits only past a page of stack.
- Competing interpretations: size alone proves nothing about how often the whole
  struct is copied; most mutating methods take it `inout`. The number bounds the
  cost of the copies that *do* happen; it does not establish their count.
- Uncertainty: none on the measurement, moderate on its consequences.
- Next action: keep H3 last so it does not confound H1 and H2.

### F3 -- the app's copy-on-write pressure is invisible to the headless harness

- Status: recorded. Cross-instrument comparison, not a controlled experiment.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: headless at `557dd4f`; app profile is doc 9's
  artifact at `6c58c45`.
- Measurements -- `_ArrayBuffer._consumeAndCreateNew` beneath
  `clearCellAndPair`:

  | Instrument | Workload | Share |
  | --- | --- | ---: |
  | headless feed harness | `styled-screen-redraw` | 1.0% / 0.8% of root |
  | headless feed harness | `incremental-screen-updates` | 2.7% of root |
  | app sample profile | `full-screen-content-churn` | 4.7% of feed |

- Observation: the node is several times larger in the app than headless. The
  harness holds exactly one `Terminal` value and no snapshot; the app holds the
  host's value plus `cachedTerminal` plus `lastPlannedTerminal`, so grid row
  storage is not uniquely referenced when the host writes to it.
- Inference: supports H4 -- the app's extra retained references convert in-place
  row writes into copy-on-write duplications.
- Competing interpretations: **the workloads differ**, so this is a comparison
  across two instruments and two fixtures, not a controlled A/B. It is enough to
  motivate H4 and not enough to size it.
- Uncertainty: moderate. Direction is well-supported, magnitude is not.
- Next action: before implementing H4, bound it properly -- either profile the
  app on a redraw-shaped workload, or add a headless variant that retains a
  snapshot so the same fixture is measured both ways.

## Decision log

No decisions yet. The Phase 2 gate is the first one.

## Rejected

Nothing yet.

## Open questions and caveats

- **`incremental-screen-updates` has one profile.** Its column ranks nodes very
  differently from styled (parsing nearly doubles in share, `printNarrow` falls
  by more than three times). Until a repeat exists, do not treat any incremental
  share as stable.
- **The `outlined ...` symbol names may be linker-deduplicated** and therefore
  attribute copy/destroy work to the wrong type. The sizes are trustworthy; the
  type names in H2 are not, which is why H2's confirming experiment is designed
  to be decisive regardless.
- **`styled-screen-redraw` is a proxy for btop, not a recording of it.** It
  matches the shape (cursor-home full-frame redraw, dense truecolor SGR, `EL` per
  row) but its cell content and frame cadence are synthetic. If a candidate's
  win turns out to be shape-sensitive, capture a real recording into the corpus
  before trusting it.
- **The renderer gap is out of scope here.** The app comparison that opened this
  file also showed the Swift backend rasterizing glyphs on the CPU via CoreText
  while libghostty composites a GPU-rendered `IOSurfaceLayer`
  (`app/TerminalView.swift:266`). That is a real and probably larger structural
  difference, but it belongs to the draw path and to a renderer-architecture
  decision, not to this file.
