# External test corpus expansion

Research started: 2026-07-31.
Continues: [1-external-tests.md](../1-external-tests.md).

- [findings.md](findings.md) -- the append-only evidence chain: the corpus
  census, the two stale rationales, and the unsurveyed corpora.
- [decisions.md](decisions.md) -- the auditable decision log for what to adopt,
  mine, and decline.

## Purpose

Doc 1 surveyed which external suites DanTerm should adopt and set the licensing
and neutrality rules. It was live when this doc opened, because its Milestone
8/9/10 injection points had not been consumed; this doc's Phase 5 evidence
package closed it. This doc owns the narrower successor question, asked once
Milestones 1-8 were checked:

1. Of the cases the pinned corpora classify as **out-of-scope**, which are
   blocked on a feature DanTerm does not implement, and which are blocked only
   on a rationale that has since gone stale?
2. Which reusable corpora does doc 1's candidate table not consider at all?

It does not reopen doc 1's settled boundaries: the neutrality rule (never
regenerate-and-auto-accept another emulator's output as DanTerm truth), the
licensing rules, the wraptest declination (doc 2), or the 2026-07-21 Milestone 6
closure adjudication of WezTerm/xterm.js/Contour.

## Investigation rules

- An out-of-scope case is only reclassifiable if the behavior it asserts is
  reachable through `TerminalCore`'s **current** public surface. Verify against
  the source, not against the roadmap's checkboxes -- a checked milestone does
  not imply a feature landed.
- A stale rationale is a rationale whose stated blocker (a milestone, a seam, a
  staging decision) has resolved. Reclassifying it still requires naming the
  adopted/adapted disposition and the public expectation it will assert.
- Mining a new corpus means translating scenarios and public outcomes. Never
  port another engine's private structures, callback topology, or storage model,
  and never let its output decide a disagreement -- DanTerm's support matrix and
  the protocol specs adjudicate.
- Ghostty is the highest reference-bug risk of any source here, because it is
  the incumbent backend. A Ghostty-derived expectation must be justified against
  the spec or the DanTerm contract, not against "Ghostty does this."
- Under the repository TDD rule, a case that discovers a bug becomes the
  smallest failing native test first, verified failing for the expected reason.

## Trigger and current evidence

Milestones 1-8 are checked in
[plan-terminal-engine/14-roadmap.md](../../plan-terminal-engine/14-roadmap.md);
Milestone 9 ("Pass the replacement quality gates") is not, and one of its four
criteria is doc 1's pinned, reproducible, gating evidence package. That prompted
a census of what the pinned corpora currently skip, taken at `593ce4a`.

Both corpora are **fully classified** -- diffing `references/libvterm/t/*.test`
and `references/alacritty/alacritty_terminal/tests/ref/*` against the two
manifests returns zero unclassified entries in either direction (F1). So
"skipped" means exactly the out-of-scope dispositions:

| Corpus | adopted | adapted | superseded | out-of-scope |
| --- | --- | --- | --- | --- |
| libvterm (43 files, 388 cases) | 171 | 105 | 26 | 86 |
| Alacritty (45 recordings) | 11 | 9 | 22 | 3 |

Grouping those 89 by rationale and checking each family against
`lib/TerminalCore/Sources/TerminalCore/` shows ~81 are feature-blocked or
policy-blocked and correctly parked (F2), while two clusters totalling 8 cases
are blocked only on rationales that have since resolved (F3, F4).

## Current hypotheses

### H1 -- the remaining out-of-scope backlog is feature work, not test work

Every large out-of-scope family (horizontal margins, legacy charsets, DEC
double-width lines, DECRQSS, DECSCA) requires implementing a sequence family
before any imported expectation could be asserted. If H1 holds, "apply more
skipped tests" is not a lever on Milestone 9 and the backlog should be tracked
against the support matrix instead of against the manifests.

Supported by F2: a source grep for `DECRQSS`, `DECSLRM`, `DECSCA`, `DECALN`,
`DECSCNM`, charset designation, and `DECIC`/`DECDC` returns exactly one hit, a
comment noting margins do not exist. Rejected if any of those families is found
to be reachable through a differently-named implementation.

### H2 -- rationale staleness is the real defect in the manifests

