# One owner for the mode of every file DanTerm creates

## Context

`docs/scratch/2026-08-25-terminal-security-audit.md` records four findings that
are one defect seen from four places: nothing owns the permissions of the files
this process writes, so each writer decides for itself and most decide nothing.

- **DT-SEC-03** (high). `last-enriched.json` holds every pane's scrollback,
  bounded at 4,000 lines and 400,000 characters per pane, rewritten every 600 s
  and on clean exit. It is written 0644. Observed on disk today. Ghostty shipped
  this exact bug and fixed it in 1.0.1 (GHSA-hfg5-8q2c-crhc).
- **DT-SEC-05** (med). `Recovery/` reaches 0700 only because the IPC audit
  writer happens to `chmod` it on the first `danterm` invocation. An instance
  that never receives one leaves the directory at the umask default with
  scrollback inside it.
- **DT-SEC-16** (low). Scrollback replay files under the temporary root are
  written 0644 into a directory created with no mode.
- **DT-SEC-15** (low). The control socket is `0777 & ~umask` between `listen()`
  and the `chmod` that follows it, so it is already accepting during the window.

An inventory of the tree found 7 production directory creations and 8 production
file creations. Two set a mode. The three that do set one disagree on how:
post-hoc `chmod(path,)`, `open` mode plus `fchmod`, and a raw octal literal.
There is no `umask` call anywhere in the repo, so every unmoded create is at the
mercy of whatever umask the process inherited.

The exposure today is bounded by `~/Library` being 0700, which is exactly the
problem: the layer that should not depend on that is depending on it.

Desired outcome: a file this process creates cannot be readable by another user,
and a writer added later cannot reintroduce the defect by omission.

## Decision

**D1. One seam creates every file and directory, and it creates them private.**
A writer in `DanTermSupport` gains the sole authority to create a file or a
directory in `app/` and `lib/`. It states the mode itself rather than inheriting
whatever the umask leaves, and it finishes stating it before the artifact is
reachable under the name a reader would use -- `open` with an explicit mode plus
`fchmod` on the descriptor, which is what `IpcAuditLogWriter` already does. This
extends the invariant `DanTermInstancePaths` already holds -- one value owns
every path this process keys by identity -- one step further: the same owner now
answers what mode that path is created with.

**D2. Private is the default; user-visible is a declaration.** This policy
governs the files the running product creates -- the app and the `danterm` CLI.
Source-maintenance tools under `tools/` are a different domain: they rewrite
git-tracked files in the working tree, so they preserve the modes they find and
stay outside the seam. A call site inside the product that wants the umask
default must say so at the call. Exactly three artifacts qualify:
the config file at `~/.config/danterm/config.json`, its directory, and the CLI
symlink, all of which the user edits or inspects directly and none of which
carry terminal content. Everything else is private, including the state export
the user chooses a destination for with `NSSavePanel` -- it contains every
pane's scrollback, so its content decides its mode, not its path.

**D3. Atomic and private are the same operation.** `Data.write(options: .atomic)`
writes a sibling temp file and renames it, so a mode applied after the write
leaves a umask-default file at the final path first, and leaves the temp file at
that mode for its whole life. The seam modes the temp file and renames, so no
world-readable name for the content ever exists. `.atomic`'s durability and
replace-in-place behavior are preserved.

**D4. The socket is bound and moded by one operation.** Creating the socket node
and giving it 0600 becomes a single step in the seam, which hands back a bound
descriptor that has not yet listened. `listen()` stays with the caller. The
vulnerable ordering is then unrepresentable rather than merely corrected: a
caller cannot reach the fd until the mode is already on the node, so no test seam
and no ordering lint is needed to keep DT-SEC-15 closed.

**D5. A lint holds the shape.** `scripts/private-file-mode-lint.sh`, in the shape
of `scripts/ambient-identity-lint.sh`, rejects creating a file or a directory
across `app/`, `lib/`, and `cli/` outside the seam. `tools/` is out of its sweep
for the reason D2 gives. It carries a path-suffix
allowlist, a stale-entry check, a `*_LINT_ROOT` test seam, a
`scripts/lib/lint-rationale.sh` failure block, and a self-test under
`scripts/tests/`. It joins `LINT_STEPS` and its self-test joins `STEPS` in
`scripts/run-test-suite.sh`. It is a regression guard over the creation
spellings this codebase actually uses, not a proof that no other spelling exists
(AR4). Without it this is three patches that drift back apart, which is how the
tree reached its current state.

