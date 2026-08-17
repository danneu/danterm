# Retire the logical-line probe island

## Problem and evidence

`lib/TerminalCore/Tests/TerminalCoreTests/` holds nine `*Probe*.swift` files,
4,811 lines, none of which runs in the gate. Each `@Test` carries
`.enabled(if:)` against one of three env vars, and no `justfile` recipe or script
sets any of them -- they are run by hand from invocations quoted in
`docs/research/31-logical-line-scrollback/`. They are not assertion-free: the six
retired ones carry 67 `#expect` checks between them, validity gates gating their
own stimuli, checksums, and reproduced structures. Every one of those checks is
env-gated too, so what deletion removes is fidelity checking for measurements that
can no longer be taken -- not coverage the gate has ever had. Three premises carry
this plan.

**Most of them can no longer measure anything.** Their comparison arms are paired
against the display-row history store that `9ad7cc55` deleted.
`research/31/DD49` states that `research/31/D4`'s eviction rule and its `AR6`
residency reading "are **not re-triggered**, because neither is runnable at this
revision -- both are paired against today's store, which slice 5 deleted", and
that their verdicts "stand as readings of the store at `5cf61e0`". Five of the
files contain no reference to `LogicalLineStore`, the store that shipped. The
honest charge is not that they produce no number: arm A of the eviction probe
still compiles against `PackedRetainedRow`, which survives for the live-screen
refold. It is that they produce a ratio whose denominator is an unverifiable
reproduction of code that no longer exists and can never again be checked against
it. (`docs/research/README.md` resolves the `research/31/...` prefix.)

**They are compiled twice per gate run, and still maintained.**
`scripts/run-test-suite.sh` compiles them in `lib/TerminalCore/.build-gate`, and
`scripts/ios-portability-gate.sh` cross-compiles them again for the iOS triple,
because `TerminalCore` declares `.iOS(.v26)` and that gate builds pinned packages
with `--build-tests`. Meanwhile `5391260b` renamed a constant through them,
`9ad7cc55` reshaped them, and `069b0090` had to add an `#if os(macOS)` guard
inside the eviction probe purely to keep the iOS gate green -- maintenance paid
with the verification switched off. Last touched `b95d703e`, two days before this
plan.

**The tree has already done this once, for the same reason.** `9ad7cc55` deleted
`TerminalHistoryDepthSizingProbe.swift` when the structure it measured was
removed, and doc 28 records the deletion with a visible "deliberately gone"
comment plus an allow-missing marker at the top of its `README.md` and
`findings.md`. That is the precedent this plan follows, and it is stronger
support than the audit item's own argument.

`docs/scratch/2026-08-11-simplification-audit.md` raises this as S37 and proposes
a second test target inside `TerminalCore`. That mechanism does not work: both
gate steps build every target in the package, including executables -- the gate's
own tree holds built `TerminalCoreBenchmark` and `TerminalBrowseBenchmark`
binaries as proof. Only a sibling package or deletion removes a compile, and a
sibling package was weighed and rejected below.

## Decision

Delete the six probes whose arms are gone from production -- the read, index,
wide-index, blank-index, admission, and eviction probes, 4,145 lines. Git holds
each at the revision where it last produced a number, and `research/31/D4` holds
the rule and the verdict; re-running one means checking out `5cf61e0`, which is
more faithful than dragging a half-updated copy forward. Deleting all six removes
the shared measurement harness with them, and with it the prototype stores
(`LogicalLineArena`, `GranularityArena`, `BudgetEnforcedRowStore`) -- the
reimplementations of production that this finding was filed as a symptom of. It
also removes a live hazard the audit never named: the harness defines a
`TerminalCellKind.probeCode` extension, a second and divergent coding of the
field production codes as `packedCode`, visible to every file in the test target.

Three helper functions survive their defining files and move to one small file in
the test target. Nothing else in `TerminalCoreTests` references any harness
symbol; the nine files are a closed island whose only inbound edge is the
history-tail probe's use of a shared fixture.

The three surviving probes stay in the test target, env-gated as they are. The
history-tail cost probe is the wall-clock companion to a live contract test and
was always correctly placed; the pathological and wired-history probes join it on
the same footing. Only the audit's "all nine are alike" framing was wrong.

One arm dies with the move: the wired-history probe's equality reading times a
path production no longer takes. `b95d703e` removed whole-`Terminal` equality
from the owner publish path and amended only the probe's comment. That is exactly
what the six files are being deleted for, so it goes with them.

### Why no new package, and no public API change

