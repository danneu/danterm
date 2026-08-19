# One target grammar for every danterm subcommand

## Context

`danterm pane focus <pane-id>` takes its target as a positional word. It is the
only one of 27 targeting subcommands that does: every other pane, tab, group,
todo, agent, and theme command names its target behind `--pane`, `--tab`, or
`--group`. An agent that has learned the surface still gets a parse error here,
and the error does not say what the accepted form is -- `danterm pane focus
--pane <id>` fails as `invalid pane id: --pane`.

The positional form is not an isolated slip. Target handling in
`lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift` is hand-rolled per
command in four idioms: a strict two-argument guard (`pane info`, `pane
snapshot`), a careful guard that distinguishes an unknown flag from an
unexpected argument (`pane close`, `group close`), ad-hoc index loops (`pane
zoom`, `pane resize`, `pane rows`, the agent commands), and the positional case.
Four further commands -- `pane read`, `pane input`, `pane tape`, `pane split` --
parse their target as one more case inside their own flag loops. Nothing holds
these to one grammar, so they have drifted: the same mistake produces three
different messages depending on which command you typed, and a target may
appear anywhere in the arguments of some commands and only first in others.

Prior passes saw this and left it. The IPC unification work stated that "the
user-facing `danterm pane focus <id>` CLI surface is unchanged", and the recent
gate-test audit recorded the inconsistency as a CLI surface question rather than
a test problem, encoding the exception in the parser test table.

Outcome: naming a target reads and fails the same way in every subcommand, and
the grammar lives in one place rather than in each parser's habits.

## Decision

Parse and validate a subcommand's target before its command-specific parser
runs. The shared step owns the whole target grammar: which flag or flags the
subcommand accepts, the wording when the target is absent, malformed, or
unrecognized, and the id validation. A command parser receives an
already-validated typed target and only the arguments that follow it, so no
command parser handles a target at all.