**D6. The ADR records it.** The "same identity keys the paths" section of
`docs/design/2026-05-28-pure-core-support-split.md` gains the mode half of the
invariant, and the audit register's four findings are marked fixed.

Critical files: `lib/DanTermSupport/Sources/DanTermSupport/` (the new seam plus
`CheckpointWriter.swift`, `RecoveryStore.swift`, `IpcAuditLogWriter.swift`,
`ControlSocketListener.swift`, `CLIPathInstaller.swift`),
`app/AppRuntime.swift` (replay files, both checkpoint tiers, state export),
`app/DanTermConfigStore.swift`, `scripts/run-test-suite.sh`.

The privileged branch of `CLIPathInstaller` shells out to `/bin/mkdir -p` under
`osascript`; it creates a directory in the user's own `bin` path and is
allowlisted with that reason rather than routed.

## Invariants

- **I1.** A private artifact is never nameable at a mode broader than 0600 for a
  file or 0700 for a directory, and holds exactly that mode once the write
  reports success -- on a fresh instance that has received no IPC connection, and
  whatever umask the process inherited.
- **I2.** No path holding terminal content is ever nameable at a broader mode --
  not the final path, and not the temp sibling an atomic write goes through.
- **I3.** An existing private file whose mode is already broader is narrowed by
  the write, not left as found.
- **I4.** The three user-visible artifacts (config file, config directory, CLI
  link) keep umask-default creation and replacement semantics, and each says so
  at its call site. They are the only artifacts I1 does not govern.
- **I5.** The control socket carries 0600 from the moment a caller can reach its
  descriptor, so no code path can publish it at another mode.
- **I6.** Creating a file or a directory in the running product outside the seam,
  by any spelling present in this codebase, fails the gate.
- **I7.** Atomicity is unchanged: a reader sees either the previous complete file
  or the new one, never a partial write, and no temp sibling survives a
  successful or a failed write.

## Proof obligations

- **PO1 (I1, I3).** Every routed private writer is covered, not a sample: the
  session lock, both checkpoint tiers, the state export, the replay file, the
  audit log and its rotated sibling, the socket's replacement lock, the
  harness-only logs and recordings, and the directory each of them creates. For
  each, the mode on disk is 0600 / 0700 after the write, and is still 0600 / 0700
  when the destination was pre-created 0644. Reverting any one production writer
  to a raw create must change an assertion. `IpcAuditLogWriterTests` is the model
  for how to read a mode; no test asserts a directory mode today.
- **PO2 (DT-SEC-05).** A checkpoint written by an instance that never
  constructed an audit writer still lands in a 0700 directory. This is the
  incidental-mode bug stated as a scenario, so it cannot come back by removing
  the audit writer's `chmod`.
- **PO3 (I2, I7).** A write that fails partway leaves the previous file intact
  and no sibling behind; a successful write leaves no sibling. The temp path's
  mode is asserted, not just the final one.
- **PO4 (I4).** The config file and its directory come out at umask default.
- **PO5 (I6).** The lint self-test: a raw create in a non-allowlisted file
  fails, the seam passes, an allowlisted basename at a wrong path still fails,
  and a stale allowlist entry fails. Follows
  `scripts/tests/ambient-identity-lint_test.sh`.
- **PO6 (I5).** The bound socket the seam returns already carries 0600, asserted
  on the descriptor the seam hands back rather than after
  `ControlSocketListener.open` has finished. A test that only reads the mode
  after `open` returns passes under either ordering, which is how DT-SEC-15
  survived until now.
- **PO7.** Recovery still works end to end -- the existing checkpoint, recovery,
  socket, and installer suites stay green, and `just test` passes.

## Non-goals

- DT-SEC-12 (whether command lines should be persisted at all). Fixing the mode
  bounds that exposure to the local user; whether the data should exist is a
  separate decision.
- Peer credential checks on the socket (DT-SEC-08). Different mechanism,
  different threat-model question.
- Encrypting or shortening checkpoint content.

## Accepted risks

- **AR1.** The state export is 0600 even though the user chose its destination,
  which will surprise anyone who exports to a shared location. It holds every
  pane's scrollback; a `chmod` is the cheaper correction than a leak.