Manifest rationales cite the milestone or seam that blocked a case at
classification time. Milestones advance; the rationales do not. If H2 holds, the
manifests need a periodic re-adjudication pass keyed to milestone transitions,
not just a one-time classification.

Supported by F3 and F4: two rationales cite Milestone 6 and Milestone 4 blockers
respectively, both now checked, and Milestone 8 Slice 1 already re-adjudicated
the *Alacritty* vttest ledger while leaving the *libvterm* one untouched --
evidence the staleness is per-corpus drift rather than a deliberate hold.

### H3 -- the best unmined corpora are the ones the survey never listed

Doc 1's candidate table treats Ghostty only as a differential replay backend
(and that use was dropped from the Milestone 6 gate). It never evaluates
Ghostty's own test suite as a case mine, despite it being MIT, already checked
out locally, and larger than every surveyed corpus combined (F5). Mid-session,
`references/` gained eight more terminal trees, two of which carry test corpora
the survey also never listed -- windows-terminal's MIT conformance suite and
vte's LGPL one (F8). If H3 holds, the Milestone 9 evidence package has
unexamined sources for exactly the scrollback, selection, style, and
parser-conformance coverage that is hardest to get elsewhere.

The sharpest version of H3 is that a **conformance suite is a safer mine than an
engine's own unit tests**, because it is organized around the specification
rather than around one implementation's choices. Phase 3 confirmed that
prediction: windows-terminal yielded two novel OSC 52 expectations from 4,315
lines, while the 10,777 lines containing Ghostty's 251 selected test blocks
yielded no behavior absent from DanTerm's native contract and suite (F9).

## Candidate direction, pending evidence

Provisional, and explicitly ordered by cost-to-value rather than by size:

1. Re-adjudicate the 8 stale cases (F3, F4) -- cheapest, and it is correctness
   of the manifest as much as coverage. See D1.
2. Scope a mine of Ghostty (F5) and windows-terminal (F8) against the support
   matrix -- Ghostty for `Selection.zig`, `PageList.zig`, and `sgr.zig`;
   windows-terminal for `Base64Test.cpp`, `MouseInputTest.cpp`, and
   `OutputEngineTest.cpp`, which map onto gaps this doc already found. See D2.
3. Close the two Unicode data gaps (F6) -- both reuse the existing generator
   path. See D3.
4. Finish Milestone 9's actual external legs: keep F10's passing, pinned
   14-case esctest2 gate and add replayable external vttest sessions. The
   vttest leg is now the milestone blocker; items 1-3 are not. See D5.

Throughout, `references/xterm/ctlseqs.txt` is the adjudication instrument
(F8): an imported expectation is justified against the specification or the
DanTerm contract, never against the source engine's behavior.

## Task ledger

### Phase 1 -- establish the census (complete)

- [x] Diff both pinned corpora against their manifests for unclassified
  entries. Result in F1.
- [x] Group all 89 out-of-scope cases by rationale and verify each family
  against the current `TerminalCore` source. Result in F2.
- [x] Identify rationales whose stated blocker has since resolved. Results in
  F3 and F4.
- [x] Census Ghostty's local Zig test suite as an unsurveyed corpus. Result in
  F5.
- [x] Identify Unicode/decoder fixture gaps doc 1's table omits. Result in F6.
- [x] Audit the Milestone 9 external legs. F7's initial result was corrected by
  F10: esctest2 already had a pinned 11-case gate; the scope expansion and
  external vttest runner remained.
- [x] Census the eight terminal trees pinned mid-session for test corpora.
  Result in F8.

### Phase 2 -- re-adjudicate the stale libvterm rationales

- [x] Adopt `t/92lp1640917.test` as a neutral fixture asserting that a redundant
  `DECSET 1002` while 1002 is already active does not break motion reporting.
  Confirm first whether DanTerm's X10 report bytes match upstream exactly, or
  whether this lands as `adapted`. Record the disposition and the resulting
  fixture path in F3's next-action.
- [x] Adopt the seven supported `90vttest_*` recordings as full-session neutral
  recordings at their authored dimensions, replayed one-chunk and at split
  points like the existing recordings. Record per-file disposition in F4.
- [x] Keep `90vttest_01-movement-1` out-of-scope, but rewrite its rationale to
  cite the DECALN dependency rather than Milestone 4 staging.
