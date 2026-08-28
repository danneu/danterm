# Give `doctor` a named instance, stable row identity, and a JSON projection

Audit items CLI-4 and CLI-6 (docs/scratch/2026-08-26-improvement-audit.md),
landed as one doctor change on top of CLI-5.

## 1. Problem

`danterm doctor` opens a control socket to whatever instance ambient
resolution picks and never says which instance answered, so the rows only a
running instance can answer -- the three permissions and the config font --
describe an app the caller did not name. CLI-5 (in the working tree,
uncommitted) already derives `doctor`'s target policy from its wire method and
passes `routed.target` into `gatherDoctorAppFacts` (`cli/main.swift`), so the
flag now exists; the report still does not name the instance.

One instance-owned fact is not even asked of the instance. The app returns
the path of the config file it read, and the CLI then reads that path on the
caller's filesystem and resolves the font against the caller's installed
families (`cli/main.swift:323`, `DoctorProber.swift#gatherConfigFontFacts`).
For `danterm --tcp remote:24863 doctor` that reads an unrelated local file
and reports the caller's fonts under the remote instance's name.

The permission rows' titles encode the answer (`Notifications enabled` vs
`Notifications disabled`, via `evaluatePermission`'s `deniedTitle` in
`cli/Doctor.swift`), so the line a script greps for is the line that
disappears when the answer changes. `DoctorCheckID` exists "so tests and
renderers can find rows without depending on ... title text" and is never
rendered; a script has no id to select on.

`integrations/danterm/SKILL.md` documents the title flip as a feature (doctor
section, ~line 938), and its `## CLI stdout shapes` table claims "only these
subcommands print to stdout" while omitting `doctor`, which prints. The
wave's premise applies: a contract nothing enforces is a comment.

Desired outcome: every instance-owned fact comes from the instance doctor
asked; doctor says once which instance that was and whether it answered;
one title per row regardless of the answer; a machine-readable projection
keyed by stable ids; SKILL.md's generated synopsis gate-checked against
it, and its stdout table updated by hand (generated enforcement of that
table is CLI-7's).

## 2. Decision

- Instance-owned facts are gathered by the instance. `doctorAppFacts`
  returns the permissions, the config file path, and the config-font
  verdict for that file, read at request time on the instance's machine
  against its installed families with today's ladder (unset, unreadable,
  installed, not installed); the CLI stops reading the config file or
  resolving fonts itself. Local facts (CLI install, hooks, skills, `jq`)
  stay local.
- The instance doctor asked is a fact of the query, not of each check, so it
  is reported once: one `instance` row naming the resolved target and whether
  an instance answered. The rendered target is reusable verbatim as the
  `--socket` or `--tcp` argument that reaches it -- a socket path, or
  `host:port` with the host bracketed when it contains a colon.
- When no instance answers -- ambient or explicit, unreachable or typo'd --
  every instance-owned row SKIPs, the instance row says so and names the
  target, and the exit code is unchanged. Doctor's "works with no app
  running" property holds for a bad `--socket` too, and the miss is visible.
- Titles are subject-named and fixed per row id: `Notifications`,
  `Full Disk Access`, `Developer Tools`, `Configured font installed`. The
  outcome lives in the status word and the message. `deniedTitle` goes.
- One report model -- resolved target, answer state, evaluated checks -- is
  rendered as text or, with `doctor --json`, as
  `{instance: {target, answered}, checks: [{id, status, title, message?}]}`.
  `id` is a stable string per `DoctorCheckID` (agent rows encode integration
  and kind, e.g. `claude-hooks`); `status` is the lowercase status word. The
  object form matches every other row in SKILL.md's stdout table.
- SKILL.md moves in the same commit: the doctor section, `doctor` and
  `doctor --json` rows in the stdout-shapes table (and the "only these"
  sentence made true), and the catalog usage string `doctor [--json]` so the
  generated synopsis region carries it and the gate checks it.

Backwards compatibility is not a constraint: today's titles, SKIP messages,
the `doctorAppFacts` wire payload, and the greps in
`cli-tests/DoctorEvaluatorTests.swift` and `scripts/tests/danterm-cli_test.sh`
change with the behavior.

## 3. Invariants

- I1. Every instance-owned row (permissions, config font) describes the
  instance doctor asked -- the explicit `--socket`/`--tcp` target, else the
  same ambient resolution every other querying command uses -- and nothing
  read from the caller's machine stands in for it.
- I2. Every doctor report, text or JSON, names the target doctor asked,
  exactly once, in a form that reaches that target when passed back as the
  matching flag's argument, and says whether it answered.
- I3. For every row id, the title is identical across every fact state.
- I4. The JSON projection and the text report are two renderings of one
  evaluated check list: same ids, order, statuses, and messages; ids are a
  fixed, unique set drawn from `DoctorCheckID`.
- I5. Doctor exits 0 whenever no check is an error, including when the
  target cannot be reached.
- I6. `localOnly` commands open no socket; the parser refuses a target only
  for `skill` and `help`.
