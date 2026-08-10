# Promote the Values-and-Lifecycles ADR and Align the Code

## Context

`docs/scratch/2026-08-10-values-and-lifecycles-adr.md` states the rule that
decides where a terminal-reported pane fact lives: the model owns **values**
(latest report is the whole truth), the pane's stream owns **lifecycles**
(order carries meaning, reports can be refused, truth is session-scoped).
Until now that boundary was picked by accident -- whichever plan happened to
cover a fact decided its home -- and title, cwd, and progress still look
structurally like the mirrored fields that were just deleted.

The draft cannot be cited yet: its own Consequences section forbids any code
comment pointing at the scratch path. So this plan promotes it to
`docs/design/`, then makes the code say the rule. The stream side renames from
the retired word "semantic" to lifecycle vocabulary, while the pane model
keeps its independent latest-value fields flat. IPC projects both owners into
one flat pane document: `command`, `connection`, `agent`, and `integration`
sit beside `title` and `cwd` instead of exposing the internal ownership split.

Exploration turned up two things the ADR did not anticipate, both settled
with the user:

- **Name collision.** `lib/TerminalPTY/Sources/PaneLifecycle` is an existing
  SPM module for the child-process launch/exit/teardown machine, and it
  already owns `PaneLifecycleReducer` and `PaneLifecycleEvent` -- the exact
  names the ADR prescribes for the reported-fact side. `app/SwiftTerminalSessionView.swift`
  imports it, so both meanings would land in one file. Resolution: qualify the
  PTY module as `PaneProcessLifecycle` so the plain word means one thing.
  The collision reaches past that package -- the root `Package.swift` requests
  the product by name, and the UI harness declares its own `PaneLifecycleResult`
  fake -- so commit 2 is a repo-wide rename, not a package-local one.
- **Broken UI harness.** `tests-ui/SidebarViewTestShim.swift` calls
  `semanticStream.apply(.paneTornDown)`, a case that does not exist on the
  event type. `just test-ui` is excluded from `just test`, which is how this
  went unnoticed. Fixed as part of the rename.

Unrelated `lib/TerminalCore` search work is already staged in the tree; it is
not part of this plan and must not be swept into these commits.

## Commit progress

- [x] 1. Promote the ADR to `docs/design/`
- [x] 2. Qualify the PTY process-lifecycle module
- [x] 3. Rename the reported-fact stream to lifecycle vocabulary (CLI key `semantics` -> `live`)
- [x] 4. Flatten lifecycle fields in pane IPC and keep model values flat

---

## 1. Promote the ADR to `docs/design/`

Docs only, no code. Nothing in the repo cites the scratch path yet, so this
commit is what unblocks the three that follow.

- `git mv docs/scratch/2026-08-10-values-and-lifecycles-adr.md docs/design/2026-08-10-terminal-reported-pane-facts.md`.
- Set `Status` to `Accepted`. Keep the existing backtick header style, which
  `2026-08-06-ui-harness-whole-module-substitution.md` already uses.
- Conform to the shape `docs/design/index.md` prescribes: the draft has
  Context, Decision, Consequences but no `References`. Add one citing the code
  the rule governs and the durable design documents it sits beside -- the
  reducer that holds the lifecycles, `Model.swift#PaneModel`, and the
  pure-core/support split ADR. No plan paths: plans are historical and their
  ids are not unique, so any invariant a plan would have carried gets restated
  in the ADR's own prose instead.
- Correct the Naming section: it lists `customTitle` as pane-owned content,
  but `customTitle` is a `TabModel` field. Name the
  actual pane-owned fields instead -- `todos`, `theme`, `fontSizeSteps`.
- Record the collision resolution in Naming, so a later reader does not
  re-derive it: plain `PaneLifecycle*` names the reported-fact machine in
  `DanTermCore`; the PTY child-process machine is `PaneProcessLifecycle`.
- Add the index row to `docs/design/index.md`, appended in date order:
  `- [2026-08-10: Terminal-Reported Pane Facts -- the Model Owns Values, the Stream Owns Lifecycles](2026-08-10-terminal-reported-pane-facts.md)`.
