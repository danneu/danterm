# Single-source danterm command catalog

## Problem

The accepted CLI grammar, per-command parse-error usage, `danterm help`, and the
command synopsis in `integrations/danterm/SKILL.md` are separate inventories.
The normal gate checks selected help tokens and prevents duplicate usage
literals inside DanTermProtocol, but it does not prove that these four
inventories agree.

The copies have drifted. The parser and SKILL.md accept and advertise
tab-targeted `pane split`, while help advertises only the pane-targeted form.
The parser also says `<uuid>` where help and SKILL.md say `<pane-id>`, and help
says `<id>` where the other surfaces say `<todo-id>`. The gated help suite passes
with these differences.

The desired outcome is one declaration of every public command. Dispatch,
parse-error usage, help, and the SKILL.md synopsis must project from it, so
adding or changing a command cannot leave one of those surfaces behind.

## Decision

DanTermProtocol owns one catalog entry for every public leaf command, including
IPC commands and the local `help`, `skill`, and `doctor` commands. An entry owns
its verb path and aliases, canonical synopsis, help prose, target policy, and
parser route. Help prose may span multiple lines and preserves the content of
today's per-command descriptions, including pane-resize bounds, pane-tape
defaults and flag dependencies, and the remote-quit refusal. The command
dispatcher selects and invokes the entry; it does not keep a parallel command
switch.

The canonical synopsis is also the sole source for parse-error usage. A leaf
usage error adds the `usage: danterm` prefix to its entry's synopsis. Branches
preserve their current missing- and unknown-subcommand error shapes; wherever
an existing message enumerates child commands, that list derives from the
catalog. The one-child `theme` branch continues to report its leaf usage. The
diagnostic sentence that precedes usage for errors such as `pane tape` remains
command-specific, but the appended usage is a catalog projection. Once the
independent usage literals are gone, retire the textual duplicate-usage gate
and its self-test because they have no remaining subject.

The three creation-command synopses compose their common launch and focus flag
fragment from the same shared grammar declaration. The catalog does not replace
that existing cross-command source with three expanded copies.

`danterm help` renders its command section from the catalog. Its surrounding
global-option, defaults, and environment prose remains authored prose. The
renderer uses a simple deterministic layout rather than preserving the current
hand-aligned columns and wrapping.

SKILL.md keeps its exhaustive command overview in a marked generated region.
A deterministic repository generator updates only that region, and a normal
gate check rejects a stale or malformed region. The authored prose that frames
the region names the catalog as the source and states that the region is
generated; it no longer instructs agents to hand-sync the copies. The rest of
the skill remains authored guidance. The checked-in SKILL.md remains the byte
source copied into every app bundle; generation is not a prebuild step.

Use `<pane-id>` for pane targets and `<todo-id>` for todo identifiers on every
surface. Advertise both pane-targeted and tab-targeted `pane split`.

Preserve command semantics, help content, and command-specific diagnostic
detail. This includes the `pane tape` explanations, creation-command defaults,
target rules, output modes, and request encoding. The deliberate behavior
changes are the corrected synopses, normalized help and parse-usage layout, a
generated help row in the SKILL.md synopsis, a usage error for extra help
arguments, and a direct error when a local command receives `--socket` or
`--tcp`.

Land this work before BUILD-2. Both change the normal gate inventory, and
BUILD-2 must validate the test tree that remains after this refactor.

## Invariants

- **I1.** Every accepted public leaf command has exactly one catalog entry and
  one canonical synopsis, and no catalog entry lacks a parser route.
- **I2.** Parse-error usage, help, and the SKILL.md synopsis contain exactly the
  catalog's public commands, aliases, and canonical synopses.
- **I3.** Command-specific parser behavior stays unchanged except for the
  deliberate user-facing changes named in the decision. Help retains the
  current commands' documented constraints even when its layout changes.
- **I4.** A bare invocation prints help to stderr and exits 1. `help`, `--help`,
  and `-h` are help forms only when they are the sole argument; then they print
  the same help to stdout and exit 0 without touching IPC.
- **I5.** `skill` and `doctor` remain local commands and reject explicit
  connection targets. `quit` still requires an explicit connection target.
- **I6.** Regenerating SKILL.md changes only the marked synopsis region, and the
  bundled skill remains byte-identical to the checked-in file.
- **I7.** The repository builds without a code-generation prebuild step.

## Proof obligations

- **PO1 (I1).** Catalog validation proves unique, unambiguous paths and aliases;
  behavioral parser coverage proves every entry reaches its route and reports
  usage from its canonical synopsis.
- **PO2 (I2, I3).** The existing black-box help suite remains an independent
  content oracle rather than comparing the renderer with itself. Hand-written
  expectations cover the corrected `pane split`, pane-id, and todo-id spellings
  and the retained resize, tape, and quit semantics without depending on the
  old column layout. A separate check compares the checked-in SKILL.md region
  with the catalog projection.
- **PO3 (I3).** Existing parser, request round-trip, target, output-mode, and
  error-message suites pass, with assertions changed only for the deliberate
  surface corrections.
- **PO4 (I4).** Black-box CLI tests cover the bare invocation, all three sole-
  argument help forms, and help with trailing arguments, including exit status,
  output channel, error wording, and absence of IPC access. A process-level
  split case proves `pane split --pane <pane-id> -h` still reaches the split
  route rather than help.
- **PO5 (I5).** Black-box CLI tests prove local commands do not connect, reject
  explicit targets, and preserve `quit`'s explicit-target rule and error
  ordering.
- **PO6 (I6).** Generator tests cover matching, stale, missing, duplicate, and
  reversed markers, and prove that an update preserves all bytes outside the
  region. Bundle contract tests continue to compare the bundled resource with
  the repository file.
- **PO7 (I7).** The cold root build and the normal `just test` gate pass from a
  tree whose checked-in generated region is current.

## Non-goals

- Do not replace the command-specific argument parsers with a generic option
  parser or grammar DSL.
- Do not generate the whole skill, its examples, its output contracts, or its
  agent safety policy.
- Do not change IPC methods, JSON shapes, command defaults, or app behavior.
- Do not preserve the current help page or parse-usage wrapping byte-for-byte.

## Accepted risks

- **AR1.** Help and parse-error usage receive a one-time layout change. A
  deterministic projection is worth more than the current hand-aligned
  presentation, and their wording and semantic content remain covered
  behaviorally.
- **AR2.** The checked-in SKILL.md region can be stale during an edit. The normal
  gate makes stale generated documentation unmergeable without adding a
  prebuild step.

## Rejected ideas

- **RI1.** An IPC-only catalog leaves local commands in a second help and
  dispatch inventory, so the same class of drift survives.
- **RI2.** Removing the SKILL.md synopsis eliminates drift but also removes the
  offline command overview agents use to select a command.
- **RI3.** Keeping independent dispatch, parse-usage, help, and skill lists and
  adding equality tests detects drift after it is written but does not remove
  its structural cause.

## Implementation discretion

- The catalog's concrete types, file boundaries, and closure representation are
  implementation choices as long as I1 holds without a parallel dispatcher.
- The generator's executable name and marker spelling are implementation
  choices as long as its check and update behavior satisfies I6 and I7.

## Commit progress

- [x] 1. feat(cli): define validated public command catalog
- [x] 2. refactor(cli): project dispatch, usage, and help from catalog
- [x] 3. build(skill): generate and verify command synopsis
