# Level-triggered connection declaration

## Context

A pane stays stuck in remote state -- the remote theme plus the globe toolbar
accessory -- after an `ssh` that never connected is interrupted. The connection
is opened by an edge event and closed by a matching one, and the closing edge is
emitted from the body of the `ssh` wrapper function after `ssh` returns. SIGINT
abandons the rest of a shell function body, so that emit never happens while the
opening one has already latched the pane into `.remote`. Nothing else clears it,
so the pane is wrong until it dies.

Reproduced headlessly, real shells in a real PTY:

| stimulus | events emitted |
|---|---|
| `ssh <unreachable>`, then Ctrl-C | `command-start`, `remote-start`, `command-end;130` |
| `ssh <unreachable>`, left to time out | `command-start`, `remote-start`, `connection-end`, `command-end;255` |

zsh behaves the same; bash loses the close for the same reason. The lost close is
not specific to Ctrl-C -- any signal that unwinds the function, and any path that
strands shell-local state (the wrapper running in a pipeline or subshell), leaves
the same stale pane.

The desired outcome: no shell mishap can leave a pane claiming a connection it
does not have, and a pane still shows remote as soon as `ssh` starts, including
for hosts that have no DanTerm integration installed.

## Decision

Replace the edge-triggered trio `remote-start` / `remote-host` / `connection-end`
with one **level-triggered declaration**: an event that states the shell's whole
connection state rather than a transition into or out of it.

- Every shell declares its complete connection state **at every prompt**,
  unconditionally: local shells declare local, and a shell that is itself remote
  (`LC_DANTERM` present, `DANTERM` absent) declares remote with its identity --
  which it already does today, once per prompt, via `remote-host`.
- The `ssh`/`mosh` wrappers emit only the opening declaration (remote, identity
  unknown) before launching. They close nothing, keep no flag, and no longer
  re-report an enclosing identity.
- The engine event and the core `SessionReport` collapse to one case carrying the
  declared state; the reducer becomes a plain assignment, and the rule that stops
  a bare `remote-start` from clobbering a known identity disappears with it.

Why this is the ideal rather than a repair of the pairing: it deletes the failure
class instead of the instance. The close now rides the same prompt hook that
already delivers `command-end` reliably -- verified in all three shells, after
Ctrl-C -- and there is no shell-local flag for a subshell or a signal to strand.
Nesting stops being choreography: each shell declares its own state at its own
prompt, so returning from an inner `ssh` restores the enclosing identity because
the enclosing shell says so, not because a wrapper remembered to re-announce it.
The wrapper's optimistic declaration is kept, so a host without the integration
still reads as remote, and a wrong guess now expires at the next prompt.

The envelope version moves to `DanTermShell=3`. The vocabulary is incompatible,
remote hosts carry copies of the integration that update on their own schedule,
and the version is what makes a stale remote's events ignored outright instead of
half-understood.

Wire form: one `connection` event whose first argument is the state token, with
the identity pair present only for a remote declaration. Field counts stay
exactly checkable, which is the existing parser's contract for every event.

## Invariants

- **I1.** A shell's prompt declares its complete connection state. A pane's
  connection state is therefore never stale past the next prompt of the shell
  that owns it.
- **I2.** An interrupted, failed, or killed connection command leaves the pane
  local as soon as its shell prompts again.
- **I3.** A connection is declared, never paired. A missing edge cannot leave
  connection state stale past the owning shell's next prompt, and no declaration
  depends on shell state surviving a subshell, a pipeline, or a signal.
- **I4.** Returning from a nested connection restores the enclosing identity,
  with no stack in the model and no re-announcement by the wrapper.
- **I5.** A connection command declares remote before it launches, so a host with
  no far-side integration reads as remote for the life of that command.
- **I6.** A declaration that matches the pane's current state leaves the model
  unchanged, and a prompt cycle costs no reconcile sweep beyond the one its
  command events already schedule. A connection declaration is reconcile-coalescing:
  it drives only chrome (the pane theme and the globe accessory), so it rides the
  throttled sweep instead of forcing an inline one.
