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
- **A directional claim uses `benchmark-confirm`, not `benchmark-quick`.** F7 ran
  the same `benchmark-quick` comparison on `incremental-mixed` five times against
  one unchanging pair of trees and got every verdict the tool can emit, spanning
  -6.05% to +7.61% -- including `slower` twice, on a change that `confirm`
  reproducibly scores `faster`. Quick's 2-pair rule is a smoke test. Never record
  a lone quick verdict as a result, in either direction.
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

**Partly refuted, 2026-07-28.** F4 reduced the snapshot to POD and neither node
moved: `recordDamage` 21.9/22.4% -> 23.1/22.8%, the getter flat, the memmove
beneath it unchanged. The snapshot's *contents* are not the cost. The hypothesis
survives only in its H1(a) form -- how often the snapshot is built, not what is
in it -- and the surviving memmove now points at H3 instead.

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

**Confirmed, 2026-07-28 (F5, D2).** The flag took the node from 19.4/19.2% to
1.5/1.7% of root with nothing absorbing the work. The competing explanation is
also settled against: the `outlined ...` symbols were where this hypothesis
placed them -- the `InactivePrimaryScreen?` copy goes to zero and the
`InteractionLinkState?` destroy to 0.31x when the four optional reads leave the
guard. Reading nil non-POD optionals is not free.

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

### H5 -- cell and row shifting reallocates instead of moving in place

`Terminal.moveAndFillCells(in:row:by:)` is **33.8% / 33.2%** of the harness root
on `incremental-screen-updates` (F6), the single largest node on that shape by
more than a factor of two, and it is absent from `styled-screen-redraw`
entirely. Its subtree is not cell writing: it is
`specialized _copyCollectionToContiguousArray<A>(_:)` (8.0% / 8.4%) and
`swift_arrayInitWithCopy` (5.5% / 5.7%) building a fresh array, matched by
`swift_arrayDestroy` (10.3% / 10.9%) tearing the old one down, with
`outlined copy of` / `outlined consume of TerminalScalars.Storage` on both
sides. `moveAndFillRows(...)` beneath `advanceToNextRow` (12.1% / 12.5%) shows
the same shape one level up.

So a shift that should be a `memmove` within one row's storage appears to
allocate a new buffer, copy each `GridCell` individually, retain each cell's
heap `TerminalScalars.Storage`, and then release the originals.

Supporting evidence: F6's incremental tree, where the three array-traffic
symbols plus the refcount release path total roughly the same as
`moveAndFillCells` itself; `swift_isUniquelyReferenced_nonNull_native` appears
directly beneath it (2.8% combined with its stub), which is the copy-on-write
uniqueness check firing on a buffer that is evidently not unique.

Competing explanation: the arrays may be legitimately new -- if the shift is
expressed as a slice-to-`Array` conversion the allocation is inherent to how it
is written, not to aliasing, and the fix is a different rewrite (in-place
`replaceSubrange` or a manual `memmove` over the row) rather than removing a
retained reference. Distinguished by reading the implementation before
measuring anything.

Note the interaction with H4: `swift_isUniquelyReferenced` failing here would be
*aggravated* in the app by the retained snapshots H4 describes, and F3 already
found `_ArrayBuffer._consumeAndCreateNew` several times larger in the app than
headless. H5 and H4 may be the same wound seen from two instruments.

Confirmed if rewriting the shift to move cells in place collapses
`_copyCollectionToContiguousArray` and `swift_arrayInitWithCopy` without
inflating a sibling.

**Confirmed, 2026-07-28 (F7, D3).** Both symbols went to exactly zero and the
destroy path more than halved. The competing explanation was the correct one --
the allocation was an explicit `Array(slice)` in both primitives, inherent to how
the shift was written rather than caused by aliasing -- so the fix was a
traversal-order rewrite. That also **detaches H5 from H4**: they are not the same
wound, and the note above suggesting they might be is withdrawn.

## Candidate direction, pending evidence

Ordered by measured size against implementation risk. Re-scoped 2026-07-28
against F6, which is the current baseline; the two entries settled so far are
struck through with their findings.

Done:

- ~~**H1(b) -- shrink `DamageActionSnapshot` to POD.**~~ Reverted: F4, D1. No win
  on either instrument.
- ~~**H2 -- precomputed interaction-state flag.**~~ Shipped: F5, D2. About 18
  points of the feed path on `styled-screen-redraw`.

Open, re-ordered against F6:

1. ~~**H5 -- move cells in place instead of reallocating.**~~ Shipped: F7, D3.
   The first app-level `faster` verdict in this file (`terminal-feed` ~-7%,
   `scrollback-stream` ~-4.5%, both reproducing).
2. **H1(a) -- stop snapshotting for `.print`.** Targets `recordDamage` (27.7%)
   plus the snapshot getter (11.2%) on styled, but only ~12% combined on
   incremental, so its value is shape-dependent. F4 sharpened its design: the
   cost is not what the snapshot contains, so this has to avoid building and
   diffing it at all. Note the correctness trap -- a print advances the cursor, so
   the snapshot pair is not dead work for `.print`; it is what damages the old and
   new cursor rows. Skipping it wholesale drops a cursor repaint. Needs behavioral
   damage tests first, under the correctness rule above.
3. **H4 -- drop `lastPlannedTerminal`.** App-only, removes a per-frame whole-grid
   compare as well as the copies. Weakened by F7: the tentative link to H5 is
   withdrawn, so F3 is again its only evidence, and F3 is uncontrolled.
4. **H3 -- box the cold fields of `Terminal`.** The argument strengthened: F4
   showed the 1.4k-sample `_platform_memmove` under `recordDamage` survives making
   the snapshot fully POD, so it is not the snapshot and most plausibly is the
   932-byte `Terminal` being partially copied. The reason H3 was scheduled last --
   that it would confound H1 and H2 -- has largely expired now that H1(b) and H2
   are settled.

`eraseLine` / `eraseCells` / `clearCellAndPair` is the one large node that ranks
high on *both* shapes (styled 13.9% / 12.7% / 17.2%; incremental 12.5% / 11.4% /
12.0%) and is still unattributed to a mechanism. That shape-independence makes it
the most valuable remaining RESEARCH item.

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
- [x] Capture a second `incremental-screen-updates` profile so its column meets
  the two-profile rule. Result: F6 -- two captures, agreeing within 0.6 points.