- Add an AGENTS.md "Read before you touch it" row: *Where a new
  terminal-reported pane fact lives* -> this ADR.
- Fix the stale claim in `docs/design/2026-08-06-swift-terminal-engine.md:410`
  that "the live pane semantic model ... moved to `plans/wip/`". It shipped
  (`plans/impl/2026-08-10-1113-...`); point the sentence at the new ADR.
- Amend that register's `I7` and `I11` rows, whose "semantic event" / "semantic
  facts" wording names the pane stream this plan is renaming. Its amendment
  rule requires a commit contradicting a `live` row to amend the row.

Verification: `just test` (the doc lint steps in `scripts/run-test-suite.sh`),
and every relative link in the moved file still resolves from its new
directory depth -- the scratch file sat one level deeper is not true here
(`docs/scratch/` and `docs/design/` are siblings), but the draft has no
relative links today, so this is a check, not an edit.

## 2. Qualify the PTY process-lifecycle module

Pure mechanical rename inside `lib/TerminalPTY`, no behavior change. It lands
before commit 3 so the reported-fact rename has an uncontested vocabulary to
move into.

Postcondition: **no Swift identifier, package manifest entry, or shell script
target names the child-process machine `PaneLifecycle`.** The sweep is over
executable vocabulary -- `.swift`, `Package.swift`, `.sh` -- not prose; this
plan and the historical plans and research documents that discuss the old name
are history and stay as written. Everything the child-process
machine owns gains the `Process` qualifier -- the SPM module and its test
target, the source and test directories, and every type it exports
(`PaneLifecycleReducer`, `PaneLifecycleEvent`, `PaneLifecycleCommand`,
`PaneLifecycleResult`, `PaneLifecyclePhase`).

The sweep is repo-wide, not package-wide. Three places sit outside
`lib/TerminalPTY` and are easy to miss:

- The **root `Package.swift`**, which requests the `PaneLifecycle` product by
  name. Commit 2 does not build until this changes.
- **`tests-ui/SwiftTerminalSessionViewTestShim.swift`**, which declares its own
  process-owned `PaneLifecycleResult` fake. The UI harness compiles against
  substituted sources, so it would stay green while holding exactly the
  ambiguous vocabulary the ADR retires.
- The **shell scripts** that name the module as a path or a lint target
  (`scripts/terminal-backend-boundary-lint.sh`, `scripts/run-test-suite.sh`,
  and the script tests under `scripts/tests/`).

Verification: `just test` covers the packages and the lints -- the boundary
lint and its own test both name the module, so a missed rename fails the suite
rather than passing silently. `just test-ui` covers the shim. Then
`grep -r 'PaneLifecycle' --include='*.swift' --include='*.sh' .` returns
nothing -- at this point in the sequence the reported-fact side is still named
`PaneSemantic*`, so any hit is a missed process-machine site. No new tests; a
rename that changes behavior is a bug.

Non-green until slice 3: `just test-ui` cannot reach the renamed shim against
the current harness source list. `test-ui.sh` omits `LivePaneStateView.swift`
and `PaneSemanticIpcAdapter.swift`; after supplying them, compilation reaches
the already-recorded nonexistent `.paneTornDown` call. Slice 3 owns the source
list catch-up and call removal together.

## 3. Rename the reported-fact stream to lifecycle vocabulary

The ADR's Naming section, applied. Everything is behavior-preserving except
one observable change: the CLI key. That part lands TDD.

**TDD step, first.** The exact-shape IPC reply tests are the only tests that
see this change: they assert the whole `ls` tree and the whole `pane.info`
reply, so the key rename is visible to them and to nothing else. Change the
expected key from `semantics` to `live` in both, watch them fail on the old
key, then flip the encoder and watch them pass. The nested value under the key
is structurally unchanged -- same fields, same discriminators, same typed
shape -- and no `semantics` key survives anywhere. The value, reducer,
recovery, and routing suites stay green throughout, which is what proves the
rest of the rename is behavior-preserving.

