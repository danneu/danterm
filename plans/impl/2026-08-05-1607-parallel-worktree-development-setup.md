# Finish the parallel-worktree development setup

## Problem and context

Concurrent dev instances landed (`plans/impl/2026-08-01-1526-concurrent-dev-instances.md`):
slot identities, race-safe socket ownership, per-identity state, and a launcher
that claims a kernel-held slot and execs into it. The mechanism is complete. What
remains is that an agent working in a worktree cannot *find* it, cannot target it
reliably once launched, and cannot provision a worktree that reaches a buildable
state without hand-repair.

Load-bearing premises, all verified in-tree:

- `AGENTS.md` contains no occurrence of "slot", "launch", or "worktree". It is
  `@`-included by `CLAUDE.md`, so it is the first thing every agent reads, and its
  Build section presents `just build-run` as the way to run the app. That path
  passes `--kill-running` and `open`s the shared `~/Applications/DanTerm Dev.app`:
  it quits and replaces the user's instance. The slot workflow is documented only
  in `README.md` and `integrations/danterm/SKILL.md`.
- `cli/main.swift#selectControlSocketPath` falls back to `controlSocketPath()`
  whenever `DANTERM_SOCK` and `DANTERM` are both unset, and the CLI has no flag to
  name a socket. An agent's own shell is exactly that case, so a `danterm` call
  from a worktree mutates the user's app with no error.
- `dev-slot-launcher.py#launch_services_environment` discards the inherited
  environment wholesale (`del inherited`). This is required by that plan's I10, but
  with no escape hatch a slot cannot exercise either env-gated code path that
  exists: backend selection (`AppDelegate#applicationDidFinishLaunching`) and PTY
  recording (`SwiftTerminalBackend`).
- `test-ui.sh` compiles to a fixed `/tmp/danterm-ui-tests` and runs it, so two
  checkouts running the harness overwrite each other's binary between build and run.
- The dev-slot build lock lives at `.build/dev-slot-build.lock`, inside the
  directory `just clean` removes. A holder then guards an unlinked inode while the
  next launcher creates a fresh file.
- Worktrees are already in use at `.claude/worktrees/`, and both have
  `references/` and `lib/GhosttyKit.xcframework` symlinked by hand to the primary
  checkout. The provisioning step is real, already practiced, and unwritten --
  so it is applied inconsistently and from memory.
- `terminal_benchmark_snapshot.py#digest_prerequisites` raises rather than
  degrading when a prerequisite is absent, so an unprovisioned worktree cannot
  benchmark at all until it is repaired.

## Decision

Close the discoverability and provisioning gaps around the existing slot
mechanism. Nothing about slot identity, socket ownership, or launch policy changes.

Four decisive constraints:

- **The agent entry doc is the deliverable, not a footnote.** The reason agents
  clobber the user's app is that the correct path is documented where they do not
  look. `AGENTS.md` gains the isolated-launch workflow, the explicit-target rule,
  and the worktree provisioning step.
- **An instance is targetable without ambient state.** The CLI accepts an explicit
  socket, which outranks every ambient source. Environment plumbing survives only
  until an agent shells out through something that resets it; a flag is visible in
  the command that is written.
- **Environment reaches a slot only when named.** Passthrough is per-variable and
  restricted to DanTerm-owned names, preserving the measured guarantee that
  unmanaged launching-agent state does not leak into slot panes.
- **Benchmark storage and benchmark concurrency stay out of scope.**
  `plans/wip/bounded-benchmark-storage.md` owns benchmark storage; splitting that
  ownership across two plans is worse than the duplication it would save.

## Invariants

- **I1** A `danterm` invocation can name its target instance explicitly, and an
  explicit target outranks every ambient source. With no explicit target, socket
  resolution is exactly what it is today.
- **I2** A slot instance receives an explicitly named DanTerm-owned environment
  value, and no unnamed value from the launching process reaches it.
- **I3** Concurrent UI-harness runs from different checkouts never share a build
  artifact path.
- **I4** Two launchers in one checkout serialize canonical bundle assembly even
  across removal of that checkout's build products.
- **I5** Provisioning a worktree makes every shared external build prerequisite
  present, is repeatable, and writes nothing outside the worktree being
  provisioned.