### Phase 2 -- direction gate

- [x] **Gate: confirm the ordering in "Candidate direction" before implementing.**
  Answered 2026-07-28: the operator kept the ordering and ran its two cheapest
  entries -- H1(b) then H2 -- one at a time, each with its own tree pair, `just
  test`, and paired verdict, explicitly deferring H1(a), H4, and H3. The gate's
  open question is settled by D1.

### Phase 3 -- implement and verify, one change at a time

- [x] H1(b): POD `DamageActionSnapshot`. Result: F4 -- negative, reverted; D1.
- [x] H2: interaction-state flag. Result: F5 -- confirmed and shipped; D2. The
  attribution experiment came out in H2's favor, which also resolves this file's
  "the `outlined ...` names may be misattributed" caveat.
- [x] Re-baseline the feed path after H2, on both workload shapes. Result: F6,
  which supersedes F1 and re-scopes the candidate ordering.
- [x] H5: read `moveAndFillCells` / `moveAndFillRows` and establish whether the
  reallocation is aliasing or is inherent to how the shift is written. Result:
  F7 -- inherent to the written form; shifted in place instead; D3.
- [ ] H1(a): skip the snapshot for `.print`, with behavioral damage tests. Must
  preserve cursor-row damage -- see the trap noted in the candidate list.
- [ ] H4: replace `lastPlannedTerminal` with a generation counter; verify on an
  **app** profile, not the headless one. Reconsider jointly with H5.
- [ ] H3: box the cold fields of `Terminal`. The confound argument for keeping it
  last has largely expired; F4 strengthened its evidence.
- [ ] RESEARCH: `eraseLine` / `eraseCells` / `clearCellAndPair`, 11-17% of root
  on **both** workload shapes. Not yet attributed to a mechanism, and the only
  large node that is shape-independent.

## Findings log

### F1 -- feed is dominated by damage snapshotting and inspection invalidation, not by parsing

- Status: recorded, and **superseded by F6** as the current picture. Kept as the
  record of the starting state. Two caveats on reading it now: every styled share
  predates F5 and has since been rescaled by roughly 1.24x, and its incremental
  column was built from the styled tree's node list and therefore omits
  `moveAndFillCells`, the largest node on that shape.
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

### F4 -- a POD `DamageActionSnapshot` removes its copy node and buys nothing

- Status: recorded. Negative result. H1(b) implemented, measured, reverted.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: baseline `52af73a` clean; candidate is `52af73a`
  plus the single-file change described below, with only untracked `notes.md` /
  `plans/wip/*` besides.
- The change: `DamageActionSnapshot.hoveredLink` moved from
  `TerminalResolvedLink?` (which carries a `TerminalHyperlink`, and therefore a
  `String`) to a POD `HoveredLinkKey?` of `(range, activationIdentity)`, fed by a
  new `hoveredLinkKey` getter that mirrors `hoveredLink`'s nil conditions without
  materializing the URI. `recordDamage(since:)` was untouched -- it already only
  compared the link for equality and read `.range`. The whole struct becomes
  trivially copyable.
- Commands: `just benchmark-feed-sample styled-screen-redraw 20` twice before and
  twice after; `just test`;
  `DANTERM_BENCHMARK_ALLOW_BATTERY=1 just benchmark-quick baseline=52af73a workload=content-churn`.
- Artifacts: `.build/terminal-feed-profiles/2026-07-28-{093123,093151}` (before),
  `.../2026-07-28-{093330,093358}` (after),
  `.build/terminal-benchmark-comparisons/quick/23310e13bc0c-0000`.
