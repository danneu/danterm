# M9 criterion 1: component-invariant traceability gap tracker

Working document for closing roadmap milestone 9 criterion 1: "Every required
component invariant has the behavioral proof required by
[Testing and conformance](../../plan-terminal-engine/12-testing-conformance.md)."

This file is the handoff surface: it carries enough context for a fresh agent
to continue without the originating conversation. Update the Status column as
items are adjudicated/fixed, and keep the Decision log current.

## How this list was produced

A 6-way parallel audit (2026-07-31) walked every bullet under `## Invariants`
and `## Proof obligations` in plan-terminal-engine docs 01-13 and 16 (~130
bullets; docs 14/15/17 have no such sections) and traced each to named
behavioral tests, lint gates, or scripted harnesses, judged skeptically (a
nearby suite existing did not count; auditors cited actual test names). The
overwhelming majority of bullets are COVERED with named test evidence; this
tracker lists only what is NOT plainly covered, i.e. everything standing
between here and checking criterion 1.

Owner ground rules from milestone 8 carry over: Dan adjudicates each item
(fill with a test, or waive with an honest judgment note in
plan-terminal-engine/14-roadmap.md); TDD applies to any test written (failing
test first, verify expected failure); test preambles follow AGENTS.md
(Intent / Why it exists / Scenario).

## Status legend

- `open` -- awaiting Dan's ruling
- `decided:<fill|waive|accept>` -- ruled, work not yet done
- `done` -- test landed or waiver note recorded
- Recommended disposition is in each item; nothing below is ruled yet unless
  the Decision log says so.

## A. Scoping resolution: doc 16 (semantic model) -- EXCLUDED

Status: decided:waive -- Dan ruled 2026-07-31 that semantic modeling is out of
scope for this review. Doc 16's 13 GAP + 5 PARTIAL rows are not criterion 1
debt; the criterion 1 record should say so, citing doc 16's own Non-goals
("Gating a terminal-engine replacement milestone on this document") and its
README status of "Initial direction captured".

Doc 16 produced 13 GAP + 5 PARTIAL rows, but only because the facet-reducer
slice is unimplemented (its implementation checklist is entirely unchecked; no
facet code exists). Doc 16's own Non-goals section states: "Gating a
terminal-engine replacement milestone on this document." Recommendation:
record doc 16 as excluded from criterion 1 by its own scope declaration.

Heads-up to preserve for whoever implements doc 16 later: its planned
command/connection facet independence (P4) is contradicted by current behavior
-- `commandEnded` clears `remoteSession` (pinned by
lib/DanTermCore/Tests/DanTermCoreTests/UpdateRemoteTests.swift). Also the
envelope has no `integration-ready` event and no exit status on `command-end`.

## B. The one true gap: sleep/wake -- CARRIED TO CRITERION 2

Status: decided:accept -- Dan ruled 2026-07-31. Deferred to M9 criterion 2,
which names sleep/wake explicitly in its gate list (14-roadmap.md). Not a
waiver: it is a real gap with a real owner. Note for criterion 2: this needs
IMPLEMENTATION plus proof, not just proof -- there is no
`NSWorkspace.willSleepNotification` / `didWakeNotification` observer anywhere
in `app/` or `lib/`, so no behavior exists to pin yet.

No test or script anywhere exercises a system sleep/wake or app-activation
transition against the PTY layer. Affected bullets:

- 07-pty-process-lifecycle.md P7: sleep/wake and activation do not lose PTY
  data or duplicate process-exit events.
- 13-power-performance.md I5: sleep/wake does not duplicate events, lose
  read bytes, or leave stale display scheduling active.
- 13-power-performance.md P4 (partial): deactivation/sleep/wake legs of
  stop-and-restart-only-required-work (occlusion/hidden + teardown legs ARE
  covered).
- 03-engine-architecture.md P3 / 12-testing-conformance.md P7 (partial): the
  power boundary's real-adapter proof.

Recommendation: do not patch under criterion 1. M9 criterion 2 (power gates
per 13-power-performance.md) already owns sleep/wake; record this as the known
open item criterion 2 must close, and note that in the criterion 1 record.

## C. Inherited milestone-8 waivers -- RECORDED, NOT FIXED

Status: decided:waive -- Dan ruled 2026-07-31, standing by the milestone 8
decision. These are not new gaps: they are the same manual-probe closure
already adjudicated in 14-roadmap.md (lines ~371-413), seen from the invariant
side instead of the criterion side. The criterion 1 record should cite those
milestone 8 judgment lines rather than restate them. For 02 P1, add that
dual-backend parity goes moot at milestone 10 when Ghostty is removed, so an
automated parity suite would ship with a scheduled expiry date.

