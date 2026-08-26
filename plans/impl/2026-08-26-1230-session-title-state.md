# One title slot, one type: SessionTitleState

## Context

`plans/impl/2026-08-26-1135-declared-titles-cwd-as-display.md` split a pane's
one title slot into two writers, and shipped it as two fields on `SessionModel`:

    var title: String?           // what a program declared, via OSC 0/2
    var recoveredLabel: String?  // what the checkpoint this session restored from carried

That pair has four combinations and three legal ones. "Declared and inherited at
the same time" is forbidden, and the only thing forbidding it is one assignment
inside the reducer's non-empty branch (`PaneLifecycleReducer.swift:129`). That
same assignment is what makes the plan's I3 true -- "after that the recovered
label never returns" holds only because the label was destroyed early, so a
later clear has nothing to fall back to. A rule the whole feature rests on is
carried by remembering to null a second field.

The pair also duplicates its own reading rule. `ModelOperations.swift:640` and
`Persistence.swift:113` are the same `declared ?? inherited` expression written
twice, in two files, and they must stay in the same order for a checkpoint to
store what the tab displays. Nothing connects them.

Three kinds of consumer read the slot and they do not want the same thing: the
display and the checkpoint want either string, IPC wants a declared title only
(`IpcEntityEncoder.swift:195`, documented in `integrations/danterm/SKILL.md`),
and the reducer wants the classification. Two optionals cannot say which is
which, so each consumer restates the rule.

Outcome: the same behavior, with the legal states named by a type instead of
maintained by convention.

## Decision

Replace both fields with one sum type on `SessionModel`.

- **D1.** A session's title slot is a single value with three cases: nothing, a
  label inherited at restore, and a title a program declared. The forbidden
  combination stops being representable.
- **D2.** The empty case is not named `none`. `pane.session?.titleState == .none`
  would silently resolve against `Optional`, not against this type, and compile.
  `undeclared` (or any name that is not `none`) removes the hazard.
- **D3.** The type owns the OSC 0/2 transition table -- non-empty payload,
  empty payload, and what each does to an inherited label -- as one mutating
  operation the reducer calls. The reducer keeps admission and session
  resolution; it stops keeping the rule.
- **D4.** The type exposes exactly two reads: the string a display or a
  checkpoint uses, and the declared title alone. The two duplicated
  `declared ?? inherited` expressions both become the first one, so the display
  and the checkpoint cannot drift apart.
- **D5.** The field is renamed, not kept as `title`. Every site that passes a
  plain `String?` through the memberwise initializer then fails to compile
  rather than silently keeping an old meaning, and no reader mistakes the slot
  for a string.
- **D6.** Behavior does not change, on screen, on disk, or on the wire.
  `PaneSnapshot` keeps its one optional string, restore keeps reclassifying it
  as inherited, `ls` and `pane info` keep reporting a declared title or `null`,
  and `integrations/danterm/SKILL.md` needs no edit.

Critical files: `lib/DanTermCore/Sources/DanTermCore/Model.swift` (the fields,
and the restore construction in `validateAndBuildDetailed`),
`PaneLifecycleReducer.swift` (`reduceSession`), `ModelOperations.swift`
(`paneClaimedTitle`), `Persistence.swift` (`toPaneSnapshot`),
`IpcEntityEncoder.swift`, and the two launch constructions in `Update.swift`.
Everything else is a fixture rewrite: `lib/DanTermCore/Tests/` (~45 sites),
`tests-ui/` harness helpers (~9 sites), and
`scripts/checkpoint-projection-cost-probe.swift`.

## Invariants

- **I1.** A session cannot hold a declared title and an inherited label at the
  same time.
- **I2.** Every observable title behavior matches HEAD: what a pane and a tab
  display, what a checkpoint stores, what IPC reports, and what each OSC 0/2
  payload does.
- **I3.** One definition classifies an OSC 0/2 payload, and one definition
  yields the string a display or a checkpoint uses. No consumer restates
  either.
- **I4.** A pane carrying only an inherited label reports a `null` title over
  IPC, and the accessor IPC uses cannot return an inherited label.

## Proof obligations