- Measurements -- share of harness root inclusive, `styled-screen-redraw`:

  | Node | before 1 | before 2 | after 1 | after 2 |
  | --- | ---: | ---: | ---: | ---: |
  | `Terminal.feed(_:)` | 96.9% | 97.2% | 97.0% | 96.8% |
  | `Terminal.printNarrow(_:breakClass:)` | 29.6% | 29.8% | 30.2% | 30.8% |
  | **`Terminal.recordDamage(since:)`** | **21.9%** | **22.4%** | **23.1%** | **22.8%** |
  | **`Terminal.damageActionSnapshot.getter`** | **8.9%** | **9.0%** | **9.0%** | **9.1%** |
  | `Terminal.invalidateInspection(inViewportRows:)` | 19.4% | 19.2% | 20.3% | 21.0% |
  | `_platform_memmove` | 16.7% | 16.3% | 16.1% | 16.3% |
  | `Terminal.clearCellAndPair(...)` | 14.9% | 14.7% | 14.0% | 14.4% |
  | `Terminal.eraseLine(mode:)` | 11.6% | 11.1% | 11.1% | 11.5% |
  | `outlined init with copy of Terminal.InactivePrimaryScreen?` | 8.7% | 8.1% | 8.3% | 8.7% |
  | `outlined destroy of Terminal.InteractionLinkState?` | 8.4% | 8.8% | 7.8% | 7.6% |
  | `TerminalInputStream.feed(_:)` | 7.4% | 7.0% | 7.2% | 6.5% |
  | `destroy for ClosedRange<>.Index` | 6.0% | 6.3% | 5.9% | 5.6% |
  | `outlined init with copy of Terminal.DamageActionSnapshot` | 1.4% | -- | **absent** | **absent** |

  Before, run 1, pruned to nodes at or above 130 samples (root 16784):

  ```
  16784  measureFeedBatch(chunks:executionCount:makeTerminal:now:)
    5055  Terminal.feed(_:)
      3282  Terminal.printNarrow(_:breakClass:)
         763  Terminal.invalidateInspection(inViewportRows:)
           532  outlined init with copy of Terminal.InactivePrimaryScreen?
             208  initializeWithCopy for ClosedRange<>.Index
             172  _platform_memmove
         757  Terminal.invalidateInspection(inViewportRows:)
           531  outlined init with copy of Terminal.InactivePrimaryScreen?
         615  Terminal.invalidateInspection(inViewportRows:)
           444  outlined destroy of Terminal.InteractionLinkState?
             274  destroy for ClosedRange<>.Index
         442  Terminal.invalidateInspection(inViewportRows:)
           285  outlined destroy of Terminal.InteractionLinkState?
         219  Terminal.invalidateInspection(inViewportRows:)
         218  Terminal.invalidateInspection(inViewportRows:)
      1022  Terminal.printNarrow(_:breakClass:)
         314  Terminal.clearCellAndPair(...)
    3883  Terminal.feed(_:)
      1157  Terminal.recordDamage(since:)
        1131  _platform_memmove
       597  Terminal.recordDamage(since:)
         156  Terminal.damageActionSnapshot.getter
       371  Terminal.recordDamage(since:)
         231  outlined init with copy of Terminal.DamageActionSnapshot
           231  initializeWithCopy for Terminal.DamageActionSnapshot
       367  Terminal.recordDamage(since:)
         203  outlined destroy of Terminal.InteractionLinkState?
       283  Terminal.recordDamage(since:)
       183  Terminal.recordDamage(since:)
         183  ___chkstk_darwin
       142  Terminal.damageActionSnapshot.getter
    2010  Terminal.feed(_:)
      1948  Terminal.eraseLine(mode:)
        1634  Terminal.eraseCells(row:columns:)
    1255  Terminal.feed(_:)
       479  TerminalInputStream.feed(_:)
         286  EscapeAbsorber.consume(_:)
    1242  Terminal.feed(_:)
      1201  _platform_memmove
  ```

  After, run 1, same pruning (root 16697):

  ```
  16697  measureFeedBatch(chunks:executionCount:makeTerminal:now:)
    5132  Terminal.feed(_:)
      3405  Terminal.printNarrow(_:breakClass:)
         790  Terminal.invalidateInspection(inViewportRows:)
           634  outlined destroy of Terminal.InteractionLinkState?
             438  destroy for ClosedRange<>.Index
         726  Terminal.invalidateInspection(inViewportRows:)
           500  outlined init with copy of Terminal.InactivePrimaryScreen?
             192  _platform_memmove
         709  Terminal.invalidateInspection(inViewportRows:)
           480  outlined init with copy of Terminal.InactivePrimaryScreen?
         480  Terminal.invalidateInspection(inViewportRows:)
           317  outlined destroy of Terminal.InteractionLinkState?
         217  Terminal.invalidateInspection(inViewportRows:)
         208  Terminal.invalidateInspection(inViewportRows:)
       953  Terminal.printNarrow(_:breakClass:)
         294  Terminal.clearCellAndPair(...)
    3994  Terminal.feed(_:)
      1122  Terminal.recordDamage(since:)
        1101  _platform_memmove
       892  Terminal.recordDamage(since:)
       604  Terminal.recordDamage(since:)
         220  Terminal.damageActionSnapshot.getter
       215  Terminal.recordDamage(since:)
       208  Terminal.recordDamage(since:)
       190  Terminal.recordDamage(since:)
         190  ___chkstk_darwin
    1910  Terminal.feed(_:)
      1851  Terminal.eraseLine(mode:)
        1535  Terminal.eraseCells(row:columns:)
    1218  Terminal.feed(_:)
       456  TerminalInputStream.feed(_:)
         262  EscapeAbsorber.consume(_:)
    1184  Terminal.feed(_:)
      1153  _platform_memmove
  ```

- Correctness: `just test` exit 0 -- 618 core tests in 84 suites, the one
  pre-existing `GhosttyInspectionRecoveryReplayTests` known issue, plus 1111
  protocol, 115 support, 30 shell-contract. No behavior surface moved.
- Paired verdict: `content-churn` **equivalent** (+0.09% symmetric median of 2
  pairs; plan time +0.53%, also equivalent). Run on AC power, not battery.
- Observation: the change did exactly what it was designed to do and nothing
  more. `outlined init with copy of Terminal.DamageActionSnapshot` -- 231 samples,
  1.4% of root -- disappears from the tree completely in both after-runs, which
  is direct confirmation that the struct became trivially copyable. But
  `recordDamage(since:)` did not shrink: its lowest after-run share (22.8%)
  exceeds its highest before-run share (22.4%), against a before/after
  repeat spread of 0.5 and 0.3 points respectively. The
  `damageActionSnapshot.getter` node is flat to within 0.2 points. The 1.1k-sample
  `_platform_memmove` directly beneath `recordDamage`, which H1 cited as its
  strongest evidence, is unchanged at 1131 -> 1101 samples.
- Inference: **H1(b) is refuted, and it partly refutes H1's stated mechanism.**
  The cost under `recordDamage` is not the snapshot's *contents*. In this
  workload `hoveredLinkState` is nil for the entire run, so the optional's
  reference-counting was never actually exercised -- only the outlined
  copy/destroy *calls*, which tag-check and return. Removing them removes the
  calls, and the calls were nearly free. What remains under `recordDamage` is a
  1.1k-sample memmove that survives making the snapshot POD, which points at the
  932-byte `Terminal` (H3), not at the ~100-byte snapshot.
- Second inference, which matters for H2: `outlined destroy of
  Terminal.InteractionLinkState?` stays at 7.6-7.8% *after* the only
  `TerminalResolvedLink` in the snapshot was removed. That symbol therefore
  cannot be accounted for by the hovered-link field. It is direct support for
  this file's standing caveat that these `outlined ...` names are
  linker-deduplicated and misattributed, and it is the reason H2's confirming
  experiment had to be designed not to depend on the name.
- Competing interpretations: `invalidateInspection` reads 0.9-1.8 points higher
  after, which could be read as work displaced into a sibling. More likely it is
  the same total work redistributed by inlining -- `printNarrow` rises by a
  similar amount, the root is flat, and the paired wall-clock verdict is
  `equivalent`, which no displacement story survives.
- Uncertainty: low. Two instruments agree, and the mechanism (a nil optional's
  outlined calls are cheap) explains the null cleanly.
- Next action: D1. H1's remaining weight is H1(a) alone.

### F5 -- a precomputed interaction-state flag removes 18 points of feed, and confirms H2's attribution

- Status: recorded. Positive result, committed. Confirms H2.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: baseline `52af73a` clean; candidate is `52af73a`
  plus the change below (`Terminal.swift` + one new test), with only untracked
  `notes.md` / `plans/wip/*` besides.