- [x] Rewrite every remaining `90vttest_*` and `92lp1640917` rationale so no
  manifest rationale cites a checked milestone as a live blocker.
- [x] Decide whether manifest re-adjudication becomes a standing milestone-exit
  step. Destination: D4.

### Phase 3 -- scope the Ghostty and windows-terminal mines (complete)

- [x] Read windows-terminal's `Base64Test.cpp`, `MouseInputTest.cpp`, and
  `OutputEngineTest.cpp` first -- they map onto the OSC 52 decode path, the
  mouse-mode hole F3 found, and parser conformance respectively. Record which
  cases assert spec behavior versus console-host specifics. Result in F9.
- [x] Read Ghostty's `Selection.zig`, `PageList.zig`, and `sgr.zig` tests and
  list which assert behavior reachable through DanTerm's public projections
  versus which are coupled to page/style internals. Result in F9.
- [x] Cross-check both shortlists against the native suite for genuine novelty.
  Milestone 8's Slice 18 adjudication found no unique support-matrix behavior in
  the *other* researched sources; F8 rates that analogy as weak for a
  conformance suite, so it must be checked rather than assumed.
- [x] Test H3's sharp form: measure novel portable cases per unit of test-file
  reading for the conformance suite versus the engine unit tests. Result in F9.
- [x] Decide adopt/decline per source. D2 selects windows-terminal's two
  non-ASCII OSC 52 cases and declines Ghostty as a maintained corpus.
- [x] Land the selected windows-terminal cases with a manifest and license
  notice matching the libvterm and Alacritty pattern.
- [x] Record how each shortlisted expectation is justified against
  `references/xterm/ctlseqs.txt` or the DanTerm contract rather than against the
  source engine's behavior. Result in F9 and D2.
- [x] Decline vte's `utf8-test.cc` and `unicode-width-test.cc`: the
  CC-BY-4.0 Kuhn-derived fixture closes the decoder gap without translating
  LGPL-3.0/GPL-3.0 cases, and the generated native suite already exhaustively
  covers DanTerm's Unicode width policy. Result in D3.

### Phase 4 -- close the Unicode data gaps

- [x] Add Markus Kuhn's UTF-8 decoder stress corpus (`UTF-8-test.txt`), pinned
  to an explicit version, as boundary coverage for `UTF8Decoder.swift`'s
  maximal-subpart recovery contract. Confirm its overlong/surrogate/truncation
  cases against the recorded U+10FFFF and U+FFFD deviations first.
- [x] Decide whether double-click word selection claims UAX #29 word semantics.
  If it does, pin `WordBreakTest.txt` at the same Unicode version as the
  existing `GraphemeBreakTest` corpus and generate it through the same path.
  Destination: D3.

### Phase 5 -- Milestone 9's external legs

- [x] Scope the supported esctest2 subset against DanTerm's advertised
  capability contract. F10 retains the passing 11 cases and selects two adapted
  DA1 forms plus one adapted DECCPR form for a 14-case target. The existing
  gate runs the GPL-2.0 program from a separately fetched pinned checkout.
- [x] Land the three selected esctest2 additions and rerun the 14-case gate.
  F10 records the expected failing-first result and the passing adapted gate.
- [x] Select and record the replayable vttest sessions for the gate. F11 chooses
  VT100 DSR/CPR, VT100 DA1, and VT320 DECCPR, and declines unjudged visual
  sessions as gate oracles.
- [x] Land the pinned three-session vttest runner and its result parser. F12
  records the failing-first parser proof, replay correction, and passing gate.
- [x] Reduce every failure either program finds to the smallest native
  byte-stream fixture before fixing it. Neither external program exposed a
  DanTerm behavior failure; the replay-orchestration failure required no native
  fixture.
- [x] Assemble the pinned evidence package and confirm upstream updates cannot
  silently change the gate. This is the criterion that closes doc 1.

## Rejected

### Reclassifying the feature-blocked out-of-scope families

Horizontal margins, legacy SCS charsets, DEC double-width/double-height lines,
DECRQSS replies, DECSCA/selective erase, 8-bit ST, mouse 1005/1015, OSC 52
reads, and the SGR presentation omissions stay out-of-scope. F2 verified none of
them has an implementation. Reopening any one of them is a support-matrix
decision that must precede the test change, not follow it.

