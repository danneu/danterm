# One close vocabulary, one owner per rule

Source: `docs/scratch/2026-08-26-improvement-audit.md`, Wave 9 --
UPDATE-5 + UPDATE-3 + MODEL-5, verified against the tree on 2026-08-27.

## Problem

Three rules of the reducer's close/confirmation flow each have two writers,
and two of the pairs have already drifted.

1. **"A close that would empty the app asks first."** The single tab close
   (`closeTabBody`, `Update.swift`) tests before it removes anything. The
   batch confirm arm (`answerPendingConfirmation`, `.closeTabs`) removes
   every tab, then notices the app is empty, then asks. Cancel that dialog
   and the window has zero tabs -- a state no other path can produce.
   `CloseConfirmationTests.paneAndBatchThatBecomeAppEmptyingAsk` currently
   pins the wrong behavior (`hasAnyTab == false`) in its batch leg while the
   pane leg of the same test pins the right one.
2. **The close vocabulary** (pane / other-panes / tab / tabs) is declared as
   `ConfirmationSubject` and again as four `ConfirmationKind` cases. The
   reducer translates subject->kind in `emitConfirmation` and kind->subject
   in `closeSubjectHasGrown`, with a dead `.quit, .deleteGroup: return false`
   arm; the test support (`TestSupport.swift`) copies both switches a third
   time.
3. **"A confirmation whose subject is gone is retracted"** lives in
   `reconcilePendingConfirmation` (runs after every message, all six kinds)
   and again as three `guard ... else { return nil }` lines in
   `desiredConfirmation` (`Projections.swift`) covering only three kinds.
   The projection copies are unreachable -- `desiredConfirmation` is called
   only from `app/Reconcile.swift` on a reconciled model -- except that the
   `.deleteGroup` guard is how the projection reads the group and
   destination names out of the live model.

## Decision

Three commits, in this order; each leaves the gate green.

**D1 -- one body for closing tabs.** The single tab close is a batch of one.
One function owns "would this close empty the app; if so ask before removing
anything, or remove and terminate when already authorized". Both the
`.closeTab` path and the batch confirm path reach it.

**D2 -- the vocabulary is declared once, and it carries the frozen facts.**
Replace `ConfirmationSubject` and the four close cases of `ConfirmationKind`
with one target enum whose cases carry exactly the request-time facts each
target has today (the tab title on a tab close, `quitAuthorized` on
pane/tab/tabs, nothing extra on other-panes), and one `ConfirmationKind`
close case that pairs a target with its frozen `CloseImpact`. Impact
computation, alert copy, the grown-subject check, retraction, and the
test-support builders all take the target; no switch maps between two
spellings of the same four cases. The four confirm bodies stay four bodies;
the grown-check-then-re-request step happens once.

This is deliberately not the audit's `ConfirmationKind.close(Close)` with
impact inside each case: impact is computed *from* a target, so that shape
still needs an impact-free target type and keeps two four-case enums.

**D3 -- the projection is a total function of the pending transaction.**
`DeleteGroupConfirmation` freezes the group name and destination name at
emission, the way a tab close freezes its title. All three existence guards
in `desiredConfirmation` are deleted. The reducer's reconcile pass is the
only writer of retraction.

No side effect, path, or `CoreEnv` reader is added; the core-purity lint
is unaffected.

## Invariants

- **I1.** No close path can leave a live window with zero tabs. A close that
  would empty the app either terminates (already authorized) or raises the
  generic quit confirmation with every tab still present; cancelling keeps
  every tab, confirming terminates.
- **I2.** A confirmation subject has exactly one spelling in `DanTermCore`.
  Asking whether a quit or delete-group confirmation "has grown" is not a
  call that compiles.
- **I3.** Frozen per-target facts stay exact: a pane close carries no tab
  title, an other-panes close carries no quit authorization.
- **I4.** `desiredConfirmation(in:)` is `nil` iff `model.pendingConfirmation`
  is `nil`. The projection reads no live model state for a close or
  delete-group confirmation; its copy is immune to a rename while open.
- **I5.** Existing confirmation behavior is unchanged: a subject that grew
  while the panel was open re-prompts instead of closing; quit confirm
  terminates; every existing close/quit/delete-group projection string is
  unchanged.

## Proof obligations

- **PO1 (I1).** `paneAndBatchThatBecomeAppEmptyingAsk`'s batch leg flips to:
  both subject tabs present, `hasAnyTab == true`, quit confirmation pending.
  Add: cancel that quit and both tabs survive with no pending confirmation;
  confirm it and the result is `.terminate` (the quit transaction carries no
  close target, so nothing is removed first -- the same shape the single tab
  close has today).
- **PO2 (I2, I3).** Compile-time; the type shape is the proof. The
  test-support builder reuses the production emitter rather than restating
  it.
- **PO3 (I4).** A scripted sequence that opens each confirmation kind and
  then mutates the model around it (rename the group, delete the frozen
  destination group, close a subject tab, split a subject pane, close an
  unrelated tab) asserts after every `update` that
  `pendingConfirmation != nil` implies `desiredConfirmation != nil`. Plus:
  rename the group while its delete confirmation is open and the projection
  title keeps the frozen name.
- **PO4 (I5).** `swift test --package-path lib/DanTermCore --filter
  CloseConfirmationTests`, `CloseOtherPanesTests`, `ProjectionsTests`,
  `UpdateGroupTests` pass with their assertions unchanged apart from PO1.

## Non-goals / Accepted risks / Rejected ideas

- **NG1.** Collapsing the four confirm bodies into one. They call four
  different removal routines; the plan removes the duplicated *decision*,
  not the bodies.
- **NG2.** Changing when a delete-group confirmation re-emits (frozen tab
  set grew, destination gone). Out of scope.
- **AR1.** A frozen group name goes stale if the group is renamed while the
  dialog is open. Accepted: it matches the frozen tab title today, and the
  dialog is the user's own copy of what they were asked.
- **RI1.** Two-line reorder inside the batch arm (audit's UPDATE-5 ideal).
  Rejected: keeps the empty-app rule with two writers.
- **RI2.** `var closeSubject: ConfirmationSubject?` accessor on the kind
  (audit's UPDATE-3 fallback). Rejected: two vocabularies still drift; a
  fifth target still means editing two enums.
- **RI3.** Adding the two missing projection guards (audit's MODEL-5
  fallback). Rejected: keeps a second writer of retraction.

## Implementation discretion

- Whether `deleteGroupBody(moveTabs: true)` reads the frozen destination or
  keeps re-deriving it (audit note at `improvement-audit.md:7242`); either is
  acceptable in commit 2.

## Commit progress

- [x] 1. D1 / PO1 -- one tab-close body, batch asks before removing.
- [x] 2. D2 / PO2, PO4 -- one close target enum; delete `ConfirmationSubject`
      and the two mapping switches; test support reuses the emitter.
- [x] 3. D3 / PO3, PO4 -- freeze the group names, delete the three guards.

After commit 3: tick UPDATE-5, UPDATE-3, MODEL-5 in the audit's
`## Plan of work` with `-- done <sha>`.

## Critical files

`lib/DanTermCore/Sources/DanTermCore/{Model,Update,ModelOperations,Projections}.swift`,
`lib/DanTermCore/Tests/DanTermCoreTests/{TestSupport,CloseConfirmationTests,ProjectionsTests}.swift`.

## Follow Up

- Tick UPDATE-5, UPDATE-3, and MODEL-5 in
  `docs/scratch/2026-08-26-improvement-audit.md` under `## Plan of work` with
  `-- done <sha>` for commit 3.