- The change: the four inspection fields (`selection`, `search`,
  `hoveredLinkState`, `armedLinkState`) each gained a `didSet` observer that
  recomputes one `hasInteractionState: Bool`, and both `invalidateInspection`
  overloads now guard on that Bool instead of re-reading all four optionals.
  The observers, rather than the mutation sites, are what make the flag
  undriftable: `didSet` fires for in-place mutation
  (`hoveredLinkState?.range = ...`) as well as for whole-value assignment, so
  there is no call site that can forget to maintain it.
- Commands: `just benchmark-feed-sample styled-screen-redraw 20` twice before
  and twice after; `just test`;
  `DANTERM_BENCHMARK_ALLOW_BATTERY=1 just benchmark-quick baseline=52af73a workload=content-churn`, twice.
- Artifacts: `.build/terminal-feed-profiles/2026-07-28-{093123,093151}` (before,
  shared with F4), `.../2026-07-28-{095004,095032}` (after),
  `.build/terminal-benchmark-comparisons/quick/9f143d617884-{0000,0001}`.
- Measurements -- share of harness root inclusive, `styled-screen-redraw`. The
  final column is the after/before ratio of the two-run means, which is the
  column that carries the verification argument:

  | Node | before 1 | before 2 | after 1 | after 2 | ratio |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | `Terminal.feed(_:)` | 96.9% | 97.2% | 96.4% | 96.2% | 0.99 |
  | **`Terminal.invalidateInspection(inViewportRows:)`** | **19.4%** | **19.2%** | **1.5%** | **1.7%** | **0.08** |
  | `outlined init with copy of Terminal.InactivePrimaryScreen?` | 8.7% | 8.1% | 0.0% | 0.0% | 0.00 |
  | `outlined destroy of Terminal.InteractionLinkState?` | 8.4% | 8.8% | 2.7% | 2.7% | 0.31 |
  | `destroy for ClosedRange<>.Index` | 6.0% | 6.3% | 1.8% | 1.7% | 0.29 |
  | `Terminal.printNarrow(_:breakClass:)` | 29.6% | 29.8% | 12.5% | 13.0% | 0.43 |
  | `_platform_memmove` | 16.7% | 16.3% | 17.8% | 17.9% | 1.08 |
  | `Terminal.clearCellAndPair(...)` | 14.9% | 14.7% | 17.2% | 16.8% | 1.15 |
  | `Terminal.appendToOpenClusterIfJoined(...)` | 4.0% | 4.0% | 4.8% | 4.5% | 1.16 |
  | `TerminalInputStream.feed(_:)` | 7.4% | 7.0% | 8.6% | 8.8% | 1.21 |
  | `Terminal.eraseLine(mode:)` | 11.6% | 11.1% | 14.2% | 13.6% | 1.23 |
  | `Terminal.eraseCells(row:columns:)` | 10.7% | 10.1% | 13.0% | 12.5% | 1.23 |
  | `EscapeAbsorber.consume(_:)` | 2.8% | 2.5% | 3.3% | 3.3% | 1.23 |
  | `Terminal.recordDamage(since:)` | 21.9% | 22.4% | 28.0% | 27.7% | 1.26 |
  | `Terminal.damageActionSnapshot.getter` | 8.9% | 9.0% | 11.3% | 11.4% | 1.27 |

  After, run 1, pruned to nodes at or above 130 samples (root 16149):

  ```
  16149  measureFeedBatch(chunks:executionCount:makeTerminal:now:)
    4777  Terminal.feed(_:)
      1446  Terminal.recordDamage(since:)
        1388  _platform_memmove
       760  Terminal.recordDamage(since:)
         215  Terminal.damageActionSnapshot.getter
         137  Terminal.damageActionSnapshot.getter
       458  Terminal.recordDamage(since:)
         262  outlined init with copy of Terminal.DamageActionSnapshot
           262  initializeWithCopy for Terminal.DamageActionSnapshot
       456  Terminal.recordDamage(since:)
         242  outlined destroy of Terminal.InteractionLinkState?
           160  destroy for ClosedRange<>.Index
       339  Terminal.recordDamage(since:)
       280  Terminal.recordDamage(since:)
         280  ___chkstk_darwin
       142  Terminal.damageActionSnapshot.getter
    2350  Terminal.feed(_:)
      2290  Terminal.eraseLine(mode:)
        1993  Terminal.eraseCells(row:columns:)
           481  Terminal.clearCellAndPair(...)
           271  Terminal.clearPreviousSpacer(...)
    2155  Terminal.feed(_:)
      1027  Terminal.printNarrow(_:breakClass:)
         204  Terminal.clearCellAndPair(...)
       240  Terminal.printNarrow(_:breakClass:)
       196  Terminal.printNarrow(_:breakClass:)
    1444  Terminal.feed(_:)
      1400  _platform_memmove
    1413  Terminal.feed(_:)
       524  TerminalInputStream.feed(_:)
         286  EscapeAbsorber.consume(_:)
           232  EscapeAbsorber.dispatchCSI(final:)
       395  TerminalInputStream.feed(_:)
     757  Terminal.feed(_:)
       223  Terminal.damageActionSnapshot.getter
     705  Terminal.feed(_:)
       431  Terminal.appendToOpenClusterIfJoined(_:classification:)
     414  Terminal.feed(_:)
       414  doDecrementSlow -> _swift_release_dealloc -> swift_arrayDestroy
  ```

  The `invalidateInspection` subtree that dominated the before-tree --
  six sibling entries totalling 3260 samples, each topped by an `outlined init
  with copy` or `outlined destroy` -- is simply absent. The function survives at
  199 raw samples in the after profile.

- Verification that nothing absorbed the work: the harness samples for a fixed
  20 seconds, so every share is relative and removing a node inflates every
  other share mechanically. Removing a 19.3% node predicts a uniform rescale of
  `1/(1-0.193)` = **1.24x** for untouched work. The measured ratios for work
  with no relationship to the guard cluster tightly on that prediction --
  `recordDamage` 1.26, the snapshot getter 1.27, `eraseLine` and `eraseCells`
  1.23, `EscapeAbsorber.consume` 1.23, `TerminalInputStream.feed` 1.21. **No
  node exceeds 1.27**, so nothing grew in absolute terms; nothing absorbed the
  removed work. The nodes that came in *below* 1.24 -- `_platform_memmove` 1.08,
  `clearCellAndPair` 1.15, `appendToOpenClusterIfJoined` 1.16 -- are ones that
  had part of themselves under the guard and therefore shed work as well.
  `printNarrow` at 0.43 is the guard's own caller.