- I7. SKILL.md's stdout table lists `doctor` and `doctor --json` (hand
  edited; generated enforcement is CLI-7's), and the generated synopsis
  region matches the catalog (existing gate).

## 4. Proof obligations

- PO1 (I1, I6): `routeCLIInvocation(["--socket", "/x.sock", "doctor"])`
  yields the `.doctor` descriptor with that target; `skill` and `help` with a
  target still throw. `DanTermProtocolTests`.
- PO2 (I1): a config-font verdict carried in the instance's reply is what
  the row reports, even when the caller's local fixture would disagree; the
  `doctorAppFacts` JSON round-trips the verdict; and the producer's reply
  carries the verdict for the file it names -- a file whose `font.family`
  is not installed yields `notInstalled`, so a placeholder or a verdict
  about another file fails. `DoctorEvaluatorTests`,
  `DoctorAppFactsJSONTests`, and a producer-side test (the existing
  `DoctorProberTests` ladder coverage stays with the probe wherever it
  moves).
- PO3 (I1, I2, I5): facts from a target that answered render an instance row
  naming it; facts from one that did not render the instance row as not
  answered, every instance-owned row SKIP, exit 0. Target rendering covers a
  socket path, a hostname or IPv4 `host:port`, and a bracketed IPv6 host.
- PO4 (I3): for each `DoctorCheckID`, titles are equal across every fact
  state the evaluator distinguishes.
- PO5 (I4): the JSON rendering of an evaluated list has the same ids in the
  same order as the text rendering's rows; the id set is exactly one per
  `DoctorCheckID` case for a full fact set; ids are distinct strings.
- PO6 (I2, I5): `scripts/tests/danterm-cli_test.sh` -- with no app, `danterm
  --socket <nonexistent> doctor` exits 0 and names that path; `--json` output
  has `instance.answered == false` and an `id` on every row.
- PO7 (I7): the existing synopsis gate plus `just lint` after the SKILL.md
  edit.
- Behaviorally: `danterm --socket "$SLOT_SOCKET" doctor` reports slot N's
  permissions, config file, and font under slot N's socket; a bare `danterm
  doctor` in a pane reports that pane's instance.

## 5. Non-goals / Accepted risks / Rejected ideas

- Non-goal: teaching the app which socket a request arrived on. The CLI's
  resolved target is the identity; the app stays unaware.
- AR1: with no instance answering, the config-font row SKIPs instead of
  probing the standard config file locally as it does today. A local probe
  is a second answer about a file only an instance can name; the instance
  is the authority, and a font check is advisory.
- AR2: anything grepping today's titles, SKIP messages, or the
  `doctorAppFacts` payload breaks. Only this repository's own tests do; they
  change here.
- RI1: printing the instance inside each instance-owned row (the audit's
  shape). Repeats a query fact per row and gives scripts no row to select it
  by.
- RI2: `--json` as a bare array of rows. Leaves the instance nowhere to live
  and breaks the `{noun: ...}` shape every other stdout row uses.
- RI3: making an unreachable explicit target a command failure. Removes
  doctor's no-app property for one flag and is unneeded once the instance
  row names the miss.
- RI4: keeping the local config-font probe as a fallback for unix-socket
  targets (same host by construction). Two probes of one fact; the SKIP is
  simpler and AR1 bounds the loss.

## 6. Implementation discretion

- How `DoctorCheckID` gains its string form and how the agent ids are
  spelled, provided they are fixed, unique, and documented in SKILL.md.
- Where `--json` is parsed for the `doctor` route and how the JSON is
  serialized; `cli/main.swift`'s existing `compactJson` is the obvious reuse.

## Critical files

`lib/DanTermProtocol/Sources/DanTermProtocol/CLICommandCatalog.swift`,
`DoctorFacts.swift`, `DoctorAppFactsJSON.swift`;
`lib/DanTermSupport/Sources/DanTermSupport/DoctorProber.swift`;
`app/AppRuntime.swift` (`readDoctorAppFacts`); `cli/main.swift`,
`cli/Doctor.swift`; `cli-tests/DoctorEvaluatorTests.swift`,
`scripts/tests/danterm-cli_test.sh`,
`lib/DanTermProtocol/Tests/DanTermProtocolTests/`; `integrations/danterm/SKILL.md`.

## Verification

Red first: PO1-PO5 as failing tests, then the change. `swift test
--package-path lib/DanTermProtocol`, `lib/DanTermSupport`, the `cli-tests`
suite, `just lint`, then `just test` before commit. End-to-end: `just
launch-slot`, run `danterm --socket <slot> doctor` and `... doctor --json |
jq -e '.instance.answered'`, then `just stop-slot`. Finally tick CLI-4 and
CLI-6 in the audit's `## Plan of work`.

## Commit progress

- [x] 1. feat(cli): make doctor reports instance-attributed and machine-readable
- [ ] 2. docs(audit): mark CLI-4 and CLI-6 complete
