# One spelling for todo text, one spelling for the todo and ok wire objects

Audit items CLI-3 and IPC-5 of `docs/scratch/2026-08-26-improvement-audit.md`
(Wave 11, "make the IPC and CLI contracts enforce themselves"). CLI-3 owns it.

## Problem

The rule "todo text is non-blank after trimming" is enforced five times, four
different ways:

- `CLIParser.swift#parseTodoAddCommand` checks untrimmed `isEmpty`, so
  `"  "` passes parse and fails later at dispatch; `parseTodoEditCommand`
  checks arity only.
- The wire `todo.add` decoder (`IpcRequest.swift`) accepts any string; the
  `todo.edit` decoder rejects blank text but with the message `"invalid todo"`,
  the same message as a bad id.
- `ModelOperations.swift#appendTodo` and `Update.swift#.editTodoText` re-trim
  and silently no-op on blank; the AppKit todo popovers rely on that no-op.
- `TodoItem.text` is a bare `String`, so a persisted snapshot can load a blank
  todo (`Model.swift` snapshot restore).

Separately, two wire objects have two producers each: the todo object is
written in `IpcDispatch.swift#todoJSON` and `IpcEntityEncoder.swift#todo`
(byte-identical today, nothing tests that), and the `{"ok": true}` reply is
`okResult()` at five sites and an open-coded literal at four
(`IpcDispatch.swift` agent arms, `Update.swift` `.inputSubmissionCompleted`).

The audit's headline symptom -- `danterm todo edit ... "  "` exits 0 -- is
stale: the wire decoder has refused it since `139a4dc1`. The structural
duplication is what remains.

## Decision

Make todo text a validated value type in `DanTermProtocol`: constructible only
from text that is non-blank after trimming, and stored trimmed. Every carrier
of todo text uses it: the CLI command, the IPC request (both directions of the
wire), the `Msg` cases, and `TodoItem` itself. Blank text therefore fails at
the earliest boundary it reaches and the reducer's and `appendTodo`'s blank
guards are deleted, not kept as belt-and-braces.

Then land IPC-5 on top: `IpcEntityEncoder` is the sole producer of the todo
wire object and `okResult()` the sole producer of the acknowledgement object.

Backwards compatibility is not a constraint (AGENTS.md). Usage lines, exit
codes, and JSON shapes are unchanged, but blank `todo add` text moves from a
daemon error (`"invalid todo text"`) to a parser usage error, which is a
CLI-surface change: `integrations/danterm/SKILL.md`'s `### Todos` section
states in the same change that `add`/`edit` text must be non-blank after
trimming whitespace and newlines, and that blank text is refused at parse.

## Invariants

- I1. No `TodoItem`, `Msg`, `IpcRequest`, or `CLICommand` can carry blank
  todo text; the type makes it unrepresentable.
- I2. `danterm todo add` and `danterm todo edit` with blank text fail at
  parse with the command's usage line, before any socket traffic.
- I3. A wire `todo.add` or `todo.edit` request with blank text is refused at
  decode, with one message for both verbs, distinct from the bad-id message.
- I4. Stored todo text is trimmed of leading and trailing whitespace and
  newlines (`.whitespacesAndNewlines`, the popover's existing rule; the
  reducer's `.whitespaces` is the one that changes), and "blank" means empty
  after that trim. The popovers still treat a blank entry as "no change" (no
  `Msg` sent).
- I5. A persisted snapshot row with blank text is dropped on load, the way
  other unreadable todo rows already are; the rest of the snapshot loads.
- I6. `danterm ls` and `danterm todo list` report a given todo with the same
  object, and every acknowledgement reply is the same object -- each has one
  producer in the tree.

## Proof obligations

- PO1 (I1, I4). Protocol tests: constructing the value from `""`, `"  "`,
  `"\t"`, and `"\n"` fails; from `" \nx \n"` yields `"x"`.
- PO2 (I2). `CLIParserTests`: `todo add` and `todo edit` with blank text
  (space-only and newline-only) throw `CLIParseError`; with real text they
  parse as today (existing test at `CLIParserTests.swift:549` stays green).
- PO3 (I3). Protocol decode tests: space-only and newline-only `todo.add` and
  `todo.edit` wire requests all throw, with an identical message; a
  `todo.edit` with a bad id throws a different one.
- PO4 (I5). Core snapshot test: a snapshot where a tab and a pane each hold one
  blank and one valid todo restores exactly the valid row for each owner
  (tab and pane restore are separate code paths).
- PO5 (I6). `UpdateIpcTests`: the todo object inside the `ls` reply for a pane
  equals the object `todo.list` returns for it; every existing `ok`-asserting
  test stays green.
- Existing `UpdateTodoTests` blank-rejection tests (`:169`, `:240`) are
  rewritten against the value type rather than the reducer, since the reducer
  can no longer receive blank text.

## Non-goals

- Changing `todo edit`'s output mode (`.none` today). The audit's Correction
  notes the verb prints nothing on success; that is a separate CLI decision.
- Any other validated-text type (group names, tab titles) -- same pattern,
  separate item.

## Implementation discretion

- Where the value type lives inside `DanTermProtocol` and its `Codable`
  strategy, provided I1 holds for decoded values too.
- Whether the blank-snapshot drop reuses the existing lossy per-row decoder
  (`Model.swift#decodeLossyTodoSnapshotsIfPresent`) or the restore step.

## Verification

- `swift test --package-path lib/DanTermProtocol` and
  `swift test --package-path lib/DanTermCore --filter Todo` in the loop;
  `just test` before commit.
- Live: `just launch-slot`, then `danterm todo add --pane <p> "  "` and
  `danterm todo edit --pane <p> <id> "  "` exit non-zero with usage;
  `danterm todo add --pane <p> " x "` stores `x`; `danterm ls` and
  `danterm todo list --pane <p>` agree on the todo object. `just stop-slot`.
- On landing: tick CLI-3 and IPC-5 in the audit's `## Plan of work` with the
  commit hash.

## Commit progress

- [x] 1. fix(todo): make todo text valid by construction
- [ ] 2. refactor(ipc): centralize todo and acknowledgement wire objects
- [ ] 3. docs(audit): record the CLI-3 and IPC-5 landing commits
