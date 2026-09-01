# Reducer per-message budget: price the sweep, then make pane teardown reconcile-owned

Audit items: UPDATE-7 + UPDATE-2 (one combined question) in
`docs/scratch/2026-08-26-improvement-audit.md`. The last open piece of the
"nothing prices a change" / stored-projection theme after d05e4468 (MOBKIT-2)
landed the shell half.

## Context

Every `Msg` pays `update()`'s `defer` sweep -- `reconcileTabState` allocates
two `Set<TabId>` and hashes every tab, `reconcileFocusedPaneAlerts` scans up
to 100 alerts -- and the messages that arrive most often (title/cwd/progress
at 30-60 Hz) cannot change what the sweep repairs. Whether that cost matters
is unmeasured: no workload on the benchmark ladder drives reducer dispatch,
and the audit's own correction predicts the cost claim is false (single-digit
microseconds). UPDATE-7 asks for the number before any change.

Separately, five pane-teardown sites in `Update.swift` hand-write the same
ritual (reject pending IPC work, drop the pane's alerts, clear an anchored
popover) with diverging subsets -- four of the popover lines are provably dead
because `reconcileTodoPopover` already retracts at the chokepoint. UPDATE-2's
ideal moves the whole ritual to the chokepoint too, but that adds a
per-message existence pass -- more of exactly the budget UPDATE-7 questions.
The two cannot both be right, so the probe's number gates the ideal.

## Decision

