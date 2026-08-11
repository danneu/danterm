# Require explicit targets on every IPC command

## Problem

The CLI is agent-only. No human types `danterm` inside a pane. Yet 18 of the
23 targeting IPC methods treat a missing `--pane` / `--tab` / `--group` as
"use the caller's pane", resolved from `$DANTERM_PANE` carried in the request
envelope as `params._ctx`.

That makes an omitted flag a different action instead of an error. The shell
here is fish, where an unset variable used unquoted removes the argument
outright:

    danterm pane input --pane $PANE_ID -- C-c   # unset -> the flag vanishes
    danterm pane input -- C-c                   # ...and Ctrl-C hits the agent's own shell

The same substitution happens on a dropped env var, a subshell, or a recipe
copied without its flag. The five methods that already require an explicit id
(`pane close`, `pane focus`, `pane read`, `pane rows`, `pane tape`) show the
intended contract; the recent `pane close` work stated it directly ("no
fallback to the calling pane, so the command can never close a pane the caller
did not name"). Everywhere else the rule exists only as prose in
`integrations/danterm/SKILL.md`, which spends a whole section telling agents to
override the default the code hands them.

There is a second implicit channel: `tab new` with no `--cwd` inherits the
caller pane's live shell cwd, and if that is deleted naively `.createTab` falls
through to a focused-pane lookup -- strictly more ambient than what was
removed.

Outcome: the daemon never infers a target or a working directory from who
called or from what has focus. Everything the request acts on is named in the
request.

## Decision

Make the target a required part of every targeting command, then make that a
property the compiler enforces rather than a runtime check.

Explicitness is sourced, not abolished. `DANTERM_PANE` stays as the env var an
agent reads; it just has to be named at the call site as `--pane
"$DANTERM_PANE"` -- the rule already argued for `--socket` in SKILL.md ("the
target should remain visible at each call site"), applied to the other three
target kinds. Human ergonomics, if ever wanted, belong in a user-owned shell
wrapper, not in the protocol.

Three structural consequences:

- **The envelope loses caller identity.** `IpcRequestContext` and the `_ctx`
  params key are deleted end to end -- CLI construction, wire shape, `Msg`
  payload, and both readers. A fallback that no longer has an input cannot be
  reintroduced by accident.
- **The GUI's focus-relative operations become inexpressible from IPC.**
  `createTab` and `splitPane` currently take an optional target whose `nil`
  means "use the selection". Each splits into an explicit-target case and a
  separate focused/selected case, so the IPC branch cannot construct the
  ambient one. This is what keeps the property alive through future edits.
- **`tab new` gets its cwd from the caller's process.** The CLI fills
  `launch.cwd` from its own working directory when `--cwd` is absent, so the
  value travels visibly in the params and the daemon never consults focus. A
  direct IPC request with no cwd gets the home directory. `pane split` keeps
  inheriting cwd, theme, and font size from its *resolved target* pane -- that
  target is explicit, so it is not an ambient channel.

Backwards compatibility is not a constraint: the wire format breaks, and the
app is replaced wholesale.

Delivered in two commits. The first removes the behavior; the second removes
the possibility. Commit 1 carries most of the value but leaves "a new method
forgets to resolve its target" defended only by a test somebody must remember
to extend. Commit 2 moves that to the compiler by routing every method through
one exhaustive catalog of decoded requests -- adding a method means adding a
case, and a case declared as targeting cannot be written without its target.
What the catalog cannot do is decide that declaration for a method nobody has
written yet. The catalog is
shared by the CLI and the daemon, which also collapses their two independent
transcriptions of each method's params into one definition; that is the larger
practical win. Scattered per-method structs would not deliver either property,
since a method could still hand-roll its params outside them.

Critical files: `lib/DanTermCore/Sources/DanTermCore/Update.swift` (dispatch and
the shared resolver), `lib/DanTermCore/Sources/DanTermCore/Msg.swift`,
`lib/DanTermProtocol/Sources/DanTermProtocol/` (CLI parser, per-command arg
structs, `IpcRequestContext.swift`), `app/IpcServer.swift`, `cli/main.swift`,
the two `integrations/*/danterm-agent-session.sh` hooks, and
`integrations/danterm/SKILL.md`.

## Invariants

- **I1** Every targeting IPC method requires its target id in the request. An
  absent target is an error that mutates nothing. No method derives a target
  from the caller, the selected tab, or the focused pane.
- **I2** The request envelope carries no caller identity. A request is fully
  described by its method and params.
- **I3** The IPC dispatch path cannot express a focus-relative create or split.
  The GUI keeps its focus-relative behavior through separate operations.
- **I4** A tab created over IPC never inherits a working directory from the
  focused or most-recently-used pane. Through the CLI it gets the caller
  process's directory unless `--cwd` says otherwise; a direct IPC request with
  no cwd gets the home directory.
- **I5** Every targeting CLI subcommand rejects a missing or malformed target
  with a usage error, before any request is sent. `tab new` requires exactly
  one of `--group` or `--after-tab`: neither and both are usage errors, and the
  daemon's consistency check between the two goes away with the case that
  needed it.
- **I6** `agent attach`, `agent activity`, and `agent detach` take an explicit
  `--pane`; the shipped agent hooks pass `$DANTERM_PANE`. A hook with no
  `DANTERM_PANE` stays the silent no-op it is today.
- **I7** Target errors use one vocabulary across pane, tab, and group:
  absent, not a string, and unknown are three distinct messages, all invalid
  params. With I5 in force, a target reaching the daemon from the CLI can only
  fail as unknown; the other two shapes remain reachable by direct IPC clients.
- **I8** (commit 2) Every IPC method is a case of one exhaustive catalog of
  decoded requests, shared by the CLI that builds them and the daemon that
  consumes them. No method is dispatched from raw params, so a case cannot opt
  out of the catalog's declaration. Every case declared as targeting carries
  its target as a non-optional phantom-typed id, which a dispatch cannot obtain
  from anywhere else.

## Proof obligations

- **PO1** (I1) One table over every targeting method: with the target key
  removed from otherwise-valid params, the reply is an invalid-params error and
  no command is emitted. Its method enumeration is hand-maintained in commit 1
  and derived from the I8 catalog in commit 2, so a method added after that
  cannot silently escape it.
- **PO2** (I1, I3) An explicit target is honored regardless of what is selected
  or focused. The existing per-method tests that pin this survive; only their
  context argument goes.
- **PO3** (I4) Three parts, since the contract spans both sides of the wire.
  CLI: `tab new` with no `--cwd` emits a request whose params carry the caller
  process's directory, and with `--cwd` carries that value unchanged. Daemon: a
  `tab new` request with no cwd creates a session at exactly the injected home
  directory. Together, with the focused pane's cwd set to a distinct sentinel
  that neither answer can coincide with.
- **PO4** (I5) Per subcommand, omission of the target is a parse error with the
  documented usage string. `tab new` rejects both neither-anchor-given and
  both-anchors-given. A malformed target id is a parse error, proved once per
  target kind.
- **PO5** (I6) The hook tests assert the `--pane`-bearing command lines, and
  the missing-`DANTERM_PANE` no-op cases still pass.
- **PO6** (I7) All three entities against all three failure shapes.
- **PO7** (I2) A request the CLI generates with `DANTERM_PANE` set carries no
  caller-identity field on the wire, proved against the serialized request
  rather than against the model the daemon reaches.
- **PO10** (I1) The golden-master snapshot is byte-identical once the recorded
  requests name their targets. A snapshot change means something other than
  target sourcing moved, and must be explained before re-recording.
- **PO8** (I8) Per method, the params the CLI produces decode back into the
  expected catalog case -- the test the two-transcription duplication made
  impossible.
- **PO9** End to end against an isolated slot: a command with an explicit
  target acts on it while a different tab is selected; the same command with
  the flag omitted exits non-zero and changes nothing.

## Non-goals

- No `--pane self` or similar sugar. A second spelling for "me" reintroduces
  the thing being deleted.
- No change to GUI behavior. Menu items and key bindings stay focus-relative.
- `DANTERM_PANE` is not removed; it is the value agents pass.
- No change to `pane split` inheriting cwd, theme, and font size from its
  resolved target pane.

## Accepted risks

- **AR1** The focused-pane cwd lookup reached by `.createTab` survives for GUI
  callers. I4 keeps the IPC path from reaching it by always supplying a cwd,
  rather than by restructuring that operation's cwd decision.
- **AR2** Between the two commits, I1 is defended by PO1's hand-maintained
  table rather than by the type system, so a method added in that window can
  forget its target and pass. It cannot resolve one ambiently either way: I2
  and I3 remove the inputs in commit 1.
- **AR3** A method added later can be declared untargeted when it is not, and
  the catalog will accept it. Classification is a review question; the value of
  I8 is that the declaration exists, is explicit, and cannot be sidestepped by
  dispatching from raw params.

## Rejected ideas

- **RI1** Sourcing `tab new`'s cwd from the target group's selected tab. That
  is focus by another name.
- **RI2** Keeping the envelope's caller pane alive solely to supply cwd. It
  leaves "implicit caller pane" in the protocol to serve one field.
- **RI4** A capability boundary that denies untargeted requests any pane, tab,
  or group mutation, to force future methods to classify themselves correctly.
  It builds a permission system to defend a judgment call that a reviewer
  reading a 25-case catalog makes for free.
- **RI3** Flipping the existing per-command policy flag to require-explicit
  without deleting the fallback machinery. It leaves the mechanism, the
  envelope field, and the per-method policy question all in place.

## Implementation discretion

- Whether PO1 and PO6 are parameterized tables or unrolled cases.

## Verification

`just test` for the parser, core, and protocol suites. `just test-cli` for the
CLI smoke test and the hook tests. PO9 against `just launch-slot` driven with an
explicit `danterm --socket`, checked with a second tab selected so a regression
to focus-based targeting is visible.

## Commit progress

- [x] **1. Required explicit targets.** Delete the caller-pane fallback,
  `IpcRequestContext`, and `_ctx`; require the target at every CLI subcommand
  and IPC method; add `--pane` to the agent commands and pass it from the
  hooks; split the focus-relative create and split operations from their
  explicit-target forms; source `tab new`'s cwd per I4; unify the error
  vocabulary; rewrite SKILL.md's targeting section and the CLI usage text.
  Covers I1-I7, PO1-PO7, PO9. Tests first.
- [ ] **2. One exhaustive request catalog.** Move the phantom id types to the
  protocol module so the CLI and the daemon share them, replace raw-params
  dispatch with one catalog of decoded requests covering every method, and map
  decode failures to the I7 vocabulary. The catalog lands whole -- a
  half-converted dispatch leaves I8 false. Existence checks stay in the core:
  the type proves a target was supplied, not that it resolves. Covers I8, PO8,
  and re-derives PO1's enumeration.