- Correctness: `just test` exit 0 -- 619 core tests in 84 suites (618 plus the
  new one), the one pre-existing `GhosttyInspectionRecoveryReplayTests` known
  issue, plus 1111 protocol, 115 support, 30 shell-contract.
- Test added, per this file's correctness-first rule: *"an armed link alone is
  invalidated when its text is overwritten"* in
  `TerminalHyperlinkInteractionTests`. `armedLinkState` was the one of the four
  fields with no arm-only invalidation coverage -- `linkArmTracksRunIdentity`
  drives an arm across an overwrite, but its release is refused by the
  run-identity check, so it passes whether or not the arm was ever invalidated.
  Verified by mutation: dropping `|| armedLinkState != nil` from the flag's
  recomputation fails this test and **only** this test, across the whole 619-test
  suite. Zeroing the flag entirely fails 43 assertions across selection, search,
  and hover, so those three were already covered.
- Paired verdict: `content-churn` **inconclusive** (-1.80% symmetric median of 2
  pairs) then **equivalent** (-0.67%) on a repeat. Both runs on AC power, not
  battery. Both point the right way and neither clears the bar, so per this
  file's evidence rule **no app-level speedup is claimed**. This is the expected
  shape rather than a contradiction: `benchmark-quick` is a frame-oriented
  main-thread measurement, and feed runs on the pty-host queue -- the same reason
  doc 9 set feed aside. Its role here is as a regression guard, and it clears
  that.
- Inference: **H2 is confirmed, including its attribution.** The competing
  explanation in H2 was that the `outlined ...` symbols are linker-deduplicated
  and might belong to some other field of the same layout. They do not: removing
  the four optional reads from the guard takes `outlined init with copy of
  Terminal.InactivePrimaryScreen?` to zero and `outlined destroy of
  Terminal.InteractionLinkState?` to 0.31x. The copies were exactly where H2 said
  they were. F4 already showed the same `InteractionLinkState?` destroy node was
  *not* explained by the damage snapshot's hovered link; F5 completes that by
  showing it was the guard.
- Broader inference: reading four `Optional`s whose payloads are non-trivial is
  not free even when all four are nil and the function returns immediately. The
  loads emit outlined copy/destroy calls, and here that cost about 18% of the
  entire feed path. That generalizes to any hot guard over non-POD optionals in
  this engine.
- Competing interpretations: the reduction could be an artifact of the optimizer
  inlining `invalidateInspection` into `printNarrow` rather than of real work
  being removed. The rescale analysis rules this out -- inlining relocates a
  node's samples into its caller, which would have pushed `printNarrow` *above*
  the 1.24 rescale factor, and instead it fell to 0.43.
- Uncertainty: low headless. Unquantified at the app level, by instrument
  limitation rather than by disagreement.
- Next action: D2. The next scheduled item is H1(a), then H4, then H3.

### F6 -- post-H2 re-baseline, and the incremental column F1 never showed

- Status: recorded. Supersedes F1 as the current picture of the feed path.
  Incremental now has two captures and meets the two-profile rule for the first
  time.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: `07e4784` with a clean tracked tree. The
  `identity.json` files record `isWorkingTreeDirty: true`, which is
  `git status --porcelain` counting the untracked `notes.md` / `plans/wip/*`
  that enter no build; no tracked file differs from `07e4784`.
- Commands: `just benchmark-feed-sample styled-screen-redraw 20` twice,
  `just benchmark-feed-sample incremental-screen-updates 20` twice.
- Artifacts: `.build/terminal-feed-profiles/2026-07-28-{100116,100143}` (styled),
  `.../2026-07-28-{100211,100247}` (incremental).
