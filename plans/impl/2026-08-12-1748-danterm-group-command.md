# Add a `danterm group` command

## Context

The CLI has a full `tab` noun (`new`, `rename`, `close`) but no `group`
counterpart. Groups are the top level of the model tree, yet the only way the
CLI touches one today is as a *target*: `danterm tab new --group <group-id>`,
and read-only ids in `danterm ls` / `danterm pane info`.

So a group's name, existence, and membership cannot be driven or asserted from
a script at all. AGENTS.md states DanTerm aims to be fully controllable remotely
and programmatically, and that when the API cannot drive an action you extend it
with a general, reusable command. This adds the group noun.

The trigger was a review finding that tied the gap to the sidebar's inline group
rename. That tie is only partly right, and the plan does not rely on it: an IPC
rename dispatches `Msg.renameGroup` straight into the reducer. It never starts
an AppKit field editor, never reads the `AssociatedKeys.renameTarget`
associated object, and never runs the sidebar's commit or cancel delegate path.
The CLI therefore covers *programmatic* rename only. The inline-rename coverage
gap is real but separate, and it is closed here by a UI-harness test, not by the
new command.

Little new domain logic is needed. `Msg.createGroup`, `Msg.renameGroup`, and
`Msg.deleteGroup` already exist with their `update()` cases in
`lib/DanTermCore/Sources/DanTermCore/Update.swift`. The one domain change is a
background policy on group creation (see the contract below).

## Surface

```
danterm group new --name <name> [--cmd <s>] [--cwd <p>] [--title <s>]
                                [--background | --foreground]
danterm group rename --group <group-id> <name>
danterm group close --group <group-id> [--move-tabs]
```

No `group list`: `danterm ls` already returns every group as
`{id, name, isCollapsed, tabs}` and is the enumeration path a caller uses to
find a group id.

No `--clear` on `group rename`: a group always has a name, unlike a tab's
optional `customTitle`.

`group new` is flag-shaped because it is a sibling of `tab new`, which is
all-flags. `group rename` takes a trailing positional name because it is a
sibling of `tab rename` and `theme set`, which both do.

## Behavior contract

### Group names

Both `group new` and `group rename` normalize the requested name through
`singleLineName` (`EntityTitle.swift`: collapse whitespace runs, including
newlines, to single spaces; nil when the result is empty) and use the
normalized value. A nil result is rejected with `-32602 invalid name`, before
any mutation, leaving the model unchanged.

The guard is required at both boundaries, not cosmetic:

- `.renameGroup` silently returns `[]` when `singleLineName` is nil, so without
  the guard the CLI would exit 0 for a rename that never happened.
- `.createGroup` applies no normalization at all, so without the guard
  `--name "   "` would create a blank group and a name containing a newline
  would stay multiline -- breaking the single-line invariant that rename
  enforces.

### `group new`

`.createGroup` always creates the group *and* a first tab, so the launch spec
applies to that tab. `--cwd` defaults to the CLI's current directory at parse
time, matching `tab new`; a request that omits it falls back to
`env.homeDirectory()`.

Focus follows `tab new`: **background by default**, foreground only with an
explicit `--foreground`. `Msg.createGroup` cannot express this today -- it
forwards to `.createTab` with the default `background: false`, so the new tab
always steals selection. Creation therefore gains a background parameter that
it passes through to `.createTab`.

The reply reuses the existing `tab new` result encoding, giving the caller both
the new group id and its first tab id. Prints JSON.

### `group rename`

Unknown id gives `-32602 group not found` via the existing group-existence
check. Reply carries the group id and its resulting name. Prints nothing,
matching `tab rename`.

### `group close`

Default closes the group's tabs with it; `--move-tabs` reparents them into the
adjacent group first. Three refusals, each a `-32602` raised *before* any
mutation, mirroring how `tab close` refuses the last tab:

| Condition | Error |
|---|---|
| unknown id | `group not found` |
| the model holds only this group | `cannot close the last group` |
| no `--move-tabs` and this group holds every tab | `cannot close the last group with tabs` |

The third refusal matters: that input drives `.deleteGroup` into
`emitTerminateConfirmation`, which would leave the group open and strand a
pending confirmation. The CLI never quits the app as a side effect.

Reply carries the group id, mirroring `tab close`. Prints nothing.

## Ideal vs. what this plan does

The ideal shape is that a group name cannot be invalid by the time it reaches
the reducer -- a validated name type built at every boundary, so
`.renameGroup`'s silent no-op has nothing to guard and `.createGroup` has
nothing to skip. That removes a whole class of "the reducer quietly did
nothing" failures, of which the two boundary guards above are instances.

This plan does **not** do that: it is a cross-cutting refactor touching the
sidebar, the menu commands, checkpoint restore, and `createGroup` /
`renameGroup` / `renameTab` alike, and it is not what the group-command gap
asks for. The trade-off is that this change adds a second and third copy of a
rule the reducer half-enforces already. Recorded so the ideal is not lost --
and note that the count of copies is now the argument for doing it.

