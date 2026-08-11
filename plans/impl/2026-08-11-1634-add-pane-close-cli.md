# Add `danterm pane close` to the CLI

## Problem

`danterm pane split` creates panes over IPC, but nothing removes them. The
pane subcommands are `focus`, `info`, `split`, `input`, `read`, `rows`,
`zoom`, `tape`; `close` exists only under `tab`. AGENTS.md states DanTerm aims
to be fully controllable remotely and programmatically, and this is a plain
gap in that surface: an agent can build a pane layout it cannot take down.

The only workaround today is `pane input --pane <id> -- "exit" Enter`, which
is keystroke simulation standing in for a state transition. It works only when
the pane sits at a shell prompt with no foreground job and no confirmation,
and silently does the wrong thing otherwise.

The hard part is already built. `.closePane(paneId:)` exists in the core with
coverage for sibling promotion, last-pane-in-tab cascade, and side-table
cleanup (`lib/DanTermCore/Sources/DanTermCore/Update.swift`,
`lib/DanTermCore/Tests/DanTermCoreTests/UpdatePaneTests.swift`). No IPC method
dispatches it. This change is the missing CLI and IPC surface over an existing
model operation, not new close semantics.

## Decision

Add a `pane.close` IPC method and a `danterm pane close --pane <pane-id>` CLI
command that resolves the pane and dispatches the existing `.closePane` Msg.

Two load-bearing premises, both verified in the current source:

- `.closePane` reaches `emitTerminateConfirmation` when the pane is the last
  pane of the last tab. That sets `pendingConfirmation` and returns no
  commands, so the pane stays open while the request would report success.
  `tab close` already guards this shape by refusing outright rather than
  dispatching; `pane close` needs the analogous pre-check.
- The GUI closes panes through `.requestClosePane`, which prompts on
  uncompleted todos. The CLI must dispatch `.closePane` directly, as `tab
  close` bypasses its own confirmation.

Scope also includes correcting the `pane` subcommand usage string, which is
already stale (it omits `rows` and `zoom`) and is user-visible on a parse
error.

The method resolves its target through the shared explicit-target resolution
the other IPC methods use, rather than growing its own lookup path.

Critical files: the protocol package's method list and CLI parser, the core's
IPC dispatch, the CLI executable's help text, and
`integrations/danterm/SKILL.md`.

## Invariants

- **I1** `--pane <pane-id>` is required, at both the CLI parser and the IPC
  method. There is no fallback to the calling pane, so the command can never
  close a pane the caller did not name.
- **I2** Closing a pane that has siblings leaves its tab open with the sibling
  promoted, matching what Close Pane does in the GUI.
- **I3** Closing a tab's only pane closes that tab, matching the GUI.
- **I4** Closing the only pane of the only tab is refused with an error. The
  pane and tab survive, DanTerm keeps running, and no confirmation state is
  left pending.
- **I5** No close through this path raises a confirmation sheet, including
  when the pane or its tab has uncompleted todos.
- **I6** An unknown, malformed, or missing pane id is an error that closes
  nothing.
- **I7** Success prints nothing and exits zero; every refusal above exits
  non-zero with a message on stderr.
- **I8** Every successful request replies `{"pane": {"id": "<closed-id>"}}`,
  mirroring `tab.close`. Direct IPC clients get the closed id; the CLI
  discards it and stays silent per I7.

## Proof obligations

- **PO1** (I1) Parser rejects `pane close` with no `--pane` and with an empty
  `--pane` value; the IPC method rejects a request carrying a caller pane
  context but no explicit pane param.
- **PO2** (I2) Closing one pane of a multi-pane tab: the tab survives, the
  sibling is present and focused.
- **PO3** (I3) Closing the sole pane of a tab, with another tab present: the
  tab is gone and the tab count drops by one.
- **PO4** (I4) Closing the sole pane of the sole tab: error reply, pane still
  present, `pendingConfirmation` still nil, no terminate command emitted.
- **PO5** (I5) Closing a pane whose tab and pane both carry uncompleted todos
  emits no close-pane and no close-tab confirmation effect.
- **PO6** (I6) Malformed id, unknown-but-well-formed id, and a non-string
  pane param each produce an invalid-params error and mutate nothing.
- **PO7** (I7) End-to-end against a live slot, covering both process-level
  outcomes: a successful close by id exits zero with empty stdout and `ls`
  confirms the pane is gone and its tab remains; one representative refusal
  exits non-zero with empty stdout and its message on stderr.
- **PO8** (I8) A successful close replies with the closed pane's id.

PO1 and PO6 belong with the existing parser and IPC-dispatch suites
(`CLIParserTests.swift`, `UpdateIpcTests.swift`). PO7 belongs in
`scripts/tests/danterm-cli_test.sh`, which already launches a slot and creates
a split pane it can reuse. That script also greps the usage and help text for
exact command lines, so the new command's help entry and those assertions have
to agree.

## Non-goals

- No self-close: the caller's `$DANTERM_PANE` is never an implicit target.
- The CLI never quits DanTerm as a side effect, matching `tab close`.
- No `--force` flag to override the last-pane-of-last-tab refusal.
- No change to how the GUI closes panes; `.requestClosePane` and its todo
  confirmations are untouched.

## Accepted risks

- **AR1** Closing a tab's only pane destroys that tab's todos with no prompt,
  because the CLI bypasses the confirmation the GUI shows. This is the same
  trade already accepted for `tab close`, and the caller passed an explicit id.

## Implementation discretion

- Where the last-pane-of-last-tab check sits within the IPC case, as long as it
  runs before `.closePane` is dispatched.

## Verification

`just test` for the parser and core suites, and `just test-cli` for PO7 (that
smoke test needs GUI access and is outside `run-test-suite.sh`). Confirm
the live behavior against an isolated slot via `just launch-slot`, driving it
with an explicit `danterm --socket` argument.