Per the ADR, `live` is the right CLI word because a CLI consumer cares that
the state is current rather than history; the enforcement axis is ours, not
theirs.

**Type and file renames** (`lib/DanTermCore/Sources/DanTermCore/`):

| Today | After |
|---|---|
| `PaneSemanticState` | `PaneLifecycles` |
| `PaneSemanticIntegration` | `IntegrationLatch` |
| `PaneSemanticCommand` | `CommandLifecycle` |
| `PaneSemanticConnection` | `ConnectionLifecycle` |
| `PaneSemanticAgent` | `AgentLifecycle` |
| `PaneSemanticEvent` | `PaneLifecycleEvent` |
| `PaneSemanticTransition` | `PaneLifecycleTransition` |
| `PaneSemanticStream` | `PaneLifecycleStream` |
| `reducePaneSemantics` | `reducePaneLifecycles` |
| `LivePaneStateView` | `PaneLifecyclesView` (`semantics(for:)` -> `lifecycles(for:)`) |
| `PaneSemanticRecoverySnapshot` / `State` | `PaneLifecycleRecoverySnapshot` / `State` |
| `paneSemanticInspectionValue` | `paneLifecyclesInspectionValue` |

`AgentActivity` already reads correctly and does not move. The fields of
`PaneLifecycles` stay `integration`/`command`/`connection`/`agent`.

Postcondition: **"semantic" and "facet" do not name the reported-fact stream
anywhere** -- not in types, cases, properties, argument labels, file names,
test names, or doc comments, across `lib/DanTermCore`, `app/`, the test
targets, and `tests-ui/`. The sweep reaches the Msg and session-event cases
(`paneLifecycleChanged`), the `Command` case, the `TerminalSession` protocol's
snapshot and event-apply members, the runtime's view and recovery-capture
members, the checkpoint and persistence graft members, and the encoder's flag
and stored view. File names follow their types.

One exception, and it is not a miss: `TerminalCore.TerminalSemanticEvent` is
the *engine's* semantic event, a different and correct use of the word. It
does not rename, and the adapter that reads it keeps saying so.

**Header comment carrying the rule.** `PaneLifecycleReducer.swift` gets a few
sentences on `PaneLifecycles` citing the ADR by path and clause -- D1 and its
per-fact test, D2 (admission), D3 (one fact, one owner) -- so the rule
travels to the point of edit. Cite the final `docs/design/` path, never the
scratch one.

**Two loose ends in the same commit:**

- `test-ui.sh` hardcodes source paths by filename for the substituted files;
  those that rename must be updated there too. Its current source list also
  omits `LivePaneStateView.swift` and `PaneSemanticIpcAdapter.swift`; add their
  renamed files so the harness compiles the complete reported-fact surface.
- `tests-ui/SidebarViewTestShim.swift` calls `.paneTornDown`, a case that does
  not exist on the event type. Drop the call so `tearDown()` does nothing, and
  confirm `just test-ui` compiles and passes. `just test-ui` is outside `just
  test`, which is how this went unnoticed.

**SKILL.md co-update**, required by the standing rule for any CLI surface
change: `integrations/danterm/SKILL.md` documents the key, its typed JSON, the
`.semantics.` jq recipe, and the command-table rows. All of them say `live`
after this commit.

Verification: `just test`, plus `just test-ui` for the harness fix, plus a live
check through the CLI against a slot -- `just launch-slot`, then
`danterm --socket <slot> ls | jq '..|.live?|select(.)'` and
`danterm --socket <slot> pane info --pane <id>` to confirm the key is `live`
and the value under it carries the same fields and discriminators `semantics`
carried. Key ordering inside the JSON object is not part of the contract and
is not what these checks establish.

## 4. Flatten lifecycle fields in pane IPC and keep model values flat

