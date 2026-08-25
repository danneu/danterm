# One private-write seam for both products

## Context

The private-write seam landed as five commits ending `36a91e28`. `PrivateFile`
is now the sole creator of the private artifacts the macOS app and the CLI
write: it states 0600 / 0700 on the descriptor rather than inheriting the
process umask, and `scripts/private-file-mode-lint.sh` fails the gate on a raw
create outside it. Two classes of artifact sit outside that scope by design: the
config file and its directory, and the artifacts the CLI installer puts on the
user's PATH.

The iOS product was left out, and two things follow from that.

`PaneReplicaCheckpointStore` still creates its checkpoint and the directory
holding it at whatever umask it inherits -- the same defect as DT-SEC-03, in the
other product. These are the only two raw creators anywhere under `ios/`.

And DT-SEC-03's register entry now claims `PrivateFile` is "the sole creator of
a file or a directory in the running product". That sentence is wrong twice over:
DanTerm ships two running products and it holds for only one, and it reads as a
universal even where it holds, because both exception classes are outside it.

The seam could not be reused as built: it is `internal` to `DanTermSupport`, a
macOS-only package that also carries sockets, the CLI-path installer, and
CoreText. The lint's header states the same limit as a decision -- `ios/` is out
of the sweep because it is "a different product with its own container, not this
process" -- but that rationale held only while the seam was unreachable from
`ios/`.

Desired outcome: one creator for the private artifacts of both products,
enforced by the gate rather than asserted in a doc, and stated at its true scope
everywhere it is written down.

## Decision

- **D1.** `PrivateFile` becomes its own package, `lib/PrivateFile`, declaring
  macOS and iOS, depending on nothing, with a `public` surface. `DanTermSupport`,
  the app target, and `DanTermMobileKit` depend on it.
- **D2.** The whole seam travels, socket creation included, so a socket node
  does not become a second creator sitting outside I1.
- **D3.** The iOS checkpoint store routes both of its creators through the seam.
  Its injected-writer initializer stays; only the default writer changes.
- **D4.** The lint sweeps `ios/`, and its header rationale is rewritten: the
  roots are the trees that compile into a shipped first-party product, not the
  trees whose container is this process's.
- **D5.** The seam's behavioral suite moves into the new package with it.

Docs travel with the behavior, and each states I1 and I2 at their true scope
rather than as universals: the design note recording the mode invariant, the
`AGENTS.md` lint reference, the lint's own header, DT-SEC-03's closing note, and
the iOS portability gate's comment about `DanTermSupport` being unpinned.

## Invariants

- **I1.** The seam is the only code path that brings a private artifact into
  existence -- file, directory, or Unix socket node -- in either shipped
  product. Two classes of artifact sit outside it, and are named as classes
  wherever the invariant is written down:
  - **Config artifacts** -- the config file and its directory, which the user
    edits by hand.
  - **CLI installation artifacts** -- the `danterm` symlink the user inspects
    on their PATH, and any destination parent the privileged install branch
    creates by shelling out under `osascript`. That branch's parent is outside
    the seam because a shelled-out `mkdir` cannot route through it; the
    unprivileged branch's parent does route through the seam.

  This change adds no third class.
- **I2.** A file or directory the seam creates is never born broader than 0600 /
  0700, and carries exactly that mode by the time the seam returns -- whatever
  umask the process inherited. A socket node carries 0600 before the descriptor
  reaches a caller that could `listen` on it. These hold in the iOS product
  exactly as in the macOS one.
- **I3.** An interrupted atomic write leaves the previous file intact and no
  sibling behind, in the iOS store as in the seam.
- **I4.** The seam depends on nothing. Both products depend on it.

## Proof obligations

- **PO1** (I2). Saving a checkpoint into a directory that does not yet exist
  yields an owner-only file inside an owner-only directory. `DanTermMobileKit`'s
  suite runs on macOS in the gate, so modes are observable there.
- **PO2** (I2). A store directory found at a broader mode is narrowed by a save.
- **PO3** (I3). An interrupted save leaves the prior checkpoint readable and
  leaves no extra file in the directory.
- **PO4** (I1). The lint fails on a raw create under `ios/` and passes on a
  routed one, proven against fixtures in the lint's own self-test.
- **PO5** (I1). The allowlist's stale-entry check still rejects an entry naming
  a file that does not exist, after the seam moves.
- **PO6** (I4). The seam's existing behavioral suite passes from its new
  package, and the package builds on both declared platforms.
- **PO7** (I2). A file and a directory created through the seam under a umask
  that would otherwise mask owner bits still end up at exactly 0600 / 0700. This
  is what makes the mode a property of the seam rather than of the launch
  environment, and nothing proves it today: under the gate's ordinary umask,
  deleting the seam's post-create `fchmod` / `chmod` leaves every other
  obligation green. umask is process-wide, so the proof must not perturb tests
  running beside it.

## Non-goals