The target leads a subcommand's arguments. That is already the form every usage
line documents and every caller in this repo writes. Because the target's two
tokens are consumed before the command parser sees anything, this ordering is
also what lets one shared step serve commands whose tails are hostile to a
general scan: `pane input`'s `--` token separator, `pane tape`'s streaming
flags, `pane split`'s launch flags, and the trailing positional values of `pane
zoom`, `pane resize`, `theme set`, and `tab rename` are all untouched by it.

This is a real tightening for the commands whose loops accept the target
anywhere today, including `pane read --lines 20 --pane <id>` and `pane tape
--follow --pane <id>`.

Alternative targets follow the same shape rather than becoming exceptions: the
todo owner (exactly one of `--pane` or `--tab`) and `tab new`'s anchor (exactly
one of `--group` or `--after-tab`) are resolved by the same step, which hands
the command parser the typed alternative it chose. `tab new` keeps its rule that
an `--after-tab` anchor excludes the other position flags.

The positional form of `pane focus` is deleted outright, not kept as an alias.
Backwards compatibility is not a constraint here, and an accepted second form
would preserve exactly the ambiguity this removes.

Nothing below the CLI parse layer changes. The wire params for `pane.focus` are
already `{"pane": "<uuid>"}`, identical to every sibling method, and the daemon
already resolves and validates targets through one path.

Critical files: `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift`
and the per-command argument parsers beside it (`ReadPaneArgs`, `SendKeysArgs`,
`TapePaneArgs`, `PaneSplitArgs`, `TabNewArgs`),
`lib/DanTermProtocol/Tests/DanTermProtocolTests/CLIParserTests.swift`,
`cli-tests/CLICharacterizationTests.swift`, `cli/main.swift` (hand-synced help
text), `integrations/danterm/SKILL.md`, `scripts/tests/danterm-cli_test.sh`, and
the `pane focus` call sites in `scripts/terminal-viability.sh`.

## Invariants

- **I1** Every targeting subcommand names its target behind a target flag. No
  subcommand accepts a target as a positional word.
- **I2** The target leads a subcommand's arguments, in every subcommand without
  exception. A target flag that appears after any other argument is a usage
  error.
- **I3** No command-specific argument parser reads, validates, or reports a
  target.
- **I4** One vocabulary reports target failures across pane, tab, and group and
  across every subcommand: absent, malformed, misplaced, and
  unrecognized-target-flag are distinct messages, and the same mistake in two
  subcommands differs only in the usage line quoted.
- **I5** A subcommand that takes no arguments after its target rejects any
  trailing argument, distinguishing an unknown flag from an unexpected
  argument.
- **I6** `pane focus` reaches the daemon with the same request method and
  params it does today.
- **I7** The documented surface matches the parser: the bundled `SKILL.md`, the
  `danterm` help text, and the in-tree callers all use the flag form, and none
  of them shows a positional target.

## Proof obligations

- **PO1 (I1, I2, I4)** The parser test table that sweeps every targeting
  subcommand proves the full set of target failures -- absent, malformed,
  misplaced, and unrecognized target flag -- for every target form, including
  the two alternative-target forms, and asserts the canonical message for each.
  `pane focus` appears in it with no exception row; that row's removal is part
  of the evidence.
- **PO2 (I1)** The positional `pane focus` form is rejected, and the error
  names the accepted flag form.
- **PO3 (I5)** Trailing-argument rejection is proved across the no-tail
  subcommands, not just the one that implements it today.
- **PO4 (I3)** Each command-specific parser is exercised on its own tail
  grammar with no target present, showing it neither requires nor accepts one.
- **PO5 (I6)** `pane focus` has end-to-end CLI coverage against the fake
  socket, which it currently lacks entirely: the request it sends is pinned.
- **PO6 (I7)** The gate checks the help text and the bundled `SKILL.md` for the
  `pane focus --pane <pane-id>` spelling and against the positional spelling.
  The existing help smoke test names other subcommands but not `pane focus`,
  and the skill check only compares the bundled bytes against the same source
  file, so neither can catch this today.

## Non-goals

- Trailing positional *values* stay positional: `tab rename ... <name>`,
  `pane zoom ... on|off|toggle`, `pane resize ... 80x24`, `todo add ... <text>`.
  This change is about targets only.

## Accepted risks

- **AR1** Requiring the target to lead could break an out-of-tree script that
  writes a target after another flag, such as `danterm pane read --lines 20
  --pane <id>`. That ordering is undocumented, every in-tree caller already
  leads with the target, and the failure is a loud usage error rather than a
  wrong action.

## Rejected ideas

- **RI1** Accept `--pane` on `pane focus` while keeping the positional form as
  a deprecated alias. Two accepted spellings is the state this change exists to
  end, and there is no user to migrate.
- **RI2** Fix only `pane focus` and leave the extraction idioms in place. It
  settles the reported symptom and leaves the next targeting subcommand free to
  drift the same way.
- **RI3** Share the target grammar only among the parsers written inline in
  `CLIParser.swift`, leaving the four commands with their own argument parsers
  to keep handling targets themselves. Target position would still depend on
  the subcommand, which is I2, and the grammar would still live in several
  places.

## Implementation discretion

- The shared step's shape -- one generic entry point or one thin wrapper per
  target kind -- and how it hands back the remaining arguments and the chosen
  alternative.
- Whether the exact wording of any existing message changes, so long as the
  failure kinds stay distinct and consistent across subcommands.

## Commit progress

- [x] 1. `refactor(cli): parse the target before the command parser` -- the
  shared step and the subcommands parsed inline in `CLIParser.swift`, the
  leading-target rule, and uniform trailing-argument rejection. Carries PO3 and
  the inline half of PO1. `pane focus` keeps its positional form here.
- [ ] 2. `refactor(cli): remove target handling from the command parsers` --
  `pane read`, `pane input`, `pane tape`, `pane split`, `tab new`'s anchor, and
  the todo owner move onto the shared step and lose their target fields and
  target error cases. Carries PO4 and the rest of PO1.
- [ ] 3. `feat(cli): danterm pane focus takes --pane` -- the positional form
  goes away and the parser test table loses its exception row. Carries PO2,
  PO5, and the `SKILL.md`, help-text, gate-check, and script updates for PO6.

## Verification

- `swift test --package-path lib/DanTermProtocol` for the parser suite, then
  `just test` for the gate, which runs the docs lint and the CLI shell tests.
- Against a slot: `just launch-slot`, split a pane, focus it with
  `danterm --socket <slot> pane focus --pane <id>`, and confirm the positional
  form now errors with a usage line that names `--pane`. `just stop-slot <n>`
  when done.

## Implementation notes

- The shared step is `parseCLITarget` in
  `lib/DanTermProtocol/Sources/DanTermProtocol/CLITarget.swift`, with one thin
  wrapper per target kind (`parsePaneTarget`, `parseTabTarget`,
  `parseGroupTarget`) so a command parser gets a typed id and never sees the raw
  word. It takes the list of accepted kinds and returns the kind it chose, which
  is what commit 2's alternative targets need; commit 1's callers all accept one
  kind and ignore the returned kind.
- The four failure kinds read as: absent -> the usage line alone; malformed ->
  `invalid <entity> id: <word>`; misplaced -> `<flag> must come first` above the
  usage line; wrong target flag -> `<flag> is not a target of this command`
  above the usage line.
- A leading argument that is not a target flag reports the usage line rather
  than `unknown flag: <word>`. Reporting the unknown flag would be wrong for a
  command whose other flags are all valid but simply written before the target,
  so `pane close --nope` and `group close --nope` now report the usage line the
  way `tab close --nope` always has.
- An empty target value (`--pane ""`) reports the usage line everywhere. Two
  commands guarded it before and the rest fell through to `invalid pane id: `.
- The target sweep table is split into `sharedTargetCommands` and
  `ownTargetCommands` for the life of commit 2. Only the shared rows can be
  swept for the misplaced and wrong-flag axes; the split disappears when the
  last command parser gives up its target.