- Measurements -- share of harness root inclusive:

  | Node | styled 1 | styled 2 | incr 1 | incr 2 |
  | --- | ---: | ---: | ---: | ---: |
  | `Terminal.feed(_:)` | 96.1% | 96.3% | 98.8% | 98.8% |
  | `Terminal.moveAndFillCells(in:row:by:)` | -- | -- | **33.8%** | **33.2%** |
  | `Terminal.recordDamage(since:)` | **27.8%** | **27.6%** | 8.6% | 8.7% |
  | `_platform_memmove` | 17.8% | 17.9% | 5.6% | 5.3% |
  | `Terminal.clearCellAndPair(...)` | 17.4% | 16.9% | 12.1% | 11.9% |
  | `Terminal.eraseLine(mode:)` | 14.0% | 13.7% | 12.7% | 12.3% |
  | `Terminal.printNarrow(_:breakClass:)` | 12.9% | 13.1% | 3.6% | 3.8% |
  | `Terminal.eraseCells(row:columns:)` | 12.9% | 12.4% | 11.6% | 11.2% |
  | `Terminal.execute(_:)` | 0.1% | 0.1% | 12.1% | 12.6% |
  | `Terminal.advanceToNextRow(preservingWrapClaim:)` | -- | -- | 12.1% | 12.6% |
  | `Terminal.moveAndFillRows(...)` | -- | -- | 12.1% | 12.5% |
  | `TerminalInputStream.feed(_:)` | 9.0% | 8.7% | 11.8% | 11.8% |
  | `Terminal.damageActionSnapshot.getter` | 11.0% | 11.4% | 3.3% | 3.6% |
  | `doDecrementSlow` (refcount release, all callers) | 2.7% | 2.9% | **12.9%** | **13.3%** |
  | `_ContiguousArrayStorage.__deallocating_deinit` | 2.3% | 2.5% | 10.5% | 11.0% |
  | `swift_arrayDestroy` | 2.3% | 2.5% | 10.3% | 10.9% |
  | `specialized _copyCollectionToContiguousArray<A>(_:)` | -- | -- | 8.0% | 8.4% |
  | `swift_arrayInitWithCopy` | -- | -- | 5.5% | 5.7% |
  | `outlined init with copy of Terminal.GridCell` | 1.8% | 1.7% | 5.6% | 5.7% |
  | `outlined consume of TerminalScalars.Storage` | 1.6% | 1.6% | 5.6% | 5.4% |
  | `EscapeAbsorber.consume(_:)` | 3.4% | 3.4% | 6.0% | 6.0% |

  Incremental, run 1, pruned to nodes at or above 150 samples (root 16633):

  ```
  16633  measureFeedBatch(chunks:executionCount:makeTerminal:now:)
    8226  Terminal.feed(_:)
      2103  Terminal.eraseLine(mode:)
        1840  Terminal.eraseCells(row:columns:)
      1216  Terminal.moveAndFillCells(in:row:by:)
      1157  Terminal.moveAndFillCells(in:row:by:)
        1088  specialized _copyCollectionToContiguousArray<A>(_:)
           517  swift_arrayInitWithCopy
             338  initializeWithCopy for Terminal.GridCell
             179  initializeWithCopy for Terminal.GridCell
               179  outlined copy of TerminalScalars.Storage
           301  initializeWithCopy for Terminal.GridCell
           257  swift_arrayInitWithCopy
       849  Terminal.moveAndFillCells(in:row:by:)
         835  doDecrementSlow -> _swift_release_dealloc
           715  _ContiguousArrayStorage.__deallocating_deinit
             408  swift_arrayDestroy -> outlined consume of TerminalScalars.Storage
       611  Terminal.moveAndFillCells(in:row:by:)
         469  outlined init with copy of Terminal.GridCell
       485  Terminal.moveAndFillCells(in:row:by:)
         284  swift_isUniquelyReferenced_nonNull_native
    2020  Terminal.feed(_:)
      2018  Terminal.execute(_:)
        2011  Terminal.advanceToNextRow(preservingWrapClaim:)
           889  Terminal.moveAndFillRows(...)
           650  Terminal.moveAndFillRows(...)
             639  doDecrementSlow -> _swift_release_dealloc
               563  _ContiguousArrayStorage.__deallocating_deinit
                 542  swift_arrayDestroy -> (nested release of GridCell storage)
    1986  Terminal.feed(_:)
       996  TerminalInputStream.feed(_:)
         621  EscapeAbsorber.consume(_:)
           538  EscapeAbsorber.dispatchCSI(final:)
    1534  Terminal.feed(_:)
       479  Terminal.recordDamage(since:)
         468  _platform_memmove
    633  Terminal.feed(_:)
       319  Terminal.printNarrow(_:breakClass:)
  ```

  Styled, run 1, same pruning (root 16686):

  ```
  16686  measureFeedBatch(chunks:executionCount:makeTerminal:now:)
    4941  Terminal.feed(_:)
      1473  Terminal.recordDamage(since:)
        1430  _platform_memmove
       760  Terminal.recordDamage(since:)
         231  Terminal.damageActionSnapshot.getter
       514  Terminal.recordDamage(since:)
         290  outlined init with copy of Terminal.DamageActionSnapshot
       401  Terminal.recordDamage(since:)
         214  outlined destroy of Terminal.InteractionLinkState?
       278  Terminal.recordDamage(since:)
         278  ___chkstk_darwin
    2402  Terminal.feed(_:)
      2334  Terminal.eraseLine(mode:)
        2041  Terminal.eraseCells(row:columns:)
           489  Terminal.clearCellAndPair(...)
    2258  Terminal.feed(_:)
      1053  Terminal.printNarrow(_:breakClass:)
    1508  Terminal.feed(_:)
       567  TerminalInputStream.feed(_:)
    1500  Terminal.feed(_:)
      1457  _platform_memmove
     746  Terminal.feed(_:)
       468  Terminal.appendToOpenClusterIfJoined(_:classification:)
  ```

- Repeatability: the two styled runs agree within 0.5 points on every node and
  reproduce F5's after-columns within 0.4, so four styled captures now agree.
  The two incremental runs agree within 0.6 points, so the incremental column is
  finally stable and the standing "one capture, directional only" caveat is
  discharged.