## Changes

**`lib/DanTermProtocol` -- wire surface.** Three new methods, `group.new`,
`group.rename`, and `group.close`, each with its `IpcRequest` case, params
encoding, and decoding. `group.new` is not a targeting method; the other two
target `group`. Reuse the generic typed-id target decoder, which already yields
a `GroupId` and the `group required` / `group must be a string` /
`group not found` error vocabulary the catalog tests expect. `IpcRequestMethod`
has an exhaustive `isTargeting` switch, so every declaration moves in lockstep.

**`lib/DanTermProtocol` -- CLI parser.** A `group` verb dispatching
`new|rename|close`. Rename and close follow their `tab` siblings; `new` reuses
the `tab new` flag-loop for `--cmd` / `--cwd` / `--title` / `--background` /
`--foreground`, with `--name` required. The group-id coercion helper already
exists.

**`lib/DanTermCore` -- domain.** Group creation gains a background parameter
forwarded to tab creation. Existing call sites (menu "New Group", sidebar
drag-extract) keep today's foreground behavior.

**`lib/DanTermCore` -- IPC dispatch.** Three cases beside the `tab` ones,
reusing the existing group-existence check, the `tab new` id-diff pattern for
reporting the newly created ids, and the existing entity encoders.

**`cli/main.swift`** -- the three usage lines.

**`integrations/danterm/SKILL.md`** -- required in the same change per
AGENTS.md. Mirror how `tab rename` appears: the synopsis block (kept verbatim
in sync with `usageText`), the per-command targeting rules, the "when to reach
for this skill" table, a recipe, and a stdout-shape row for `group new`
(rename and close print nothing and fall under the catch-all).

## Tests

TDD throughout -- write each failing, confirm the failure reason, then
implement.

**Protocol round-trip** (`DanTermProtocolTests/IpcRequestTests.swift`). The
catalog test asserts the CLI command catalog covers every `IpcRequestMethod`,
so it fails until all three land in the representative-commands list. The
targeting table then covers `group required` for free.

**CLI parsing** (`DanTermProtocolTests/CLIParserTests.swift`). Rows in the
existing missing-target and malformed-id tables; a multi-word `group rename`
name test paired with the `tab rename` one; a `group new` flag test asserting
the encoded background policy; a usage-string test naming all three
subcommands.

**IPC dispatch** (`DanTermCoreTests/UpdateIpcTests.swift`), through the
existing `sendIpc` harness with `requireIpcReply` / `requireIpcError`. House
style is the `// Intent: / // Why it exists: / // Scenario:` triple.

- Names, at *both* boundaries -- new and rename: a whitespace-only name is
  rejected with `invalid name` **and leaves the model unchanged** (no group
  created; the existing name intact); a name containing a newline is accepted
  and stored as a single line.
- Rename sets the name and replies with it; rename of an absent id gives
  `group not found`.
- New creates a group with exactly one tab and replies with both ids; the
  launch spec reaches that tab; **the new tab is not selected by default, and
  is selected with `--foreground`**.
- Close removes the group and its tabs; `--move-tabs` reparents them into the
  adjacent group; the last group is refused; a group holding every tab is
  refused without `--move-tabs` and leaves no pending confirmation behind.

**Sidebar inline group rename** (`tests-ui/SidebarRenameRecycleTests.swift`).
Independent of the new command, and the coverage the trigger finding actually
named: every behavioral test in that suite drives `beginRenamingTab`, and the
one group test asserts layout lanes only. Add a focused test that starts a real
group inline rename via `beginRenamingGroup`, commits it through the field
editor, and asserts the group's name changed exactly once. This is the only
test that exercises the `AssociatedKeys.renameTarget` commit path for a group.

**Message translation** (`DanTermCoreTests/CustomTitleTests.swift`).
`renameCompletionMessages` has no case for group + Enter with a non-empty name
-- the actual commit dispatch -- while every neighbouring branch is covered.
Add it. It proves translation only; it does not substitute for the UI test
above.

**End-to-end smoke** (`scripts/tests/danterm-cli_test.sh`), extending the block
that already extracts a group id from `ls`: `group new`, `group rename`, verify
the name via `ls | jq`, `group close`, verify the group is gone. Plus `grep -qF`
assertions over `danterm help` for the three new usage lines, matching the
existing help assertions.

## Verification

1. `just test` -- the full local gate.
2. `just test-cli` -- the CLI shell smoke above. It is not in the gate, so run
   it explicitly. It needs GUI access and a free dev slot.
3. `just test-ui` -- the sidebar suite, including the new inline group rename
   test. Excluded from the gate, so run it explicitly.