A sibling package is the only mechanism that removes the compile from both gate
steps, and it was rejected on two grounds. A package no gate step names is not
preserved -- it rots against the next engine refactor while looking preserved,
which is the failure `TerminalResizeProbeSupport`'s own header warns about; and
adding a gate step for it pays most of the compile back. Relocating the
pathological probe would also have forced a public forwarder for the record-split
cap, because that bound cannot be derived honestly outside the module: the
arithmetic needs internal values with no public analogue, and the only public
observable of the cap is the measurement the probe exists to report, so the
self-check would be circular. `TerminalMemoryProbeSupport` states the rule this
respects -- the budget-taking initializer "is internal on purpose ... a
measurement tool is not a reason to weaken it."

Deleting the six is where the value is: it removes 86% of the probe line count
from both trees, including the whole iOS cross-compile of those lines, with no
manifest, no recipe, no gate-step edit, and no production change.

### Relation to the seam rule

This plan is filed under the theme whose combined fix is "make the production
object drivable and delete the copy", and the audit asks that the seam rule be
stated before any of its findings land: constructor-injected collaborators yes,
conditional test-only branches no. This plan adds neither. The copies die because
the thing they copied no longer exists. Nothing here touches the `#if
DANTERM_UI_TEST` machinery or `deliverOutputForTesting`, so it can land in any
order relative to the AppRuntime `Ports` work and sets no precedent for it.

## Invariants

- **I1.** No test in the tree reproduces a production structure in order to
  measure it. A probe drives the shipping type or it does not exist.
- **I2.** `TerminalCore`'s public interface is unchanged by this work. A
  measurement tool never widens production access.
- **I3.** The wired-history probe still compiles and runs unchanged when copied
  into a checkout of the pre-cutover baseline revision it is paired to, using
  only API both revisions expose. This is the property that makes its ratios
  trustworthy, and it is why its helpers stay self-contained rather than being
  sourced from a library that is not a product at that revision.
- **I4.** No recorded research finding or verdict is retro-edited. A deleted
  instrument is recorded as deleted, naming the revision at which it last ran;
  the numbers and dispositions already written stand. The simplification audit's
  authoritative status records that S37 is complete without rewriting its
  historical finding.
- **I5.** Every citation in a linted document resolves, or is declared missing on
  purpose in the file that cites it, where a reader can see the declaration.
- **I6.** The memory probe requests maximal pressure relief before each footprint
  sample and reports the bytes the allocator says it released. The reading is a
  best-effort request, not a guarantee -- `malloc_zone_pressure_relief` promises
  only "best effort" and returns what it managed to release -- so the probe's
  contract is that the reader can see how much hysteresis was removed, never that
  none remains. On macOS 26 the answer is "none": the request is inert there
  (measured during implementation, recorded under Implementation notes), so both
  readings are zero and that zero is the finding. The invariant is that the reader
  can see the answer, not that the answer is nonzero.
- **I7.** `just test` stays green at every commit boundary.

## Proof obligations

- **PO1** (I1): No reimplementation of a history store remains in the test
  target, and no surviving file references a harness symbol.
- **PO2** (I2): The public interface diff for `TerminalCore` is empty.
- **PO3** (I3): The surviving wired-history probe builds and runs in a checkout of
  its baseline revision. A manual check, run once, and recorded.
- **PO4** (I4, I5): `docs-lint` passes; doc 31 carries a visible record of what
  was deleted, why, and the revision each file last ran at; and the
  simplification audit marks S37 complete with the implementation commit and a
  status note that records the six-deleted, three-retained disposition.
- **PO5** (I6): Every footprint sample in the report carries its released-byte
  reading, and a run where the allocator released nothing is distinguishable from
  one where the reading was not taken. No proof attributes the remaining delta
  exactly to retained bytes, because the API cannot support that claim.

  This obligation originally also demanded that repeated runs of one payload vary
  less than they did before. That clause is struck: the request releases nothing
  on macOS 26, so it cannot reduce the spread, and demanding the reduction would
  only invite reading noise as an effect. The measurement that struck it is under
  Implementation notes.
- **PO6** (I7): `just test` green at each commit.

## Non-goals

- Rebuilding any deleted measurement. If a future decision needs one, the
  instrument comes back from git and is re-aimed at the shipped store, which is a
  new finding with its own rule.
- Moving any probe out of the test target, or adding a `just` recipe for one.
  Weighed and rejected above.
- Changing the paired benchmark ladder. `research/31/D4` already names the ladder
  as the instrument that reads the shipped store.
- Touching `scripts/run-test-suite.sh`'s `-warn-long-function-bodies` flag or the
  `.build-gate` scratch path that flag forces. A separate audit item.

## Accepted risks