- Observation 1 -- **`moveAndFillCells` at 33% was never a change; it was a hole
  in F1's table.** F1 reported the incremental column by reusing the node list
  chosen from the styled tree, and `moveAndFillCells` is absent from styled
  entirely. Every node F1 *did* list for incremental is within 0.6 points today
  except the two H2 touched (`printNarrow` 8.8% -> 3.6/3.8%,
  `invalidateInspection` 6.6% -> gone). So this is a reporting gap being closed,
  not a regression. The F1 artifacts were deleted by `just test`'s `rm -rf
  .build`, so this cannot be re-derived from them -- it rests on the agreement of
  every other node.
- Observation 2 -- **the two workloads now have almost no overlap in their top
  nodes.** Styled is damage bookkeeping (`recordDamage` 27.7% + the snapshot
  getter 11.2% = ~39%) over cell clearing. Incremental is row and cell *moving*
  (`moveAndFillCells` 33.5%, `moveAndFillRows` 12.3%) whose cost is almost
  entirely array reallocation and refcount traffic -- `_copyCollectionToContiguousArray`,
  `swift_arrayInitWithCopy`, `swift_arrayDestroy`, and `outlined
  copy`/`consume of TerminalScalars.Storage`. `recordDamage` is only 8.7% there.
- Inference: the shifting path builds a **new array** rather than moving cells in
  place, and each moved `GridCell` retains and releases a heap `TerminalScalars.Storage`.
  That is a distinct mechanism from anything in H1-H4 and is the dominant cost on
  the localized-edit shape. It is recorded as H5 below.
- Second inference, for prioritization: H1(a) targets `recordDamage` plus the
  snapshot getter, which is ~39% of styled but ~12% of incremental. Its value is
  strongly shape-dependent, which the correctness risk has to be weighed against.
- Competing interpretations: `moveAndFillCells`'s share may be inflated by the
  fixture's edit pattern -- `incremental-screen-updates` is 100000 cycles of
  localized edits, and ICH/DCH-style shifting is exactly what it exercises. It is
  a fixture, not a recording, so the same caveat that applies to
  `styled-screen-redraw` as a btop proxy applies here.
- Uncertainty: low on both columns now. Moderate on how well either fixture
  represents real programs.
- Next action: re-scope the candidate ordering against this table before
  implementing H1(a).

### F7 -- shifting in place confirms H5, and is the first app-level win in this file

- Status: recorded. Positive result, committed. Confirms H5, with its competing
  explanation resolved in the competing explanation's favor.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: baseline `11a894e` clean tracked tree; candidate is
  `11a894e` plus the change below.
- The code read that settled the mechanism, done before any measurement, per the
  plan in the candidate list: both shift primitives opened with an explicit
  `Array(...)` of the strip they were about to move --
  `let sourceCells = Array(rows[row].cells[range])` (`moveAndFillCells`) and
  `let sourceRows = Array(rows[range])` (`moveAndFillRows`). **So H5's competing
  explanation was the right one**: the allocation was inherent to how the shift
  was written, not caused by aliasing or by a retained reference. That also
  detaches H5 from H4 -- they are not the same wound, and H4 must still be sized
  on its own.
- The change: both primitives now shift in place, iterating in the direction that
  makes an overlapping move safe -- descending when shifting right, ascending when
  shifting left, which is memmove's direction rule -- through one shared static
  `moveInPlace(_:by:amount:)` traversal helper. The temp array is gone from both.
  `moveAndFillRows` still materializes the evicted prefix when
  `pushesToScrollback` is set, but that is `amount` rows (typically one) rather
  than the whole region, and it must be materialized because handing
  `appendToScrollback` a slice of `self.rows` is an overlapping access to `self`.
  The helper is `static` for the same exclusivity reason: its closure mutates the
  grid.
- Commands: `just benchmark-feed-sample incremental-screen-updates 20` twice
  before and twice after, plus the same on `styled-screen-redraw` as an A/A
  control; `just test`; `just benchmark-quick` and
  `DANTERM_BENCHMARK_ALLOW_BATTERY=1 just benchmark-confirm baseline=11a894e`, twice.
- Artifacts: `.build/terminal-feed-profiles/2026-07-28-{100211,100247}` (incr
  before, shared with F6), `.../2026-07-28-{101242,101310}` (incr after),
  `.../2026-07-28-{100116,100143}` and `.../2026-07-28-{101341,101405}` (styled
  control), `.build/terminal-benchmark-comparisons/confirm/26e803876444-{0000,0001}`.
- Measurements -- `incremental-screen-updates`, share of harness root inclusive:

  | Node | before 1 | before 2 | after 1 | after 2 | ratio |
  | --- | ---: | ---: | ---: | ---: | ---: |
  | `Terminal.feed(_:)` | 98.8% | 98.8% | 98.8% | 98.8% | 1.00 |
  | **`specialized _copyCollectionToContiguousArray<A>(_:)`** | **8.0%** | **8.4%** | **0.0%** | **0.0%** | **0.00** |
  | **`swift_arrayInitWithCopy`** | **5.5%** | **5.7%** | **0.0%** | **0.0%** | **0.00** |
  | `doDecrementSlow` (refcount release) | 12.9% | 13.3% | 7.8% | 7.5% | 0.58 |
  | `_ContiguousArrayStorage.__deallocating_deinit` | 10.5% | 11.0% | 6.0% | 5.8% | 0.55 |
  | `swift_arrayDestroy` | 10.3% | 10.9% | 5.9% | 5.7% | 0.54 |
  | `outlined consume of TerminalScalars.Storage` | 5.6% | 5.4% | 3.3% | 3.2% | 0.59 |
  | `Terminal.moveAndFillCells(in:row:by:)` | 33.8% | 33.2% | 28.9% | 29.5% | 0.87 |
  | `Terminal.moveAndFillRows(...)` | 12.1% | 12.5% | 10.6% | 10.6% | 0.86 |
  | `Terminal.advanceToNextRow(preservingWrapClaim:)` | 12.1% | 12.6% | 10.6% | 10.6% | 0.86 |
  | `outlined init with copy of Terminal.GridCell` | 5.6% | 5.7% | 7.0% | 6.8% | **1.22** |
  | `Terminal.eraseLine(mode:)` | 12.7% | 12.3% | 14.1% | 13.8% | 1.12 |
  | `Terminal.eraseCells(row:columns:)` | 11.6% | 11.2% | 12.9% | 12.7% | 1.12 |
  | `Terminal.clearCellAndPair(...)` | 12.1% | 11.9% | 13.4% | 13.0% | 1.10 |
  | `Terminal.recordDamage(since:)` | 8.6% | 8.7% | 9.8% | 9.3% | 1.10 |
  | `_platform_memmove` | 5.6% | 5.3% | 6.2% | 5.9% | 1.11 |
  | `TerminalInputStream.feed(_:)` | 11.8% | 11.8% | 12.8% | 12.8% | 1.08 |
  | `Terminal.printNarrow(_:breakClass:)` | 3.6% | 3.8% | 4.1% | 4.4% | 1.17 |
  | `swift_isUniquelyReferenced_nonNull_native` | 4.9% | 4.9% | 5.2% | 5.6% | 1.10 |

  `styled-screen-redraw` as an A/A control -- neither primitive appears on that
  shape, so nothing should move, and nothing does: `Terminal.feed` 1.00,
  `recordDamage` 1.00, `_platform_memmove` 1.01, `eraseLine` 0.97,
  `clearCellAndPair` 1.02, `TerminalInputStream.feed` 1.02, every listed node
  within 0.91-1.12.

- Verification that nothing absorbed the work: removing roughly 13 points of a
  fixed-time profile predicts a uniform rescale of about **1.15x**. The
  unrelated nodes land at 1.08-1.17 (`eraseLine` 1.12, `clearCellAndPair` 1.10,
  `recordDamage` 1.10, `TerminalInputStream.feed` 1.08), so nothing grew in
  absolute terms.
- The one node above the band, stated plainly: `outlined init with copy of
  Terminal.GridCell` at **1.22** is genuinely up, and it is the expected
  trade. The old code copied each cell twice -- once into the temp array via the
  bulk `swift_arrayInitWithCopy`, once out of it -- so eliminating the array moved
  the surviving single copy from the bulk symbol into the per-element one. The
  win is the halved copy count plus the removed allocation and teardown, not a
  free move; this node is where the remaining half shows up.
- Correctness: `just test` exit 0 -- 619 core tests in 84 suites, the one
  pre-existing known issue, plus 1111 protocol, 115 support, 30 shell-contract.
- Correctness verification, which matters more than usual here: a reversed
  traversal direction does not crash, it silently duplicates one element across
  the shifted strip. Mutation-tested by swapping the ascending and descending
  branches, which fails **2207 assertions across 8 suites** --
  `TerminalFixtureTests`, `TerminalResizeTests`, `TerminalScrollbackBudgetTests`,
  `TerminalEditingTests` and others. ICH, DCH, IL, and DL are each already pinned
  against overlapping moves with distinct per-position content, so no new test
  was required; the direction hazard was already covered from both sides.
- Paired verdict, `benchmark-confirm` against `11a894e`, two full runs:

  | Workload | run 1 | run 2 |
  | --- | --- | --- |
  | `terminal-feed` | **faster** (-6.88%) | **faster** (-7.32%) |
  | `scrollback-stream` | **faster** (-4.03%) | **faster** (-4.91%) |
  | `content-churn` | inconclusive (+0.80%) | inconclusive (+1.18%) |
  | `style-churn` | equivalent (+0.73%) | faster (-2.95%) |
  | `incremental-mixed` | inconclusive (+1.42%) | faster (-3.26%) |

  The claim rests on the two that reproduce: `terminal-feed` at about -7% and
  `scrollback-stream` at about -4.5%. Nothing returned `slower` in either confirm
  run. **This is the first app-level directional win recorded in this file** --
  F5 shipped on headless evidence with an `equivalent` paired verdict, and H1(b)
  was reverted for lack of one.
- Instrument caveat, worth more than the result: `benchmark-quick` on
  `incremental-mixed` was run five times against the same pair of trees and
  returned **-2.03% (inconclusive), +3.90% (slower), +7.61% (slower), -6.05%
  (faster), +0.07% (equivalent)** -- a span of nearly 14 points across every
  verdict the tool can emit, including `slower` twice. Its 2-pair quick rule
  cannot resolve this workload at all. Had the second run been taken as the
  answer, a real win would have been recorded as a regression. Use `confirm` for
  any directional claim on `incremental-mixed`, and treat a lone `quick` verdict
  on it as noise regardless of which way it points.
- Inference: H5 confirmed. The two array-traffic symbols went to exactly zero,
  the destroy path more than halved, and the A/A control did not move.
- Competing interpretations: `incremental-screen-updates` is a fixture whose edit
  pattern is exactly ICH/DCH-shaped, so it flatters this change. That is why the
  claim above rests on the app-level `confirm` verdicts rather than on the
  headless share, and `terminal-feed` and `scrollback-stream` are independent of
  that fixture.
- Uncertainty: low. Two instruments agree, the A/A control is clean, and the
  app-level verdict reproduced.
- Next action: D3. H1(a), H4, H3, and the erase-path research item remain.

## Decision log

### D3 -- H5 shipped; the shift primitives move in place

- Date: 2026-07-28.
- Decision: commit the in-place shift. It is the first change in this file to
  earn a reproducing app-level `faster` verdict, on the workload
  (`terminal-feed`) most directly aimed at what this file studies.
- Method note worth keeping: H5 was scheduled as *a code read first, measurement
  only after*, and that ordering paid. Reading the two functions settled the
  hypothesis' competing explanation in about a minute and told us the fix was a
  traversal-order rewrite rather than a hunt for a retained reference. It also
  detached H5 from H4, which a measurement-first approach would have conflated.
- Consequence: H4 loses the supporting argument F6 had tentatively lent it. F3
  remains its only evidence, and that is still a cross-instrument comparison on
  two different workloads rather than a controlled one.

### D2 -- H2 shipped; `hasInteractionState` is maintained by observers, not by call sites

- Date: 2026-07-28.
- Decision: commit the precomputed flag (F5). It removes about 18 points of the
  feed path on the redraw-shaped workload with no behavior change and no
  app-level regression.
- Design decision inside it: maintain the flag with `didSet` observers on the
  four fields rather than by updating it at each mutation site. The fields are
  written from roughly a dozen places (`clearInspection`, `handleEviction`,
  `setHoveredLink`, `setArmedLink`, reflow, reset, the invalidation itself), and
  a hand-maintained flag would be one forgotten write away from a *missing*
  repaint -- the failure mode this file's correctness rule names as invisible to
  both benchmarks and most tests. The observers cost nothing on the hot path
  because the hot path never writes these fields.
- Consequence: the guard is now one Bool load. If a fifth inspection field is
  ever added, it must be declared with the same observer and added to
  `refreshHasInteractionState`; the arm-only test added in F5 is the pattern for
  covering it.

### D1 -- H1(b) implemented, measured, and reverted; H1's remaining weight is H1(a)

- Date: 2026-07-28.
- Decision: do **not** carry a POD `DamageActionSnapshot`. F4 measured it as no
  win on either instrument, and the change is not free -- it narrows the hover
  diff from "the whole resolved link" to "the run it decorates", which is
  defensible but is a semantic edit bought for nothing.
- Consequence for the candidate ordering: H1's cost is **not** in what the
  snapshot *contains*. The remaining H1 weight is entirely in how often it is
  built, which is H1(a). The Phase 2 gate's open question -- "is H1(a) worth its
  correctness risk given that H1(b) may recover much of the same cost with
  none?" -- is now answered: H1(b) recovers none of it, so H1(a) has to justify
  itself on its own or H1 closes.

## Rejected

### H1(b) -- shrink `DamageActionSnapshot` to POD

Implemented, measured on both instruments, reverted. See F4. Behavior-neutral
(`just test` clean) and no measurable win: the targeted node did not shrink and
the paired benchmark returned `equivalent`.

## Open questions and caveats

- ~~**`incremental-screen-updates` has one profile.**~~ -- discharged by F6, which
  captured two agreeing within 0.6 points. The warning it carried was
  understated rather than wrong: the two shapes share almost no top nodes at
  all. Styled is damage bookkeeping, incremental is row and cell moving. Quoting
  a share without naming the workload is worse than imprecise here; it is
  usually just false for the other shape.
- **F1's incremental column was reported against a node list chosen from the
  styled tree**, which is how a 33%-of-root node (`moveAndFillCells`) stayed
  invisible for the file's first day. When adding a workload column, prune that
  workload's own tree rather than reusing another's node list.
- ~~**The `outlined ...` symbol names may be linker-deduplicated**~~ -- settled by
  F5. They were not misattributed: the two large ones tracked exactly the four
  optional reads in `invalidateInspection`'s guard and collapsed with it.
- **F1's table describes a profile that no longer exists.** F5 removed about 18
  points of the feed path, so every share in F1 has been rescaled by roughly
  1.24x. F1 stays as the record of the starting state; **F6 is the current
  baseline** and is what any new candidate must be sized against.
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