4. Manual slot check, since the point of the change is remote drivability:
   ```
   just launch-slot | tail -1          # capture the socket path
   danterm --socket <sock> group new --name Scratch
   danterm --socket <sock> ls | jq '.groups[] | {id, name}'
   danterm --socket <sock> group rename --group <id> Notes
   danterm --socket <sock> ls | jq '.groups[] | {id, name}'
   danterm --socket <sock> group close --group <id>
   just stop-slot <n>
   ```
   Confirm the sidebar shows the new group and the rename live, that
   `group new` leaves focus where it was, and that
   `group rename --group <id> "   "` exits 1 with `danterm: invalid name` on
   stderr while the sidebar name stays put.

## Commit progress

- [x] `feat(cli): add danterm group rename` -- protocol case, parser, dispatch
  with the name guard, `usageText` + SKILL.md, and the rename tests.
- [x] `test(sidebar): cover committing an inline group rename` -- the UI-harness
  test and the `CustomTitleTests` translation case.
- [x] `feat(cli): add danterm group new and close` -- the remaining two methods,
  the creation background parameter, their refusal contracts, docs, and tests.

## Implementation notes

- The `{id, name}` group reference was written inline in two reply encoders
  (`paneInfo`, `tabNew`). Rather than add a third copy for `group rename`, the
  shape moved into one `IpcEntityEncoder.groupReference` all three now call.
- The name guard lives in core dispatch, not `DanTermProtocol`, because
  `singleLineName` is a `DanTermCore` extension. The protocol layer only proves
  `name` is a string; normalization and the `invalid name` refusal are one step
  in `IpcDispatch`, shared by `group new` and `group rename`.
- Verification step 1 in this plan claimed `just test` runs the CLI shell smoke
  test. It does not -- that is `just test-cli`. Corrected above.
- The plan said `group new` would reuse the `tab new` flag loop. It could not:
  `parseTabNewArgs` has no `--name`, and adding one would let `tab new --name`
  through. `group new` also must reject `--group` and the position flags, which
  that loop accepts. So `group new` got its own `ParsedGroupNew` parser in
  `GroupNewArgs.swift`, modeled on the tab one. That makes the
  `--cmd`/`--cwd`/`--title`/`--background`/`--foreground` block a third copy,
  after `TabNewArgs` and `PaneSplitArgs`. The ideal is one shared parser for that
  block, called by all three; it was left out here because it rewrites two
  parsers this change otherwise does not touch. See Follow Up.
- `group close` resolves the group once and raises its three refusals in the
  order the plan's table lists them: unknown id, last group, last group with
  tabs. It does not call `requireGroup`, which would repeat that lookup. Both
  refusals mirror
  `.deleteGroup`'s own conditions exactly; if that reducer's guards change, these
  must change with them.

## Follow Up

- `scripts/tests/danterm-cli_test.sh:51` asserts the launcher handle's `.pid`
  equals `$launcher_pid`, the backgrounded `dev-slot-launcher.py` process. The
  handle carries the *app* pid from `spawn_detached`, so the two can never be
  equal and `just test-cli` aborts there before running any assertion. The same
  mismatch means `cleanup` kills the launcher and leaks the app's dev slot. Not
  in the gate, so it rotted unnoticed; the new `group` steps in that script are
  therefore unverified by the harness (they were verified by hand against a live
  slot instead).
- `just test-ui` has one failure unrelated to this change:
  `tests-ui/IOSurfaceLayerContentsTests.swift:61`, "contents swaps attach no
  animation and release the old surface", reports "swapped-out surface still in
  use after the swap committed". It reproduces on two consecutive runs and runs
  before any sidebar test in the suite, so it is not caused by the new test.
- `scripts/tests/danterm-cli_test.sh` has a second pre-existing break, again from
  not being in the gate: both help blocks assert
  `grep -qF 'todo clear-completed --pane <pane-id>'`, but `usageText` spells that
  line `todo clear-completed (--pane <pane-id> | --tab <tab-id>)`, so the
  substring cannot match. Fix it with the pid assertion above.
- `shellcheck` reports 11 pre-existing SC2251 findings in
  `scripts/tests/danterm-cli_test.sh` (every `! grep -qF ...` line). They skip
  errexit, so those negative assertions cannot fail the script.
- Extract the shared `--cmd` / `--cwd` / `--title` / `--background` /
  `--foreground` flag block now duplicated across `TabNewArgs.swift`,
  `PaneSplitArgs.swift`, and the new `GroupNewArgs.swift` into one parser the
  three call. Three copies is the point at which the duplication is the argument.
- Adding a `.swift` file to `lib/DanTermProtocol` does not invalidate the build
  plan of the packages that depend on it by path: `swift test --package-path
  lib/DanTermCore` kept failing with "cannot find type 'ParsedGroupNew' in scope"
  until `lib/DanTermCore/Package.swift` was touched. Worth a note in
  agent-docs/build-details.md so the next agent does not read it as a real error.