### Adopting libvterm's damage-merge and callback-topology cases

`62screen_damage`'s merge modes, `moverect`, and `66screen_extent`'s
attribute-extent query assert libvterm's architecture, not terminal behavior.
DanTerm's damage vocabulary is deliberately row-granular. Unchanged from doc 1's
position; recorded here only so it is not re-litigated as "10 superseded plus 4
out-of-scope looks like a coverage hole."

### Pyte, Kitty, and wraptest

Pyte is LGPL-3.0 and its captured application fixtures are covered by the
adopted Alacritty tmux/htop/Vim recordings. Kitty is GPL-3.0 and Milestone 8
adjudicated its supported-protocol value as already covered by native Kitty
keyboard tests. Wraptest is closed in doc 2 on two independent grounds; its
reopening condition lives there.

### foot and tmux as corpus sources

Not rejected on merit -- they have no corpus to take. F8 found foot's `tests/`
holds only `test-config.c`, with no terminal-behavior suite. tmux's 46
`regress/` scripts are ISC and readable, but they test tmux's own behavior
through a terminal rather than a terminal's behavior, so they belong to
application-workflow evidence (Milestone 8, already closed by live probes)
rather than to the fixture corpus. Both trees remain valuable to *read*, which
is why they are pinned.

## Open questions and caveats

- The census is a point-in-time read at `593ce4a`. Any support-matrix change
  invalidates F2's family-by-family verdict.
- F5's and F8's full-suite counts remain size signals, not novelty signals.
  Phase 3 read and classified the six scoped files; F9's measured result applies
  only to those files, not to every Ghostty or windows-terminal test.
- The eight new reference pins landed mid-session as `4f1f325`, after F1-F7
  were written. F8 is the only finding that depends on them.
- The eight trees were pinned to be *read* for how other emulators solve a
  problem. That two of them also carry test corpora is an opportunity this doc
  noticed, not the stated purpose of the pins -- so Phase 3 should not crowd out
  the reading use they were added for.
- Whether the eight Phase 2 cases are worth their fixture-maintenance cost is a
  judgment; the full-session `90vttest_*` recordings are argued to be worth more
  than their case count because they exercise sequence interleaving the isolated
  fixtures do not, but that argument is untested.
- Doc 1 remains the historical owner of the survey and licensing rules. F12's
  evidence package satisfies its Milestone 9 close condition.

## Outcome

Investigation complete. Phase 1 is complete: the census, both stale
rationales, and the unsurveyed corpora are recorded in F1-F8, with recommended
directions in D1-D5. Phase 2 is complete: `92lp1640917` and the seven supported
`90vttest_*` sessions are adopted, `90vttest_01-movement-1` remains
out-of-scope on DECALN, all nine stale rationales are rewritten, and D4 is
decided. Phase 3 is complete: the scoped sources are classified, Ghostty is
declined, and windows-terminal's two novel OSC 52 cases replay from a neutral
fixture under a complete manifest and bundled license notice. Phase 4 is
complete: a neutral Kuhn-derived corpus pins the decoder's modern
maximal-subpart behavior, while double-click selection is explicitly DanTerm's
terminal-token policy rather than UAX #29 word segmentation. Phase 5 is
complete: F10's pinned 14-case esctest2 gate and F12's pinned three-session
vttest gate pass through the production pane/PTY path. The final evidence
package is recorded in
[`docs/evidence/2026-07-31-external-terminal-gate.md`](../../evidence/2026-07-31-external-terminal-gate.md),
closing doc 1's research condition and Milestone 9's external leg.

The one-line answer Phase 1 produced, for a reader who goes no further: the
pinned corpora are fully classified, ~81 of the 89 out-of-scope cases are
feature or policy decisions rather than test decisions, exactly 8 are
reclassifiable today on stale rationales, and the corpora most worth adding
(Ghostty, windows-terminal) are ones doc 1's survey never listed. The external
vttest leg that blocked Milestone 9 now passes.

**Reopening condition** (a new doc, per the one-way closure rule): a
support-matrix change that lands one of the ~81 feature-blocked families --
DECALN first, which alone holds `90vttest_01-movement-1` out of scope -- since
F2's verdict is a point-in-time read at `593ce4a` and does not survive it.
Re-pinning either mined corpus to a newer revision is the same trigger.