- **I7.** A wrapper still preserves its command's exit status exactly, and still
  forwards `LC_DANTERM=1` ahead of a caller's own `SendEnv` options.

## Proof obligations

Behavioral, structure-insensitive tests, one per claim:

- I1/I2: an interactive real-PTY test -- a shell with the integration loaded, a
  connection command interrupted mid-flight, and the pane observed local once the
  shell prompts. This is the reported bug; it must fail against today's code for
  today's reason. zsh and bash belong in the standard gate; fish where the gate
  has it.
- I3: cross-shell byte-exact protocol equality for the new vocabulary, extended
  to cover the wrapper running where shell-local state would not survive.
- I4: nested-connection coverage on both sides -- the reducer, from declarations
  alone, and end to end through a real ssh to a shell that declares its own
  identity.
- I5: a wrapper against a fake `ssh` still declares remote before launch.
- I6: a repeated identical declaration leaves the session model unchanged, and a
  `command-end` followed by a connection declaration in one burst resolves to a
  single scheduled sweep the declaration coalesces into -- asserted through the
  reconcile decision, not through `update`'s return value alone, since a message
  that emits no commands can still force an inline sweep.
- I7: the existing exit-status and `SendEnv` assertions, retained.
- Parser: accept table for each declaration form, reject table for wrong field
  counts, wrong state token, identity attached to a local declaration, and
  non-canonical base64. The reject table also covers `DanTermShell=2` envelopes,
  including every retired connection event, so a stale remote integration is
  ignored outright rather than half-understood.

## Non-goals

- Persisting connection state across a restore. It is not persisted today, and a
  restored pane declaring itself at its first prompt is the correct behavior.
- Detecting remoteness without shell cooperation (inspecting the pane's
  foreground process). It cannot see through a nested connection -- the local
  foreground process is the outer `ssh` the whole time -- so it would be a second
  mechanism that answers a strictly weaker question.
- Any compatibility shim for the old vocabulary.

## Rejected ideas

- **Move the close into the prompt hook, keeping the trio.** Fixes the reported
  Ctrl-C case but keeps edge pairing, keeps a shell-local flag a pipeline or
  subshell can strand, and keeps the nested re-announcement choreography. It
  repairs the instance and leaves the class.
- **Make the reconcile decision change-aware by plumbing "the model changed" out
  of `update`.** Would suppress the sweep for an identical declaration, but
  `update` returns only commands today, so it means changing that signature and
  every call site to fix a cost that classifying the declaration as coalescing
  already removes.
- **Drop the opening declaration and let only the far side declare remote.**
  Removes the wrong guess for a failed connection, but silently drops remote
  indication for every host without the integration installed.

## Surfaces

Four surfaces change, in this order of dependence: the three shell integrations
that emit the declaration, the engine's shell-event parser and semantic event
vocabulary, the core reducer with its admission bound and reconcile
classification, and the app's translation from engine event to core report.

`ConnectionLifecycle` itself is unchanged, so the pane theme, the toolbar
projection, and the `connection` IPC shape carry through untouched.

Durable contract documents that must change with it: `docs/terminal-capabilities.md`
(field-count and bracketing contract) and requirements I7 and I9 in
`docs/design/2026-08-06-swift-terminal-engine.md` (event vocabulary and wrapper
behavior). A host with an older copy of the integration goes back to identity-less
remote until the copy is refreshed; the remote-install instructions should say so.

## Verification

- `just test` -- includes the shell-integration protocol suite and the new
  interactive PTY regression.
- `just test-terminal-workflows` -- the real-sshd end-to-end, extended with an
  interrupted connection.
- Manual: `just launch-slot`, `ssh` an unreachable host, Ctrl-C, and confirm the
  theme and globe revert at the next prompt; `danterm pane inspect` reports the
  connection as local.

## Commit progress

- [x] Level-triggered `connection` declaration end to end: shells, envelope
      version, parser, core, app, IPC shape, updated and new tests including the
      interactive PTY regression, and the contract docs.
- [ ] Interrupted-connection coverage in the opt-in real-sshd workflow runner.
