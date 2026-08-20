# One enum per confirmation kind, one answer message

Source: `docs/scratch/2026-08-18-construction-audit.md` MODEL-1 (REDUCE-1
merged into it) plus the unfinished half of CHROME-2.

## 1. Problem and evidence

`PendingConfirmation` (`lib/DanTermCore/Sources/DanTermCore/Model.swift`)
stores a bare `ConfirmationSubject` beside four independently optional
payloads (`tabTitle`, `impact`, `deleteGroup`, `quitAuthorized`). Only five
field combinations are legal and nothing enforces the pairing: three
construction sites hand-fill nils per subject, every arm of
`desiredConfirmation` re-checks the pairing with a defensive `guard`,
`closeConfirmationCopy` carries two `preconditionFailure` arms and
`closeImpact` two `return nil` arms for subjects that have no close data, and
the confirm / choose reducers carry `return []` arms for kinds the panel
should never answer that way.

The output side of the same transaction was already fixed in `55f4eb4d`: the
projection carries a typed `ConfirmationAnswer` per button and the panel
funnels every click and key through one seam. That seam still fans out to
three messages (`confirmConfirmation`, `cancelConfirmation`,
`chooseDeleteGroupConfirmation`), so the reducer must still guard an answer
against a kind that cannot accept it.

The notice transaction that landed in `b93df543` is the template: a pending
record is `id` plus one per-case payload enum, and one
`.noticeAnswered(id:answer:)` message is reduced by switching on
`(subject, answer)`.

No live bug: `reconcilePendingConfirmation` already retracts a confirmation
whose subject dies. This is a retype that deletes the guards, plus the
message collapse the audit's C2 group already decided on.

## 2. Decision

- `PendingConfirmation` becomes `id` plus one enum whose cases carry exactly
  their own data: quit; close pane; close tab (with the frozen title); close
  tabs; delete group (with the frozen tab list and destination). The close
  cases carry their `CloseImpact` and `quitAuthorized` non-optionally.
- The subjects a close can name (pane / tab / tabs) are their own type, and
  `closeImpact` and `closeConfirmationCopy` take only that type, so no
  quit or delete-group value can reach them.
- The three answer messages collapse into one
  `.answerConfirmation(id:answer:)` carrying the projection's existing
  `ConfirmationAnswer`. The reducer switches on `(kind, answer)`; a pair
  that does not match is inert (`[]`, model unchanged), the same rule the
  notice reducer uses. The panel's single answer seam sends that one
  message. `confirmationResponse` (production-dead since `55f4eb4d`) goes.
- Scope: `lib/DanTermCore` (Model, ModelOperations, Projections, Update,
  Msg), `app/ConfirmationPanel.swift`, core tests, `tests-ui`
  confirmation panel tests. Persistence is untouched; none of these
  symbols are `public`.

## 3. Invariants

- I1. A pending confirmation cannot be missing the payload its kind needs
  or carry one its kind has no use for (enforced by the type).
- I2. A confirmation kind with no close copy cannot reach the close copy or
  close impact functions (enforced by the type; both crash arms and both
  nil arms are gone).
- I3. Each of the five kinds has a request that raises it: a close-pane,
  close-tab, close-tabs, quit, or delete-group request that meets the
  existing request policy yields a non-nil `desiredConfirmation`. Every
  answer that projection offers, sent through `.answerConfirmation`,
  produces its documented result -- the default answer performs the
  action, and `.cancel` leaves the target untouched and clears the
  pending transaction.
- I4. An answer that does not belong to the pending kind, or that names a
  stale id, changes nothing and returns no commands.
- I5. `desiredConfirmation` stays optional: it returns nil for a tab or
  group that has left the model between the reducer and the projection.
- I6. The close-tab confirmation title is frozen at request time and
  survives a rename while the panel is open (existing behavior,
  `CustomTitleTests`).