These PARTIALs restate the owner-adjudicated manual-probe closure of milestone
8 (recorded 2026-07-31 in 14-roadmap.md, automation intentionally waived):

- 01-product-contract.md P1 / 12-testing-conformance.md P8: prioritized-app
  workflows (tmux/vim-via-neovim/neovim/btop/htop/lazygit/Claude Code/Codex,
  incl. tmux and ssh variant legs) rest on manual probes. Shell tier
  (zsh/bash/fish/ssh/fzf/more/less) IS automated via
  scripts/terminal-workflows.sh + docs/evidence/2026-07-21-*.md.
- 10-protocols-shell-integration.md P2: live-tmux keys/mouse/links/clipboard/
  focus/synchronized-updates untested (recorded-output replay + teardown test
  exist).
- 02-migration-and-boundary.md P1: no automated dual-backend parity suite
  (moot at milestone 10 when Ghostty is removed).

## D. Structural proofs standing in for behavioral tests -- ACCEPTED

Status: decided:accept -- Dan ruled 2026-07-31. No tests written. These
invariants ARE proven, just not by tests, so the criterion 1 record names what
proves each one instead of logging a gap. This is not a waiver: nothing here is
an admitted weakness.

The criterion says "behavioral proof"; these are enforced by lint/construction,
which is stronger than any test could be. Recommend accepting with a note:

- 04-terminal-core.md I3 + 11-configuration-themes.md I1:
  core purity / no config reads, enforced by scripts/core-purity-lint.sh
  `--forbid-imports` (TerminalCore imports nothing, even Foundation) in
  `just test`, with lint self-tests.
- 04-terminal-core.md I4: synchronous transitions -- Terminal is a value type
  with a pull-based API; no callback surface exists to test.
- Process-rule bullets marked N/A by the audit: 02 I3 (experiment isolation,
  historically discharged), 02 I5 (no-permanent-parity scoping), 02 I6
  (removal ordering, enforced by unchecked milestones 9/10), 12 I1
  (tests-assert-behavior meta-rule), 12 I5 (compatibility-claim definition).
- 12 P1 is self-referential: it IS criterion 1; discharged when this tracker
  closes.

## E. Small genuine test gaps -- recommend FILL (each is cheap)

### E1. Search navigation plan/test contradiction (06-inspection-recovery.md P3)

Status: done -- Dan ruled 2026-07-31: wrapping is the intended behavior, he
changed it deliberately because he prefers it; the doc was just stale. Fixed by
editing 06-inspection-recovery.md to "and wraps around at either end". No code
or test change. Doc 06's P3 proof obligation says only "navigation order", so
it needed no edit and TerminalSearchTests.navigationAndOverlaps already
discharges it.

Doc 06 says search navigation "stops at either end rather than wrapping";
TerminalSearchTests.swift "newest-first navigation exposes overlaps and wraps
at both ends" pins wrap-around (searchNext past oldest returns to newest).
One of them is wrong. Ruling needed: keep wrap-around (edit doc 06, one line)
or keep the doc (change behavior + test). Note the shipped UX today is
wrap-around.

### E2. `pane read --lines` logical-line counting (06-inspection-recovery.md P2)

Status: done -- filled 2026-07-31 with
TerminalScrollbackTests.fullHistoryLogicalLinesAreWidthIndependent: the same
content fed at widths 8/13/20/60 must project to identical logical lines.
Verified it can fail: temporarily dropping the `row.isSoftWrapped == false`
guard at Terminal.swift#projectedHistoryText's newline site made it fail at
widths 8/13/20 (returning screen rows), and the guard was restored. Full
TerminalCore suite green (720 tests).

Design note recorded during the ruling: logical lines (not screen rows) is the
right unit here because the consumer is a script/agent -- counting rows would
make `--lines N` return different content after a pane resize. tmux
capture-pane counts rows by default because it is showing a screen; `tail -n`
counts logical lines because a file has no width, and `pane read` is the second
kind of tool.

No end-to-end test proves --lines counts logical lines (not visual rows)
across several widths with soft-wrapped content. Existing coverage:
ReadPaneArgsTests.testTailLines (pre-projected text only) +
UpdateIpcTests.paneReadEmitsScrollbackTailReadWithLineLimit (wiring only).
Fill: one test feeding soft-wrapped content at 2-3 widths and asserting the
same logical tail comes back.

### E3. Duplicate launch on an already-started pane (07-pty-process-lifecycle.md I1)