Two steps, strictly ordered. Step 1's number decides whether step 2 starts
(UPDATE-7); step 2 carries its own retention gate (UPDATE-2's added cost).

**1. Build a permanent headless reducer-dispatch probe** in the shape of
`scripts/checkpoint-projection-cost.py` + its probe source (same-module
compile of `lib/DanTermCore/Sources/DanTermCore` with `-O -wmo`, no
`-enable-testing`; DanTermProtocol as a dylib). Fixture: models at 8, 32, and
128 tabs with a full 100-entry alert feed and `alertClearMode == .focus`
(the default). Workload: 100k dispatches of
`.sessionReport(sessionId:report:.title(...))` against one pane. Report the
median ns/dispatch per tab count with instrument-coverage counts, per
`agent-docs/measurement-discipline.md`. Decision rule, frozen here before any
result exists: the sweep is a real per-message cost only if the 128-tab
median exceeds the 8-tab median by at least 1000 ns/dispatch. The bound comes
from budget arithmetic, not from the data: at the 60 Hz worst case, 1000
ns/dispatch of state-scaling cost is 60 us/s, 0.006% of a core -- below it
the sweep cannot matter at any realistic tab count. Wire it as a `just reducer-dispatch-cost` recipe with a
`--check` typecheck step in `scripts/run-test-suite.sh` and the matching
`scripts/scripts-swift-orphan-lint.py` exemption pair (the lint hardcodes
probe path + gate-step string; a new probe needs both or the lint fails).

**Checkpoint after step 1**: report the numbers to the user. Step 1 settles
UPDATE-7 only. Expected outcome (per the audit's correction): the rule does
not fire, UPDATE-7 closes with no reducer change, and step 2 proceeds. If
the rule fires, stop: step 2's ideal is off the table and UPDATE-2 falls
back to a single `tearDownPanes` helper called from the five sites (a
separate, smaller plan). Step 2 then carries its own retention gate below --
the step-1 run cannot price the existence pass, because that cost also
scales with pending-map cardinality and only exists after the change.

**2. Make pane teardown reconcile-owned** (UPDATE-2's ideal, as corrected by
the audit). `update()` becomes an explicit body-then-tail composition: the
matched arm's commands concatenated with the reconcile tail's commands, the
tail running the existing sweep sequence plus one new existence pass. The
pass uses two authorities, because `PendingSessionCreation` carries no
`PaneId` (`Model.swift:76-79`):

- pane existence (`model.allPaneIds`) answers for `model.alerts` and
  `model.pendingInputSubmissions`;
- session existence (`model.pane(owning:) == nil`) answers for
  `model.pendingSessionCreations`. Safe because `deferCreationReply`
  (`IpcDispatch.swift:536-556`) only ever registers an entry for a session
  whose pane is in the tree, and it runs after its nested `update()` frames
  finish -- no legitimate in-flight entry looks dead.

Entries whose owner is gone are dropped; the two pending maps emit
`.ipcError` (code -32603) for each dropped request. In the returned command
list, every such rejection precedes any `.terminate` -- the runtime performs
commands in order, and last-tab teardown must deliver its replies before
termination begins, as the existing sites deliberately do (I7). Then delete:
the
hand-written ritual at all five sites (`.sessionCreationFailed`,
`deleteGroupBody`, `closePaneBody`, `closeOtherPanesBody`,
`closeTabRemoval`), the four dead popover-clear lines,
`rejectPendingIpcWork`, and `PendingIpcRejectionCause`.

**Retention gate for step 2**, frozen here before any result exists: the
existence pass is priced by a direct baseline-vs-candidate comparison, not
by reusing step-1 numbers -- build the probe binary twice, from the
pre-change and post-change revisions, and interleave their runs
alternately in one session. The deciding cell is 128 tabs with the full
100-entry alert feed, 8 entries in `pendingInputSubmissions` (spread over
two multi-item requests plus single-item ones) and 8 in
`pendingSessionCreations`, each owned by a distinct live pane / session --
the model's own comment puts in-flight counts at single digits, so 8 is
the high end of realistic. Protocol: 10 alternating baseline/candidate
pairs; each side's figure is the median of its 10 per-run medians. Every
run also times fixture construction, which the diff does not touch, as
the same-session control: if the two sides' control medians differ by
more than 10%, the session is invalid and is re-run whole. Step 2 is
retained if the candidate figure exceeds the baseline figure by at most
1000 ns/dispatch (same 60 Hz budget arithmetic as step 1); otherwise
revert it and take the `tearDownPanes` fallback (RI1).

## Invariants

- I1 **Unconditional tail.** The reconcile tail runs on every `update()`
  call, on every path -- MODEL-5's `desiredConfirmation` (86c020fa) deleted
  its existence guards on this promise, and the audit records the dependency.
- I2 **Ownership by existence.** A pane absent from the tree owns no alert
  and no pending input submission; a session with no pane owns no pending
  creation reply. The chokepoint enforces this; removal sites no longer
  carry any teardown obligation, so "a removal path forgot one of the three"
  stops being expressible.
- I3 **Exactly one rejection.** Each orphaned IPC request receives exactly
  one `.ipcError`, across nested `update()` frames and across multi-item
  input submissions sharing a request. (The pass removes what it rejects, so
  an inner frame's pass leaves nothing for the outer frame's.)
- I4 **A move is not teardown.** `.movePaneToTab` / `.movePaneToNewTab` keep
  the pane's alerts and pending submissions -- the pass keys on whole-model
  existence, not one tab's.
- I5 **Same-frame delivery.** The pass's commands return from the same
  `update()` call that removed the owner, so `AppRuntime.dispatchInFrame`
  performs them inline -- never deferred to the coalesced view sweep.
- I6 **View-sweep gating untouched.** `Msg.coalescesReconcile` and
  `reconcileDecision` are downstream of `update()` and unaffected.
- I7 **Replies before termination.** In any command list `update()` returns
  that contains `.terminate`, every `.ipcError` owed by that dispatch
  precedes it.

## Proof obligations

- PO1 (I2, I3): existing behavioral net stays green --
  `UpdateIpcTests` "every pane teardown path rejects that pane's pending
  input exactly once" and "a pane moved to another tab keeps its pending
  input"; `UpdateSessionEventTests` creation-failure / close-during-spawn /
  shutdown rejection tests; `UpdateAlertTests` close-pane / close-tab /
  creation-failed alert pruning; `CloseOtherPanesTests` "confirmed close
  applies ordinary teardown to every removed pane".
- PO2 (I2, new coverage): a pending `pane.input` submission against a pane
  whose whole group is deleted via `.deleteGroup(id:moveTabs:false)` gets an
  `.ipcError` in that dispatch's returned commands.
- PO3 (I4): `.movePaneToTab` on a pane with a pending submission emits no
  error and the submission still replies when delivered (exists at
  `UpdateIpcTests.swift:2821`; keep it green).
- PO4 (I1): `UpdateTodoTests` "reconcile preserves popover opened by the
  current message" and the `movePaneToTab`/`movePaneToNewTab`
  alert-preservation tests stay green; `just lint`'s
  `reducer-command-discard-lint.sh` stays green (it already forces every
  nested `update()` call site to capture commands, which is how tail
  commands propagate).
- PO5 (probe): the probe reports coverage beside every aggregate and refuses
  a verdict on failed coverage, in the pattern of
  `checkpoint-projection-cost-probe.swift`; its `--check` step runs in the
  gate so it cannot silently stop building (the audit's ROOT-CAUSE lesson).
- PO6 (I7, new coverage): closing the app's last tab (and a creation
  failure that empties the app) while a pending creation and a multi-item
  input submission are outstanding returns their rejection errors ordered
  before `.terminate` in the same command list.

## Non-goals / accepted risks / rejected ideas

- **Non-goal:** making the sweep itself cheaper (allocation-free
  `tabStateIsCanonical`, alert-feed restructuring). That work only exists if
  the probe says the sweep is expensive, which the audit predicts it is not.
- **Non-goal:** indexing `pane(_:)` / `pane(owning:)` -- `Model.swift`'s
  header states the no-stored-index trade explicitly; the probe measures the
  budget they sit in but this plan does not touch them.
- **AR1 (wording loss):** the rejection-cause distinction ("pane closed
  before its process started" vs "pane process failed to start") collapses
  to one wording -- the existence pass sees only absence. User-visible in
  IPC error text; pinned by no test and not by `integrations/danterm/
  SKILL.md`. Adjudicated by the audit: accept the loss rather than
  reintroduce a per-pane cause field (the mirror this fix removes).
  `.runtimeWillShutdown`'s distinct wordings are untouched.
- **AR2 (added per-message cost):** the existence pass walks
  `model.allPaneIds` and both maps on every message, including the 30-60 Hz
  traffic. Priced by step 2's interleaved retention gate, with populated
  pending maps in the deciding cell.
- **RI1:** `tearDownPanes` helper at the five sites -- keeps the
  "remember to call it" obligation on every future removal path; it is the
  fallback only if the probe closes the budget.
- **RI2:** dirty flags or cached tab/pane sets to skip the sweep -- the
  audit's own rule: that shape is what the structural findings exist to
  undo, and it would break I1.

## Critical files

- `lib/DanTermCore/Sources/DanTermCore/Update.swift` -- the `defer` block
  (:24-34), the five teardown sites, `rejectPendingIpcWork` /
  `PendingIpcRejectionCause` (deleted).
- `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift` --
  `removeAlertsForPane` (absorbed), reconcile helpers.
- `lib/DanTermCore/Sources/DanTermCore/Model.swift` -- readers only
  (`allPaneIds`, `pane(owning:)`).
- New probe pair under `scripts/` + recipe in `justfile` + `--check` step in
  `scripts/run-test-suite.sh` + exemption in
  `scripts/scripts-swift-orphan-lint.py` (reuse the
  `checkpoint-projection-cost` driver pattern).
- Tests: `lib/DanTermCore/Tests/DanTermCoreTests/UpdateIpcTests.swift`,
  `UpdateSessionEventTests.swift`, `UpdateAlertTests.swift` (fixtures via
  `TestSupport.swift`'s `makeModel`/`createTab` and `UpdateIpcTests`'
  `dispatchPendingInput`).

## Verification

- Step 1: `just reducer-dispatch-cost` runs and prints per-tab-count
  medians with valid coverage; `just lint` and `just test-tooling` green
  (script + gate-step + orphan-lint pair).
- Step 2: TDD the new existence-pass tests (PO2 and PO6 first, failing for
  the expected reason); `swift test --package-path lib/DanTermCore`; `just
  lint`; `just test` before commit; then the interleaved retention gate
  (pre-change vs post-change binaries, alternated in one session).

## Implementation discretion

- Position of the existence pass within the tail's reconcile order, and the
  unified rejection wording (AR1), are the implementer's.
- Probe internals (id minting, scenario naming, scaling self-checks, how
  the pre-change baseline binary is produced for the retention gate) follow
  the `checkpoint-projection-cost` pattern; the two decision bounds are
  frozen in this plan and are not discretion.

## Commit progress

- [x] 1. tooling: add the reducer dispatch cost probe
- [ ] 2. core: make pane teardown reconciliation-owned
- [ ] 3. docs: mark UPDATE-7 and UPDATE-2 complete in the improvement audit

## Implementation notes

- The step-1 checkpoint's frozen rule **fires**, against the audit's prediction.
  Three runs of `just reducer-dispatch-cost` on an idle machine, medians in
  ns/dispatch: 8 tabs 6500 / 6708 / 6667; 32 tabs 14417 / 13667 / 13583;
  128 tabs 40000 / 41375 / 41417. The 128-vs-8 delta is 33500 / 34667 / 34750 ns,
  roughly 35x the 1000 ns bound. Coverage was valid on every run (100000 title
  changes, 0 commands, 100 alerts, mruOrder equal to the tab count).
- The delta bounds the sweep's state-scaling cost from above, not exactly: it is
  the whole dispatch. The fixture holds the arm's own linear session lookup
  roughly constant across sizes -- the target pane is always the first tab of the
  first group -- so what moves between two sizes is the per-tab work the sweep does.
- PO5 was verified the way `measurement-discipline.md` asks: the workload was
  broken on purpose (dispatching against a session id no pane owns), and the probe
  reported `verdict=not-measured reason=coverage-validation-failed` and exit 2
  instead of a timing verdict.
- The probe deliberately has no scaling self-check, unlike
  `checkpoint-projection-cost-probe.swift`. Whether cost grows with the tab count
  is the question, so gating the answer on growth would decide it in advance.
  Coverage is checked on the workload only.
- `scripts-swift-orphan-lint.py` hardcoded one probe/gate-step pair; it now holds a
  map of pairs, so a probe added without its `--check` step still fails the lint.

## Follow Up

- Step 2 (`## Commit progress` entry 2, "core: make pane teardown
  reconciliation-owned") is off the table under the plan's own checkpoint: the
  frozen rule fired, so UPDATE-2 falls back to a single `tearDownPanes` helper
  called from the five sites in
  `lib/DanTermCore/Sources/DanTermCore/Update.swift`. That fallback is a separate,
  smaller plan and is not this plan's entry 2.
- The number the probe returned reopens the non-goal this plan set aside: at 128
  tabs a title report costs ~41 us, and ~35 us of that scales with the tab count.
  `reconcileTabState` builds a `Set<TabId>` in `liveTabIds` and a second one in
  `tabStateIsCanonical` on every message
  (`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift:1181`). Making the
  canonical check allocation-free is now work with evidence behind it.