- **PO1** (I2): the behavioral title suites keep pinning the same behavior.
  `DeclaredTitleTests`, `SessionReportTests`, `UpdateSessionEventTests`,
  `CustomTitleTests`, `ProjectionsTests`, `DisplayBoundaryTests`, and
  `CheckpointCaptureTests` already cover the full contract, including that a
  declaration retires an inherited label and a later clear falls through to the
  cwd. An assertion that names the old two-field representation may be restated
  against the new cases, and it must stay at least as strong: a test that
  distinguishes a declared title from an inherited one today still
  distinguishes them afterwards. Nothing else about these suites changes.
- **PO2** (I3): a pane's checkpointed title and its displayed title are the
  same string for a declared title and for an inherited label alike -- the
  property the two duplicated expressions leave unstated today.
- **PO3** (I4): `ls` / `pane info` report `null` for a pane whose only title is
  inherited, and the declared string otherwise.
- **PO4** (I1): no runtime test discharges this one; the compiler does. It is
  recorded so a reviewer does not read its absence as a coverage gap.

## Non-goals

- No behavior change of any kind. This lands green with no user-visible
  difference.
- No on-disk or wire format change, and no `SKILL.md` edit.
- No fourth case for a title requested at launch. `pane split --title` and
  `tab new --title` map to the declared case and stay exactly as clearable as
  they are today; making a launch title durable is separate work, and this
  refactor reduces it to adding a case.
- No display or IPC mark distinguishing an inherited label from a declared
  title -- still a non-goal, unchanged from the previous plan.

## Accepted risks

- **AR1.** Roughly 60 mechanical edits across ~20 files. Two of the affected
  trees sit outside `just test`: `tests-ui/` needs a WindowServer, and
  `scripts/checkpoint-projection-cost-probe.swift` compiles only under its own
  recipe. A
  missed site is a compile error rather than a silent behavior change, but the
  gate will not find it, so both must be built explicitly before the commit.

## Rejected ideas

- **RI1.** Keep a computed `title: String?` on `SessionModel` so the ~45
  existing fixtures compile untouched. Its setter would be a second way to
  write the slot that skips the classification -- the ambiguity this refactor
  exists to remove -- kept alive for test convenience. The rewritten fixtures
  are also better: each one says which kind of title it is setting up.
- **RI2.** Move the resolution's cwd fallback into the type. The cwd is an
  independent terminal fact and only a display fallback; folding it in would
  make the type answer a display question and re-couple two facts the previous
  plan separated.

## Implementation discretion

- Whether `paneClaimedTitle` survives as a named function delegating to the new
  read, or is inlined at its callers.
- How an optional string is lifted into the type at the three construction
  sites (restore and the two launch paths).

## Verification

- In the loop: `swift test --package-path lib/DanTermCore` plus `just lint`.
- Before the commit: `just test`, then `just test-ui`, then
  `just checkpoint-projection-cost` -- the last two are the AR1 blind spots and
  the gate covers neither. The probe refuses a direct `swiftc` invocation, so
  that recipe is the only way to compile it.
- No new end-to-end probe. The previous plan's slot probe already covers the
  behavior this must preserve and can be re-run for confidence.

## Commit progress

- [x] 1. Replace `SessionModel.title` and `recoveredLabel` with the one title
      state type, and route every reader and writer through it (D1-D6, PO1-PO4).

## Implementation notes

- The type's two lifting initializers (`init(inherited:)`, `init(declared:)`)
  cover the three construction sites the plan left to discretion: restore
  lifts a checkpoint's optional title, and the two launch paths lift an
  optional launch title.
- `paneClaimedTitle` survives as a named function -- the pane toolbar's
  "would the title repeat the cwd" question still wants a name, and it is now
  one line delegating to `titleState.claimed`.
- The reducer's OSC comment moved onto `applyDeclaration` rather than being
  duplicated: the rule and its reason now sit together on the one definition.
- `checkpoint-projection-cost` ran to `verdict=pass`, but it ran only as the
  AR1 compile check the plan asked for. Its numbers are not offered as a
  measurement -- the machine's idleness was not established.