- **AR2.** The seam has one user-visible escape hatch, so a future writer can
  still opt out of privacy. It has to do so in writing, at the call, which is
  the property being bought.
- **AR3.** The privileged installer's shelled-out `mkdir -p` stays outside the
  seam, so one directory creation is enforced by allowlist and comment rather
  than by structure.
- **AR4.** The lint is a text search, so it catches the creation spellings this
  codebase uses and not every spelling that exists -- `copyItem`, a hand-rolled
  `syscall`, or an API added to Foundation later would pass it. It converts
  omission into a caught error, which is the failure mode that produced these
  four findings; it is not a proof.
- **AR5.** No test runs under a hostile umask. `umask` is process-global and the
  suites run in parallel, so setting it would race every other test. I1's
  umask-independence rests on the seam stating the mode explicitly, which PO1's
  pre-created-0644 case exercises from the other direction.

## Rejected ideas

- **RI1. Add a mode argument at the three offending call sites.** Leaves the
  next writer free to omit it, which is the defect, not the symptom. It also
  cannot fix I2: `.atomic` still passes the content through a 0644 sibling.
- **RI2. Set the process umask at launch.** One line, covers every writer, and
  wrong: umask is process-global mutable state that a spawned shell inherits, so
  it would change the mode of files the user's own commands create.
- **RI3. Fix the socket window by binding to a temp path and renaming.** Correct
  but heavier than D4, and it interacts with the stale-reclamation logic under
  the replacement lock for no additional gain.
- **RI4. Keep `chmod` after `bind` and pin the ordering with a test seam or a
  line-order lint.** Both defend an ordering that D4 makes unrepresentable, and
  a production test seam is a shape this repo has been removing.

## Verification

- `just test` green, `just lint` green.
- `just launch-slot`, let it run past one enriched checkpoint or quit it
  cleanly, then check `~/Library/Application Support/<bundle-id>/Recovery`:
  the directory is `drwx------` and every file in it is `-rw-------`.
- Confirm PO2 by hand: launch a slot, do not run any `danterm` command against
  it, quit, and check the directory mode.

## Implementation discretion

- The seam's name, its API shape, and whether it is a type or free functions.
- Whether `CheckpointWriter` learns its ownership at construction or per write.
- Which spellings the lint's pattern set covers, given I6 and AR4.

## Commit progress

- [x] 1. The private-write seam, with the recovery directory, session lock, both
      checkpoint tiers, and the replay files routed through it (DT-SEC-03, -05,
      -16), plus PO2, PO3, and the PO1 cases for those writers.
- [ ] 2. The remaining creators routed -- audit log and its rotation, socket
      directory and replacement lock, config store, state export, harness logs --
      with socket creation and moding folded into one seam operation
      (DT-SEC-15). Completes PO1 and adds PO4 and PO6.
- [ ] 3. `scripts/private-file-mode-lint.sh`, its self-test, and the gate wiring
      (PO5).
- [ ] 4. The ADR amendment and the `AGENTS.md` lint reference.
- [ ] 5. Mark DT-SEC-03, -05, -15, and -16 `fixed` in
      `docs/scratch/2026-08-25-terminal-security-audit.md`, including the
      tracking table, the counts line, and the "File modes have no single owner"
      entry in the cross-cutting note.

## Implementation notes

- The seam is `PrivateFile` in `lib/DanTermSupport/Sources/DanTermSupport/PrivateFile.swift`:
  an enum namespace with `createDirectory(at:)`, `createFile(_:at:)`, and
  `writeAtomically(_:to:)`. It is stateless, so `CheckpointWriter` learns nothing at
  construction -- every call already carries the URL it means.
- `createDirectory` narrows only the directory the caller names. The ancestors it makes
  on the way are created private but an existing one is left as found: those are the
  user's own tree (an Application Support root, a temporary root), and this seam has no
  business restating their modes.
- Replacing `Data.write(options: .atomic)` also adds an `fsync` before the rename, which
  Foundation's atomic write does not do. Durability rises and the cost rides the
  checkpoint queue, so no caller waits on it that did not already wait for the write.
- PO3's temp-sibling mode is asserted through `createFile` -- the primitive the atomic
  write stages through -- plus the cases that prove no sibling survives a success or a
  failure. Reading the sibling mid-write would need either a production test seam (the
  shape RI4 rejects) or a race against the write, so neither is used.