- **AR1.** Deleting the eviction probe removes the only wall-clock timing of
  admission and eviction at the arena's saturation bound. The benchmark ladder
  runs at roughly 9,935 and 14,382 retained rows while the arena saturates near
  36,508, so no surviving instrument reaches the bound. Correctness there is
  pinned by live store tests; speed is not. Accepted and recorded here so the
  next person attacking the read path knows the signal is absent rather than
  discovering it. Two dead arms and a retired residency ladder are not worth
  1,484 gate-compiled lines to keep the third.
- **AR2.** An instrument that is genuinely needed again costs a `git show` and a
  re-aim rather than a re-run. Accepted because `research/31/DD49` already records
  that these instruments cannot be re-run at this revision, so nothing runnable is
  given up.
- **AR3.** The allocator-settling reading will exist twice: once in the test
  target for the wired-history probe, once in `TerminalMemoryProbeSupport`. The
  duplication is required by I3 and is stated at both sites, rather than removed
  by an import that would break the baseline copy.

## Rejected ideas

- **RI1.** A second test target inside `lib/TerminalCore`, as S37 proposed.
  Membership cannot be the gate: both gate steps build every target in the
  package.
- **RI2.** An executable target inside `lib/TerminalCore`. Same reason -- `swift
  test` builds executables too.
- **RI3.** A sibling package for the survivors. Rejected above: an uncompiled
  package rots while looking preserved, a gate step pays the compile back, and it
  would force a public forwarder that I2 refuses.
- **RI4.** Deleting all nine. It would discard two instruments that still read the
  shipped engine and are the standing instruments of residuals accepted open
  rather than fixed.
- **RI5.** Keeping the probes and only removing the env-var scaffolding. It leaves
  the compile cost, which is most of the complaint.

## Implementation discretion

- Where the three surviving helpers live and what that file is called.
- Whether the spent equality arm is deleted outright or its header claim is moved
  into the historical record first.

## Critical files

- Deleted: the read, index, wide-index, blank-index, admission, and eviction
  probes under `lib/TerminalCore/Tests/TerminalCoreTests/`.
- Edited: the surviving pathological and wired-history probes in the same
  directory; `lib/TerminalCore/Sources/TerminalMemoryProbeSupport/`; and doc 31's
  `README.md` and `findings.md`; and
  `docs/scratch/2026-08-11-simplification-audit.md`.
- Unchanged: `lib/TerminalCore/Sources/TerminalCore/`, the `justfile`,
  `scripts/run-test-suite.sh`, and every `Package.swift`.

## Notes for the implementer

Two mechanisms are settled and easy to get wrong.