- **I6** The agent entry doc names an isolated launch path that never quits,
  replaces, or focuses the user's canonical app, and states the explicit-target
  rule and the provisioning step. Every doc that teaches driving a slot
  demonstrates the explicit target rather than an exported ambient one, and the
  CLI's source-of-truth doc describes the new flags in the same change that adds
  them.

## Proof obligations

- **PO1** (I1) An explicit target wins over a conflicting ambient one; with none
  supplied, resolution matches current behavior including its fail-closed case.
- **PO2** (I2) An allowlisted value reaches a slot's panes; a non-allowlisted
  variable present in the launcher's own environment does not. This extends the
  existing environment-fidelity proof rather than replacing it.
- **PO3** (I3) Two concurrent harness invocations build and run distinct
  artifacts.
- **PO4** (I4) A holder still excludes a second builder after the guarded build
  directory is removed.
- **PO5** (I5) Provisioning a fresh worktree yields every prerequisite the
  benchmark harness demands, is idempotent, and leaves the source checkout
  unmodified.
- **PO6** (I6) **Manual.** From a fresh worktree, following only `AGENTS.md` and
  the docs it points at, provision, launch a slot, and drive it by the documented
  explicit target -- while the user's canonical app stays running, focused, and
  unreplaced throughout. No slot-driving recipe in those docs relies on an
  exported ambient target.

## Non-goals

- Relocating, sharing, or bounding benchmark storage. The per-checkout arm cache
  is large (40 GB across 46 entries in this checkout) and its content-addressed
  key would make cross-checkout sharing safe, but that is an amendment to
  `plans/wip/bounded-benchmark-storage.md`, whose retention budgets already
  shrink the problem.
- Serializing concurrent benchmark runs.
- Per-slot `HOME` or config isolation, and converting the slot-0-only screenshot
  recipe. Both settled by the concurrent-dev-instances plan.

## Accepted risks

- **AR1** Each slot remains a separate notification principal needing a one-time
  foreground grant. Documented as an operational step rather than automated; the
  grant survives re-signing, so it is paid once per slot.
- **AR2** Symlinked prerequisites mean rebuilding the xcframework in the primary
  checkout changes it for every worktree at once, and a worktree that rebuilds it
  locally silently stops sharing. Accepted: the Ghostty version is pinned, so
  rebuilds are rare and deliberate.

## Rejected ideas

- **RI1** A cross-process lock serializing benchmark runs. Host load is already
  sampled and recorded beside every verdict, excluding the harness's own
  descendants, and gating on it was decided against on evidence -- no one has
  calibrated what load perturbs a decision, and a wrong refusal gate is worse than
  none. Concurrent shared benchmark use is also a stated requirement of the
  storage plan.
- **RI2** Unrestricted environment passthrough in the launcher. Reopens the
  measured leak of unmanaged agent-session state into slot panes.
- **RI3** Making the CLI refuse or warn when it resolves the fallback socket. That
  fallback is correct for the user's own shell; only an explicit target
  disambiguates the agent's case.

## Implementation discretion

- The provisioning command's name, and which shared inputs it links beyond the
  prerequisites the benchmark harness already demands.
- The allowlist's membership and the spelling of both new flags.

## Critical files

`AGENTS.md`, `integrations/danterm/SKILL.md`, `README.md`'s isolated-launch
recipe, `cli/main.swift` plus the protocol parser and its tests,
`scripts/dev-slot-launcher.py`, `test-ui.sh`, `justfile`, and a new provisioning
script under `scripts/` with a self-test alongside the existing
`scripts/tests/*_test.sh` suites.

## End-to-end check

From a worktree provisioned only by the new command and `AGENTS.md`: launch a
slot, drive it by explicit socket while the user's app stays untouched, launch a
second slot with an allowlisted backend override and confirm it took effect,
then run the UI harness in both checkouts concurrently.

## Commit progress

- [x] 1. feat(cli): add explicit control-socket targeting
- [x] 2. fix(dev): preserve allowlisted slot environment and durable build locking
- [x] 3. test(ui): isolate harness artifacts by checkout
- [x] 4. feat(dev): provision worktree prerequisites and document the isolated workflow
