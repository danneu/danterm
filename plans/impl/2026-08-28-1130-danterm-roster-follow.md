# Plan: `danterm roster [--follow]` (CLI-8)

## 1. Problem and evidence

The app serves a push pane roster: `IpcRequest.roster` subscribes the
connection, replies with the current roster, and sends every later roster as a
`roster.event` notification until the connection ends
(`lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift:33-37`). The
iOS client already consumes it (`92971468`). The CLI has no verb for it:
`CLIParserRoute` and `CLICommandCatalog.entries` have no roster case, and
`integrations/danterm/SKILL.md` only documents `ls`. A shell agent that wants
to notice a pane appearing, renaming, closing, or changing its chip can only
poll `ls`, which re-serializes every split tree per poll and misses any
transition that begins and ends between polls.

Desired outcome: the shell client can ask for everything the app can push.
Source: `docs/scratch/2026-08-26-improvement-audit.md`, CLI-8.

## 2. Decision

Add `danterm roster [--follow]` as a catalog command with two output forms,
selected by `--follow`:

- Default form, `.json`: the ordinary bounded single-reply execution path.
  Send `roster`, print the reply result as one JSON line, exit 0. Closing the
  connection ends the subscription; nothing else is needed. RPC error and
  missing-reply handling are the existing path's.
- `--follow` form, `.recordStream`: a dedicated stream renderer over a
  connection with no receive timeout, as `pane tape --follow` already uses
  (`cli/main.swift:188-211`). Print the reply result as one line, then one
  line per `roster.event` notification's params until the app closes the
  connection.
- Each line is the received `JSONValue` (reply result or notification params,
  unwrapped from the JSON-RPC envelope) re-encoded compactly, never projected
  through `PaneRoster`. The shape is therefore the wire `PaneRoster` encoding
  (`{panes: [{groupId, groupName, tabId, tabTitle, paneId, paneTitle, chip,
  isSelectedTab, isFocused}]}`).
- `roster` takes no target; the catalog's target policy already derives from
  the route's methods (`09555fe4`).
- `SKILL.md` changes in the same commit: the "what tabs/panes are open?" row
  points to `roster` for a flat list and live changes and `ls` for tree
  structure; the `DANTERM_SOCKET_TIMEOUT` section says `roster --follow`, like
  a tape capture, carries no receive timeout, while one-shot `roster` remains
  bounded.

Why this shape: it removes the only capability the app has that the CLI cannot
ask for, and it is the flat pane list agents recurse `ls` to build. Two forms
keep `CLIOutputKind` accurate and leave one new stream path.

Constraint: the follow renderer does not route through `renderPaneTapeStream`
(`cli/PaneTapeStream.swift:68-107`), which requires a tape `start` reply and
derives its EOF policy from a capture mode. It shares that file's
EINTR/EPIPE-safe unbuffered fd line-writer.

## 3. Invariants

- I1. Every line written by `roster` is a complete roster in the wire
  encoding; a line is flushed to stdout before the next notification is read.
- I2. `roster` without `--follow` exits 0 after exactly one line.
- I3. `roster --follow` exits 0 at connection EOF only after the initial
  roster line was written; EOF before the reply fails with the existing
  "DanTerm closed the connection" error and writes nothing. A closed stdout
  (EPIPE) ends the stream cleanly with exit 0, as for `pane tape`.
- I4. An RPC error reply fails the command with the server's message and
  writes no roster line, in both forms.
- I5. Catalog, `--help`, and `SKILL.md` all list `roster` with both output
  forms.

## 4. Proof obligations

- PO1 (I1-I4): `cli-tests` against the fake-server fixtures used by
  `cli-tests/PaneTapeStreamTests.swift` -- one-shot prints the reply and
  returns; follow prints one line per `roster.event` as each arrives and exits
  0 at EOF after the reply; EOF before the reply fails with no output; error
  reply fails with no output; closing the output pipe mid-follow terminates
  cleanly.
- PO2 (I1-I3, end to end): `scripts/tests/danterm-cli_test.sh` -- start
  `roster --follow` into a file, run `pane split`, assert a new line naming
  the new pane id arrives without polling; also assert the one-shot form lists
  the existing pane.
- PO3 (I5): `cli-tests/UsageTextTests.swift` and
  `lib/DanTermProtocol/Tests/DanTermProtocolTests/CLISkillGeneratedRegionsTests.swift`
  cover the new entry's synopsis and stdout regions.

## 5. Non-goals / Rejected ideas

- Non-goal: changing `ls`; it stays the tree-shaped view.
- Non-goal: filtering or formatting options on `roster`; consumers use `jq`.
- Rejected: documenting an `ls`-polling recipe in `SKILL.md` instead -- keeps
  the missed-transition hole.

## 6. Implementation discretion

- Whether the shared fd line-writer moves to its own file or stays in
  `cli/PaneTapeStream.swift` under a general name.

## Commit progress

- [x] 1. feat(cli): expose pane roster snapshots and live updates

## Implementation notes

- The plan's I5 needs a `roster` row in the generated stdout-shapes table, and the
  projection that builds that table named its per-form spelling by special-casing
  `doctor` and `pane tape` by route. Its generic fallback (`"<synopsis> [<variant>]"`)
  was already reached by no entry, and `roster [--follow] [follow]` is not a command
  anyone can type. Rather than add a third route special case, `CLIOutputForm` now
  carries `selectedBy`: the command line that selects that form. The projection reads
  it and knows no route names. Every existing row is byte-identical.
- `roster --follow` picks its renderer in the execution boundary by wire method, not by
  output variant: `.recordStream` now has two renderers, and the variant that selects a
  `pane tape` format cannot also name a stream.
- Both scripted-endpoint fixtures in `cli-tests/CLICharacterizationTests.swift` parked
  their acceptor on a global-queue worker and blocked it inside `accept()` for the life
  of the case. Adding this plan's three cases pushed the suite past what a
  non-overcommit root queue hands out, and every scripted case in the file then timed
  out at its hang guard. They now use the `runOnItsOwnThread` helper this repository
  already documents for exactly this, and the suite runs in 0.27s.
- The descriptor and session fixtures moved out of `PaneTapeStreamTests.swift` into
  `cli-tests/StreamFixtures.swift` so the roster suite reads through the same real
  socket and pipe rather than copying them. `StreamCompletionProbe` became generic over
  the outcome it carries.
- Section 6 discretion: the fd line writer moved to its own file, `cli/JsonLineOutput.swift`,
  with its own failure type. Each stream renderer words a write failure as its own.

## Follow Up

- `docs/scratch/2026-08-26-improvement-audit.md` still lists CLI-8 as open. Ticking it
  belongs with the audit's own bookkeeping commit, not this one.
- `scripts/docs-lint.py` and `scripts/tests/docs_lint_test.py` fail at HEAD, before this
  change: `docs/research/39-kitten-render-benchmark/decisions.md` cites `tools/tty`,
  `tools/cmd/benchmark`, and `tools/cmd/benchmark/main.go`, none of which exist. This
  blocks `just lint` and `just test-tooling` for everyone.
- `TerminalPTYHostTests` "tty transitions start new canonical verdict epochs" exceeded
  its 60s limit under a loaded gate run and passed alone. If it recurs, its deadline
  wants the treatment in `agent-docs/test-timing.md`.
