# One definition of the creation-command flag grammar

## Problem

`tab new`, `pane split`, and `group new` share a flag grammar. Production
already extracted that grammar once, into `NewCommandFlags` -- but the tests
never followed the refactor, so the shared behavior is still asserted three
times, once per command, in three files. A fourth layer in the CLI parser tests
re-asserts part of it a fourth time through the rendered message.

The tests copy production because production still has a copy of its own.
`CLIParser` maps the shared parse error to a CLI message in three separate
`catch` blocks, one per command. Evidence that the three are redundant rather
than merely similar: the two error cases that differ between them are each
thrown from exactly one place -- position conflict only from `tab new`'s parser,
missing direction only from `pane split`'s. Every other case is byte-identical.
So on every reachable input the three blocks produce the same message for the
same error, and differ only in the usage string they interpolate.

Three copies of the mapping invite three copies of the tests that check it, and
a fourth creation command would add a fourth of each.

## Decision

Delete the shared error type. Each arg parser throws the CLI error already
rendered, so there is nothing left for a caller to map.

The shared grammar renders the four errors it can raise; each command's own
parser renders the errors only it can raise. `CLIParser` calls the parsers and
stops translating. The usage text moves next to the flags it describes, because
the parser now needs it to render, and because today the file that defines a
flag and the file that documents it in usage are different files that can drift.

This is the structure in which the duplication cannot recur: a fourth creation
command has no second error type to introduce and no mapping block to copy. It
also dissolves, rather than works around, the compromise the current error enum
documents -- carrying cases that are unreachable for two of its three callers.

Behavior is unchanged. Every CLI message stays byte-identical, so this is not a
CLI surface change and `integrations/danterm/SKILL.md` does not move.

## Invariants

- **I1.** For every input, the `danterm` CLI reports the same message it reports
  today. Parser errors are external surface.
- **I2.** The shared flag list has one definition in source: one grammar, one
  error rendering, one occurrence of the shared flag text inside the usage
  lines. Adding a creation command cannot introduce a second.
- **I2a.** Each command's whole composed usage line also has one occurrence,
  reachable both by that command's parser, which renders errors with it, and by
  the CLI parser, whose post-parse guards report it. A creation command's usage
  line is never written out a second time to serve the second reader.
- **I3.** `group new` reports no background. Its background is derived from the
  absence of `--foreground`; the background flag exists in its grammar only so
  the focus conflict can be detected. `tab new` and `pane split` do report it.
- **I4.** The three flag families guard differently, on purpose: a repeated
  focus flag is accepted, a repeated position flag conflicts, and a repeated
  direction flag is rejected as an unexpected argument.
- **I5.** The first token a parser cannot accept wins. Errors raised while
  scanning tokens outrank checks that run after the scan.
- **I6.** Shared-grammar behavior is asserted once, against the shared grammar.
  A command's own test file asserts only what is unique to that command --
  including which flags that command does not own.

## Proof obligations

- **PO1** (I1): the existing CLI-level message assertions pass unchanged
  throughout. They are the harness for this refactor, not an output of it.
- **PO2** (I2): one test file exercises the shared grammar directly. The three
  command test files hold no assertion that would still pass if its command's
  own flags were removed.
- **PO3** (I3): `group new` accepts the background flag and leaves no trace of
  it in the parse result.
- **PO4** (I4): each of the three repetition rules is asserted where it lives --
  focus in the shared tests, position and direction in their commands'.
- **PO5** (I5): a malformed command carrying an early bad token and a later
  conflict reports the early token, including when the later check is the
  post-scan one.
- **PO6** (I1, wiring): each command's own usage string reaches its rendered
  message. The existing usage table already discharges this for all three.
- **PO7** (I2, I2a): no usage-line text appears twice in the module. A search
  for repeated usage literals discharges this, and is worth keeping as a check
  rather than a one-time inspection.

## Sequencing

Coverage must not dip mid-change. Write the shared-grammar tests first and
confirm they cover the shared behavior; change production second; delete the
per-command copies last. Not the reverse.

## Non-goals

- Changing any CLI message, flag, or usage text.
- Reworking the shared grammar itself. The production extraction is sound; only
  its error rendering is triplicated.
- Adding the missing flag's name to the missing-value message. It is discarded
  today and stays discarded.

## Accepted risks

- **AR1.** Arg-parser tests move from asserting a typed error case to asserting
  a rendered message. While a missing flag value and a missing split direction
  both render bare usage, a test sees the message but not which of the two
  causes produced it. Nothing observable is unpinned, because nothing observable
  ever told them apart.
- **AR2.** The flag name carried by the missing-value error is dropped at the
  throw site rather than at the render site. A future decision to name the
  missing flag in the message would have to re-plumb it.

## Rejected ideas

- **RI1.** Keep the shared error type and give the three `catch` blocks one
  shared mapping function. Smaller change, and it keeps typed-error assertions.
  Rejected: a fourth command can still forget to route through the function, so
  I2 holds by convention rather than by construction, and the unreachable error
  cases survive.
- **RI2.** Give each command its own error type. Rejected: it reinstates exactly
  the per-caller remapping the current design deliberately avoided.

## Implementation discretion

- **D1.** How the shared-grammar tests reach the shared grammar -- a small test
  driver, or one representative command parser named as the proxy.
- **D2.** How each usage line is composed from the single shared flag text.

## Judgment recorded

"`-h` and `-v` are unknown to this command" reads as a shared property, since
every parser rejects flags it does not own. It stays per-command. The shared
rule is that an unowned token is rejected, and that belongs to the shared tests;
which flags a command owns is command-specific, and these are the assertions
that would catch a direction flag drifting into the shared grammar.

## Implementation notes

- **D1.** The shared-grammar tests reach the grammar through a test-only driver
  that runs `NewCommandFlags.consume` over the whole argument list and nothing
  else. It renders errors with a synthetic usage line, so no assertion there can
  pass by matching a real command's text.
- **D2.** Each command's usage line is one module-scope constant in that
  command's parser file, interpolating `newCommandFlagsUsage`. `CLIParser` reads
  those constants for its post-parse guards, so no command's line is written
  twice.
- `newCommandFlagValue(after:in:at:)` became `NewCommandFlags.value(in:at:)`. The
  missing-value message is now the bare usage line, so the shared reader needs
  the command's usage line rather than the flag's name, and the instance already
  holds it. This is where AR2 lands: the flag name is dropped at the throw site.
- **PO7** is discharged by `scripts/creation-usage-single-source-lint.sh` plus its
  self-test, both wired into `scripts/run-test-suite.sh`. It is scoped to the
  three creation commands, because other commands in the module do still repeat
  their own usage text (see Follow Up).

## Follow Up

- Three non-creation usage lines are still written twice inside
  `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift`: `usage: danterm
  agent <attach|activity|detach>`, `usage: danterm pane input --pane <pane-id>
  [--literal] -- <token>...`, and `usage: danterm theme set --pane <pane-id>
  <name>|--clear`. Hoisting each to one constant would let
  `scripts/creation-usage-single-source-lint.sh` drop its creation-command filter
  and gate the whole module.