- Reducing exposure on the shipped iOS app. The mode is inert there -- one user,
  and the container is unreachable by sandbox policy rather than by mode. This
  change buys enforcement, not exposure reduction.
- `TailnetWhoisResolver`'s private duplicate of the socket-address builder. It
  predates this work and has nothing to do with modes.
- Auditing `ios/` for further writers. There are none.

## Accepted risks

- **AR1.** Socket code compiles into an iOS product that never binds one. An
  iOS SDK divergence in socket APIs would redden the seam's portability lane for
  a reason the iOS product does not care about. Accepted to keep one owner.
- **AR2.** The lint is a line-at-a-time text search, so a create split across
  lines passes it. Pre-existing, now inherited by a second tree.
- **AR3.** The mode-observing test helper is duplicated per test target, because
  test helpers do not cross package boundaries.

## Rejected ideas

- **RI1.** A tracked symlink of the seam into `DanTermMobileKit`. The symlink
  mechanism exists to dodge the access-control tax of wide-surface model types
  whose members the app reads; `PrivateFile` is an enum of static functions with
  no such members, so that rationale is absent and the boundary should be real.
- **RI2.** Leave iOS alone and narrow DT-SEC-03's entry to the app and the CLI.
  The extraction costs about what the doc edit costs and leaves an enforced
  invariant instead of a scoped claim.
- **RI3.** Share the file primitives and leave socket creation behind. A second
  legitimate creator, with the allowlist growing to name it, is the structure
  this work exists to prevent.

## Implementation discretion

- Where the mode-observing helper lives inside each test target.
- How PO7 isolates its umask from tests running beside it.

## Verification

- `just test` -- covers the seam's suite from its new package, the
  `DanTermMobileKit` suite carrying PO1-PO3, the lint sweep, and the lint's
  self-test carrying PO4-PO5. The gate discovers the new package's test lane and
  its iOS portability build from the manifest, so both must exist for the gate
  to stay green.
- `just lint` alone during the edit loop.
- Confirm PO1 against the real app once: launch a slot, attach the phone client
  so a checkpoint is written, and read the mode off the container.

Known-unrelated: the untracked WIP
`lib/TerminalCore/Tests/TerminalCoreTests/TerminalSelectionUnderMouseReportingTests.swift`
fails two selection expectations in `just test` today.

## Critical files

- `lib/DanTermSupport/Sources/DanTermSupport/PrivateFile.swift` -- the seam, and
  its test estate in `lib/DanTermSupport/Tests/DanTermSupportTests/`.
- `ios/DanTermMobileKit/Sources/DanTermMobileKit/PaneReplicaCheckpoint.swift` --
  both iOS creators, in `PaneReplicaCheckpointStore`.
- `scripts/private-file-mode-lint.sh` and its self-test under `scripts/tests/`.
- `scripts/run-test-suite.sh` -- the gate lane for the new package.
- `Package.swift`, `lib/DanTermSupport/Package.swift`,
  `ios/DanTermMobileKit/Package.swift` -- the dependency edges.
- `docs/design/2026-05-28-pure-core-support-split.md`, `AGENTS.md`, and
  `docs/scratch/2026-08-25-terminal-security-audit.md` -- the claims that move.

## Commit progress

- [x] 1. refactor(privacy): extract the private-write seam into its own package
- [x] 2. fix(privacy): route the iOS checkpoint store through the seam

## Implementation notes

- The seam moves whole and public, but `PrivateFile` keeps its old shape in one
  respect: `unixSocketAddress(for:)` became a static member of the enum rather
  than the top-level function it was inside `DanTermSupport`. A package boundary
  would have exported that name into every consumer's global namespace, and it
  is a name `TailnetWhoisResolver` already uses for a private duplicate.
- `DanTermMobileKit`'s edge on the new package lands with commit 2, where its
  store first calls the seam. Declaring it here would be a dependency nothing
  uses.
- PO4 is proven twice over, because one case alone would not have caught a
  regression: an explicit-target run pins the verdict on a raw create under
  `ios/`, and a no-target sweep pins that the sweep goes looking in `ios/` at
  all. Only the second fails when `ios` is dropped from the root list.
- The successful-replace case gained a directory-count assertion alongside the
  interrupted one. The seam stages a hidden sibling that `Data.write` did not,
  so "one file in the directory" is now a claim about new behavior.
- PO7 isolates its umask by serializing its own suite and restoring what it
  found, not by a separate process or gate lane. `Foundation.Process` is not
  available on iOS and the test target cross-compiles there, so a child process
  was not on the table. The shared window is safe because every other artifact
  that target creates is made through the seam, which states its mode outright,
  or by a `write` the case follows with an explicit `setAttributes`.

## Follow Up

- The plan's last verification step is unrun: confirm PO1 against the real phone
  app once -- launch a slot, attach the phone client so a checkpoint is written,
  and read the mode off the container. It needs a device or simulator running the
  iOS app, which the gate does not provide.