- I7. Every existing confirmation behavior is unchanged: newest request
  replaces the pending one; stale-id answers are inert; a dead subject
  retracts the confirmation; new or changed pane work refreshes a frozen
  close alert; authorization follows the subject; delete-group re-emits
  when its destination vanishes; quit copy is a live rollup. The request
  policy is unchanged too: a close request with no warning and no extra
  pane closes directly unless it would empty the app, in which case it
  raises the quit confirmation and leaves the tab in place; deleting an
  empty group deletes it directly; and deleting the last group does
  nothing.

## 4. Proof obligations

- PO1 (I1, I2). Discharged by the compiler; no test. The old five-field
  initializer and the `closeConfirmationCopy(subject: .app ...)` spelling
  no longer compile.
- PO2 (I3). One table-driven core test over the five kinds. Each row
  builds a fixture that actually raises the confirmation under the
  existing request policy -- a pane close with a warning, a tab close
  with more than one pane or a warning, a close of several tabs, a quit,
  and a delete of a non-empty group that has a sibling -- and asserts a
  non-nil projection. The row then sends every answer that projection
  offers, one per fresh fixture, and asserts its behavioral result: the
  default performs the action (pane gone / tab gone / tabs gone /
  `.terminate` / tabs moved), the delete-group discard answer deletes
  without moving, and `.cancel` keeps the target alive and clears
  `pendingConfirmation`. Cancel for delete group is genuinely new
  coverage; today `UpdateGroupTests` checks only that the projection
  offers it.
- PO3 (I4). Core test: a delete-group answer on a close transaction and a
  plain confirm on a delete-group transaction are both inert; a stale id
  is inert. Genuinely new -- today the panel cannot produce the mismatch,
  so no test can express it.
- PO4 (I5, I6, I7). Existing suites must pass unchanged in what they
  assert: `CloseConfirmationTests` (projection follows every subject,
  every subject offers cancel and a distinct default, retract on death,
  refresh on grown work, authorization, app-emptying closes),
  `UpdateGroupTests` delete-group suite, `ProjectionsTests` quit rollup,
  `CustomTitleTests` frozen title, `SnapshotTests` no-restore of the
  pending confirmation, `UpdateLifecycleTests` quit / confirm / cancel,
  and the `UpdateTabTests` request-policy cases -- the last single-pane
  tab raising the quit confirmation instead of closing, and the batch
  close rollup.
  Sites that read the old optionals (`.impact?`, `.deleteGroup?`,
  `.tabTitle`) or send the old messages are rewritten; their assertions
  keep the same meaning.
- PO5 (panel seam). `tests-ui/ConfirmationPanelTests.swift`: the
  click / Return / Escape / close-window assertions now expect
  `.answerConfirmation(id, answer)` with the same answers they asserted
  before.

## 5. Non-goals / accepted risks / rejected ideas

- NG1. Making `desiredConfirmation` non-optional (the audit's original
  wording; retracted by its Correction -- see I5).
- NG2. Reading the tab title live in the projection. Rejected: I6 is
  pinned behavior.
- NG3. Any change to `ConfirmationProjection` or the panel's button
  layout; that half landed in `55f4eb4d`.
- NG4. Notices. They already have the target shape and stay a separate
  slot.
- RI1. Keep the struct and add private per-kind initializers. Construction
  becomes safe but every read still unwraps optionals; the audit's
  "cheaper fallback: none" stands.
- RI2. Retype first, collapse the messages later as a separate CHROME-2
  change. Rejected: the collapse is the last half of an already-landed
  change and is what lets the reducer drop its kind guards; two commits
  would leave the reducer defending against messages the panel can no
  longer send.

## 6. Implementation discretion

- Whether the per-kind enum keeps the name `ConfirmationSubject` (with the
  bare pane/tab/tabs enum renamed) or takes a new name; whether a computed
  close-subject accessor exists for the grown-subject re-request path.
- Whether the test helpers `pendingAppConfirmation` /
  `pendingCloseConfirmation` keep their signatures and only change bodies.