Status: done -- filled 2026-07-31 with
LifecycleReducerTests.duplicateStartIsInertOnceLaunched: a second `.start` at
the spawning, running, and draining states emits nothing and moves no state.
The finished state was already covered by finishedStateIsTerminal. Verified it
can fail: temporarily adding a `case .start` to
PaneLifecycle.swift#handleRunning made it fail with a second `.spawn` command,
and that case was removed again. Full TerminalPTY suite green (147 tests).

Single ownership was already true, but only via the `default: return []`
catch-all in every live state -- the test converts that silence into a pinned
contract, since a future "restart this pane" feature is the plausible way to
break it.

Single-owner invariant is well pinned for close/exit/race paths
(LifecycleInterleavingTests.namedRacePermutations etc.), but no test drives a
second `.start`/launch request at a pane that already has a live session and
asserts it cannot create a second owner. Fill: one reducer test (and/or host
test) asserting the duplicate request is inert.

### E4. AppKit view teardown with frames in flight (09-renderer.md I5, also 02 I4)

Status: done -- filled 2026-07-31 with tests-ui
"a released pane is unreachable by every controller callback": the pane is
mounted, takes a frame, and is torn out of its window inside an
autoreleasepool; the test then asserts the weak ref is nil and that frames,
viewport state, clipboard writes, semantic events, search status, and hover all
reach nothing. Verified it can fail: making `controller.onFrame` capture self
strongly (dropping one `[weak self]`) failed it with the pane still retained,
and the weak capture was restored. `just test-ui` green (185/185).

Runs in `just test-ui`, so it needs a GUI session and does not run in CI.

Controller/host teardown is rigorously proven
(TerminalPaneSessionControllerTests teardown suite, weak-ref release census).
Missing leg: no test deallocates the AppKit view itself
(app/SwiftTerminalSessionView.swift -- tracking area, isolated deinit,
`[weak self]` setNeedsDisplay redraw hook) while frame callbacks are pending;
rests on docs/design/2026-06-09-appkit-lifetime-safety.md convention. Fill:
one tests-ui test; precedent pattern exists in
tests-ui/PaneWrapperViewTests.swift (weak-ref + autoreleasepool lifetime
test). Runs in `just test-ui` (needs GUI session).

### E5. XTGETTCAP explicit denial (10-protocols-shell-integration.md I2)

Status: done -- filled 2026-07-31 with three XTGETTCAP cases in
TerminalQueryTests `unsupportedQueriesAreSilent` (commit e98e064; citation
corrected in df46a7f -- doc 10 has no I2, the denial is stated in its
unsupported-query prose).

TerminalQueryTests `unsupportedQueriesAreSilent` pins DA2, DECRQSS, and
`>1q` as bit-identical no-ops, but not XTGETTCAP (`DCS + q`). Fill: add the
XTGETTCAP case to that test.

### E6. Cross-normalization search match range (05-unicode-grid-scrollback.md O1)

Status: done -- 2026-08-01. Probing the unpinned behavior turned this from a
test gap into a behavior fix: search neither normalized nor case-folded
outside ASCII, so `Ñ` did not find `ñ` and the two visually identical
n-tildes never matched each other. Search now compares canonical caseless
grapheme keys from generated Unicode 17.0 tables
(`UnicodeProperties.generated.swift`, built by
`scripts/generate-terminal-unicode-tables.py` with source hashes recorded).
TerminalSearchTests `foldingAndUnicodeExactness` pins all four needle forms
against both cells; `canonicalCaselessSearchLimits` pins the excluded scope
(no compatibility decomposition, no cross-grapheme folding). Doc 05's
obligation now states the rule.

Follow-up, still open: rewriting that obligation dropped its other half.
The old bullet also required precomposed and decomposed examples to "render,
select, erase" correctly, and nothing in the list covers that now. Restore it
as its own bullet before this tracker is deleted.

## F. Low-yield remainders

Status: decided -- Dan ruled 2026-08-01. The eight are not one disposition.
Three are not gaps at all and are ACCEPTED; four are real but low-value and
are WAIVED; one is waived with a named follow-up because it is the only
member where a test could plausibly find something the existing coverage
cannot.

### Accepted -- no gap to fill

- 11 I3 (parser state across theme changes): theme presentation-only is true
  by construction. `Terminal` takes no theme, so a theme change cannot reach
  the parser. Writing the test would require first adding the coupling the
  test exists to detect. Accepted on the construction argument, same basis as
  section D.
- 10 P1 (terminfo two-fixture gate): the macOS-ncurses vs current-ncurses
  byte-comparison gate was deliberately retired, not overlooked. One shared
  sequence set stays pinned by the TerminalKeyEncodingTests terminfo test;
  divergence (`pairs`) is covered by prose provenance. Accepted as a standing
  decision.