The storage boundary and the consumer projection answer different questions.
`PaneModel` keeps `title`, `cwd`, and `progress` as direct independent fields;
the pane-owned stream keeps `command`, `connection`, `agent`, and
`integration`. `IpcEntityEncoder` projects both owners into one flat pane
snapshot rather than making clients understand the internal split.

The observable CLI contract becomes:

- `pane.command`, `pane.connection`, `pane.agent`, and `pane.integration`
  carry the same typed objects that commit 3 placed under `pane.live`.
- Neither `pane.live` nor `pane.semantics` survives in `ls`, `pane info`, or
  commands that reuse the `pane info` reply.
- Existing pane fields keep their current wire shape. This change does not add
  `progress` to IPC and does not change persistence.

Land the contract TDD: change the whole-reply expectations for `ls` and
`pane.info` first and confirm they fail against the nested `live` object, then
flatten the encoder projection and confirm they pass. The entity-id collision
test continues to prove that lifecycle fields attach only to pane objects, not
to tabs or groups with the same raw id.

Amend the ADR in the same commit. It must distinguish storage ownership from
external projection, keep the internal `PaneLifecycle*` vocabulary, state that
model values remain flat, and describe the flat IPC shape. Remove the
`PaneReported` and `live` decisions from Naming and Consequences. Update
`integrations/danterm/SKILL.md` everywhere it documents the pane JSON or jq
paths.

Verification: the exact-shape core IPC tests, `just test`, and a live slot
check of both `ls` and `pane info`. The live replies expose the four lifecycle
objects directly on each pane and contain neither `live` nor `semantics`.

## Accepted risks

- **`ProgressState` percentages are not range-typed.** `UInt8` represents
  101-255, which the documented range excludes, so the model's admission
  depends on the engine parser rather than on the type. The ideal fix is to
  make the out-of-range value unrepresentable -- a percent type whose
  initializer refuses it -- not a guard in the `sessionProgress` handler: a
  guard leaves the invalid value constructible everywhere else while the
  comment stays the only enforcement anyone reads. That change touches the
  engine boundary, the persistence codec, and every construction site, and it
  is not what this plan is about; nothing invalid reaches the model today,
  because the single producer validates. Recorded so it is a decision, not an
  oversight.

## Overall verification

1. `just test` after each commit; `just test-serial` if parallel steps
   interleave.
2. `just test-ui` after commit 3 -- it is outside the gate and is the only
   thing that catches the shim.
3. `swift build --package-path lib/TerminalPTY` after commit 2, since the
   module rename touches Package.swift targets that the app build resolves
   separately.
4. End to end after commit 4: `just launch-slot`, drive a pane through a real
   command, and confirm `danterm --socket <slot> ls` and `pane info` report the
   four lifecycle objects directly on the pane with no `live` or `semantics`
   wrapper.
5. `git diff --stat` before each commit to confirm the staged tree excludes
   the unrelated `lib/TerminalCore` search changes already in the tree.

## Implementation notes

- Commit 2 declares `just test-ui` non-green until commit 3. The harness first
  fails because its raw `swiftc` source list omits two existing semantic files;
  once those are supplied, it reaches the known nonexistent `.paneTornDown`
  call that commit 3 already owns.
- The executable-vocabulary sweep uses tracked sources because the raw
  recursive grep enters the ignored `.refs/cmux` checkout and finds an
  unrelated `testSplitCustomSidebarPublishesNewPaneLifecycleEvents` method.
- Commit 3's isolated slot proved `live` in both query shapes and captured a
  running command under it. Localhost SSH was refused because Remote Login is
  disabled, so remote identity remained covered by the unchanged reducer and
  routing suites rather than a live remote session.
- After commit 3, the user chose a flatter consumer contract: pane IPC should
  project lifecycle fields beside model fields instead of exposing either
  owner's storage grouping. The unchecked remainder was re-sliced around that
  decision; the completed rename commits remain unchanged.
- Commit 4's isolated slot verified the flat fields in both `ls` and
  `pane info`, with no `live` or `semantics` wrapper. A background `sleep 15`
  appeared synchronously under `pane.command` as a running command.