`docs-lint`'s allow-missing marker is line-scoped -- it reads paths from the rest
of the line the marker appears on -- so a marker spanning several lines silently
forgives only the first path. Use one marker per line, following doc 28's form at
the top of `docs/research/28-retained-row-optimizations/README.md`. Full-path
citations of the deleted files are four in doc 31's `README.md` (read, index,
blank-index, admission) and five in `findings.md` (read, wide-index, blank-index,
admission, eviction -- one marker covers eviction's two citations).
`decisions.md` cites no full path and needs nothing. Bare filenames with no
directory are never resolved, so they need no treatment either.

The quoted `swift test --filter` invocations in the research docs are invisible to
`docs-lint` and will become stale recipes. Leave them verbatim -- they are what
was run -- and let the appended record carry the disposition rather than editing
ten sites in a closed doc.

## Commit progress

Each commit is independently green and carries its own tests and doc updates.

- [x] **1. Settle the allocator in the memory probe.** Add the pressure-relief
  request to `TerminalMemoryProbeSupport`, apply it before each footprint sample,
  and carry the bytes it reports released into the report beside that sample.
  Discharges PO5. Independent of everything below; lands first because the code it
  is modelled on is in a file commit 3 removes.
- [x] **2. Give the surviving probes their own footing.** Move the three surviving
  helpers into one file in the test target, and delete the wired-history probe's
  spent equality arm. Additive and neutral -- the six files still exist and still
  compile, so the survivors can be run and compared before anything is removed.
  Discharges PO3.
- [ ] **3. Delete the six retired probes.** Remove 4,145 lines, add the
  allow-missing markers and visible comments to doc 31's `README.md` and
  `findings.md`, and append one subsection to that `README.md`'s existing
  `## Outcome` recording what was deleted, why, and the revision each file last
  ran at. Markers and record ship together so `docs-lint` passes at this commit
  and no marker points at an absent section. Discharges PO1 and PO2, and the doc
  31 part of PO4.
- [ ] **4. Close S37 in the simplification audit.** After commit 3 exists, put
  its SHA in S37's authoritative Status cell and add a Status note to S37 that
  records the final disposition: six obsolete probes were deleted and three
  valid probes remain env-gated by deliberate decision. This separate commit is
  required because commit 3 cannot contain its own SHA. Completes PO4.

## Verification

- `just test` at each commit boundary (PO6), which includes `docs-lint`,
  `research-index-lint`, and the iOS portability gate.
- After commit 3: `wc -l lib/TerminalCore/Tests/TerminalCoreTests/*Probe*.swift`
  reports three files totalling under 700 lines, down from nine and 4,811. A
  grep for the harness symbols and for `probeCode` returns nothing (PO1).
- Confirm the `TerminalCore` public interface is unchanged (PO2).
- Copy the surviving wired-history probe into a checkout of its baseline revision,
  build, and run it; record that it worked (PO3).
- Confirm each footprint sample carries a released-byte reading, and that a report
  without the readings fails to decode rather than reading as a pair of zeroes
  (PO5). The spread comparison this bullet used to ask for was run and is recorded
  under Implementation notes; it is not a standing check, because the request
  releases nothing on macOS 26 and so cannot move the spread.
- Confirm S37's Status cell names commit 3 and its Status note records the
  six-deleted, three-retained disposition (PO4).

## Implementation notes

**Commit 1: pressure relief is inert on macOS 26, and that is what the commit
reports.** The plan assumed `malloc_zone_pressure_relief` clears allocator
hysteresis before a footprint sample. It does not, on Darwin 25.5:

- The process has exactly one zone, `DefaultMallocZone`, at version 16, with its
  `pressure_relief` hook present. The nil-zone form aggregates over the zones and
  skips any at version < 8 or with a null hook, so the hook really is being
  called -- the zero is the allocator's answer, not a skipped call.
- After churning and freeing 400,000 256-byte blocks, then 30,000 8 KB blocks,
  then 4,000 64 KB blocks, a relief request returned 0 and `phys_footprint` did
  not move a single page in any of the three rounds. About 450 MB of freed heap
  was on the floor at the time.
- Six runs of `--payload scrollback-mixed` before the change and six after: the
  delta spread went from 753,664 B to 376,832 B. Not claimed as an effect. The
  direct experiment above shows the call moves no pages, so this is six-versus-six
  run noise, and reporting it as a win would be exactly the confident-wrong number
  doc 15's rules exist to prevent.

The user chose to land the commit anyway with the claim amended rather than drop
it. The reasoning: the instrument now publishes "we asked and the allocator gave
back nothing", which is the honest state, and the reading moves on its own if a
later OS starts honoring the request. I6, PO5, and the verification bullet were
amended in this file to strike the variance-reduction claim.

A consequence worth carrying into commit 3: the eviction probe's own
`settleAllocator()` -- whose comment credits it with fixing negative residency
deltas -- discards the return value and, by this measurement, was very likely
doing nothing by the time it was last touched. That probe is deleted in commit 3
regardless, so nothing turns on it.

**Commit 2: PO3 discharged, and the baseline needs one file, not two.** The three
surviving helpers moved to
`lib/TerminalCore/Tests/TerminalCoreTests/ProbeHostMeasurements.swift`.
`residentHeapBytes()` and `vmmapSummaryLines()` stayed in the eviction probe,
because only that probe calls them and it is deleted in commit 3.

The spent equality arm went outright, which is the first of the two options the
plan left open. Nothing had to move into the historical record first: the probe's
header enumerates three readings and equality was never one of them, so no claim
in the file outlived the arm. Doc 31's `DD52` equality residual is a recorded
finding and stands unedited, per I4.

The baseline check ran against a detached worktree at `28c54e18`, release
configuration, with the edited `TerminalWiredHistoryAttributionProbe.swift`
copied in and nothing else changed. Both remaining arms ran: `drain` over the
1,525,000-byte `scrollback-stream` stimulus and `browse` at 9,935 retained rows.
Copying `ProbeHostMeasurements.swift` in as well does **not** build -- `28c54e1`
still defines all three helpers at file scope in its own probe files, so the
copy collides. The probe's header now says to carry that file only to a revision
that lacks them, which is the honest instruction and keeps the property I3 asks
for.

**The moved `settleAllocator()`'s comment no longer credits it with an effect.**
The eviction-probe original said it was why an early residency invocation stopped
reporting negative deltas. Commit 1 measured the call as inert on Darwin 25.5, so
carrying that claim into the new file would have re-published a number the same
plan had just retired. The moved copy states the duplication AR3 requires, points
at `TerminalMemoryProbeSupport#settleAllocator` for the full measurement, and
says no probe may credit the call with an effect on its readings.

**Both released-byte fields are required, not optional.** `MemoryProbeReport`'s
`schemaVersion` moved to 2 to match. A defaulted or optional field would decode
every archived version 1 report as "the allocator released nothing", which is the
one distinction PO5 asks the encoding to keep.