- 01 I2 (admission discipline): "unsupported legacy behavior is not silently
  treated as a future requirement" governs how work is admitted, not how the
  code behaves. The contract doc and probe allowlist are the mechanism; no
  automated guard is possible. Accepted as process, not code.

### Waived -- real, low value, and self-announcing in daily use

- 13 I8 (power assertions): sampled once via `pmset -g assertions` during the
  opt-in viability idle window, so a transient assertion taken during activity
  would pass unnoticed. Waived: the cost is battery, not correctness, and
  `pmset` reports it on demand at any time.
- 13 P5 (input responsiveness under sustained output): never asserted; the
  bounded-pending-work half of the invariant IS covered. Waived: a wall-clock
  responsiveness assertion on the AppKit main thread is the classic flaky
  test, and a stall here is felt immediately by the sole user.
- 11 P2 (contrast): all six baked-theme color roles are pinned to exact
  values, so a theme cannot drift silently; "readable" is never
  machine-checked. Waived: readability is an eyes-on judgment, and the
  pinned values already prevent the failure mode a test would guard.
- 11 P3 (one settings value across simultaneous panes): per-pane theme
  application and split inheritance are both tested; several panes created at
  once landing on one settings value is not directly asserted. Waived: it is
  the tested path executed more times, with no new code between.

### Waived with a follow-up -- the one worth revisiting

- 10 I7 / P6 (combined resource pressure): every individual bound is pinned at
  its exact limit, but no test drives parser + metadata + events + replies +
  scrollback + damage simultaneously, and the stalled-consumer test uses plain
  output rather than near-limit notification/progress bursts. Waived for
  criterion 1, but flagged as the highest-value remaining test in this
  section: per-bound tests are precisely the ones that miss interaction
  effects, so "each bound holds independently" is the assumption here most
  likely to be wrong. If effort goes anywhere in section F, it goes here.

## Decision log

- 2026-07-31: audit completed; tracker created.
- 2026-07-31: Dan waived the manual sleep/wake probes for section B. Rationale:
  code reading shows the plain sleep case is safe by construction (child
  freezes too, PTY write backpressure, event-driven rendering with no display
  link on the Swift backend, monotonic timers that pause during sleep), the
  residual wake-burst risks are visible-not-silent failures, and as sole user
  Dan will hit the scenarios in daily use and fix forward. Section B's
  criterion-2 carry-forward note still applies; before milestone 10 removal,
  tag the last dual-backend release as the escape hatch.
- 2026-07-31: A ruled EXCLUDE -- semantic modeling (doc 16) is out of scope for
  this review. Before this tracker is deleted, the two heads-up findings in
  section A must be carried into doc 16 itself so they survive.
- 2026-07-31: B ruled CARRY TO CRITERION 2. Criterion 1's record notes
  sleep/wake as a known open item owned by criterion 2; criterion 2 inherits
  both the implementation and the proof.
- 2026-07-31: C ruled WAIVE -- the milestone 8 waiver stands. No new automation
  for the prioritized-app workflows, live-tmux input, or dual-backend parity.
- 2026-07-31: D ruled ACCEPT. Purity lint verified live: it runs in `just test`
  (justfile:46) with `--forbid-imports` on TerminalCore, and has self-tests
  (justfile:52).
- 2026-07-31: E1 ruled KEEP WRAPPING; doc 06 corrected. Item done.
- 2026-07-31: E2 ruled FILL; test landed and verified failing-when-broken.
- 2026-07-31: E3 ruled FILL; test landed and verified failing-when-broken.
- 2026-07-31: E4 ruled FILL; tests-ui test landed and verified
  failing-when-broken.
- 2026-08-01: F ruled as a three-way split rather than a blanket waive. The
  tracker had recommended waiving all eight, which would have recorded three
  non-gaps (11 I3, 10 P1, 01 I2) as debts the project does not actually owe.
  Accepted those three, waived four, and waived 10 I7/P6 with a follow-up as
  the only member where a new test could plausibly find something.
- 2026-08-01: E6 ruled FIX, not fill. Dan pushed back on the initial
  recommendation to pin exact matching; the deciding argument is that search
  already case-folds ASCII on purpose, and a search that fails on text the
  user cannot visually distinguish is worse than one that is case-sensitive.
  Implemented as canonical caseless matching over generated Unicode tables.
- 2026-07-31: E5 ruled FILL; three XTGETTCAP cases landed. The audit cited
  "10 I2", which does not exist -- the denial lives in doc 10's
  unsupported-query prose. Citation corrected in the test comment.

## Close-out

When every section is `done`, check criterion 1 in
plan-terminal-engine/14-roadmap.md with a judgment note pointing at this file
(or a dated evidence doc distilled from it), then delete or archive this
tracker.
