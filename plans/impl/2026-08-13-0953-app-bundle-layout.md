# One declaration of the app bundle's layout

## Context

The macOS bundle's layout contract -- which files exist at which paths, with
which mode, matching which source -- is hand-written in six places, and the
copies have already drifted:

- `.github/workflows/ci.yml:142-172` (built bundle) and `:174-183` (unzipped
  round-trip; missing four checks its sibling has).
- `.github/workflows/release-stable.yml:40-67` (missing the `themes/catalog.json`
  check) and `:114-131` (round-trip, same reduced set).
- `build-app.sh:55-112`, which alone has the `/usr/bin/stat -f %i` inode guard.
- `dev-build.sh:73-104`, which alone lacks both GUI/CLI guards entirely.

Because the lists are YAML text rather than something runnable,
`scripts/tests/build-app-helpers-contract_test.sh` defends them by grepping the
workflow files for literal strings -- a test of a copy, which passes on a list
that is present but wrong.

Two facts reframe the work:

1. **Part of this is redundancy, not duplication.** The gate already runs the
   real `build-app.sh` and `dev-build.sh` under a shimmed `swift`, and both
   already assert hooks, shell-integration assets, and the SKILL.md compare.
   `ci.yml:142-172` and `release-stable.yml:40-67` re-assert on a runner what
   `just test` proves in seconds. Those blocks should be deleted, not re-pointed.
   Verification earns its place *after a transformation* -- codesign, zip
   round-trip -- where the pipeline is the system under test. (The GUI/CLI guards
   are the exception in the other direction: `build-app.sh` has them,
   `dev-build.sh` has neither, and the shared assembler is what will make both
   producer tests enforce them.)
2. **The contract already has a partial owner in Swift.**
   `DanTermProtocol.DanTermInstanceIdentity` owns `bundleIdentifier`,
   `displayName`, and `executableName`; `dev-build.sh:109-113` re-types all of
   them as plutil literals. `tools/DanTermInstanceIdentityTool` is already a
   build-time JSON bridge from that declaration. The pattern to extend exists.
3. **The repo builds five bundle shapes, and three are unmanaged.** Beyond
   release and dev there are: the slot clone in `dev-slot-launcher.py`
   (`stage_slot_bundle`), which renames the `Contents/MacOS` executable, rewrites
   four plist keys, and re-signs *after* `dev-build.sh` has verified its output;
   and the benchmark and viability harnesses (`scripts/terminal-benchmark.sh`,
   `scripts/terminal-viability.sh`), which each assemble a runnable bundle from
   literal paths -- `Contents/MacOS/<name>`, `Contents/Helpers/danterm`,
   `Contents/Helpers/PTYSessionBootstrap`, a patched `Info.plist`, theme
   resources -- and sign it. So "which file holds the pane bootstrap" is written
   by hand in five places, and "the plist executable name matches the file in
   `Contents/MacOS`" is re-established independently four times. Changing a
   declared path would update the release and dev bundles and leave either
   harness emitting a bundle that cannot open a pane.

Meanwhile the layout the app actually *needs* is written a seventh time, in
Swift, and no bash list is derived from it: `app/SwiftTerminalBackend.swift:31`
(`isReady` is literally `isExecutableFile` on `Contents/Helpers/PTYSessionBootstrap`),
`app/SwiftTerminalBackend.swift:162`, `DoctorProber.swift:253,431`,
`CLIPathInstaller.swift:29`. The incident this apparatus was built for -- recorded
in the contract test as "build-app.sh once produced a bundle whose default
terminal backend could not start, and every packaging check still passed" -- is
exactly a drift between those call sites and the packaging list. A longer bash
list cannot close it.

**Outcome:** one declaration names the bundle's contents; assembly, the runtime
call sites, and verification all derive from it; adding a bundled resource is one
edit.

## Decision

Declare `BundleLayout` in `lib/DanTermProtocol/Sources/DanTermProtocol/`, beside
`InstanceIdentity.swift`, which every consumer already depends on. A build-only
emitter product writes a variant's concrete plan as JSON. One
`scripts/assemble-app-bundle.sh` consumes the plan and performs every copy,
`chmod`, and plist write; one `scripts/verify-bundle-layout.sh` checks a bundle
against it. The four Swift call sites resolve their paths from the same
declaration.

This absorbs the sibling audit finding about duplicated bundle assembly between
`build-app.sh` and `dev-build.sh`: the shared assembler is the plan's natural
consumer, and writing that consumer twice is the thing being removed.

Every bundle shape is a declared variant, including the benchmark and viability
harnesses -- whose entry sets are genuinely smaller than a shipping bundle, which
the per-variant exact-set rule already expresses. The slot clone is a
*transformer* rather than a producer: it consumes the emitted identity already,
so it verifies after its final rewrite and signing step instead of declaring a
variant of its own.

Scope note: the plan is *not* shipped inside the bundle and there is no
`danterm verify-bundle` command. Both existed only to serve `package.nix`, which
is a non-goal below.

## Invariants

- **I1.** One declaration names every bundle-relative path, its required mode,
  and its content source, for every variant the repo builds -- release, dev, and
  the benchmark and viability harnesses. Assembly and verification both derive
  from it, and no script assembles a `.app` from literal paths.
- **I2.** A bundle's plist identity (bundle id, name, display name, executable
  name, icon name) and the path its executable is written to derive from one
  identity value, so `CFBundleExecutable` and the file present in
  `Contents/MacOS` cannot disagree. Today `DanTermInstanceIdentity` names only
  production and dev, mapping every other identifier to `DanTerm`; the harness
  variants must keep the identities they have now -- their own display and
  executable names, and the benchmark's caller-supplied bundle suffix, which A/B
  and isolation runs depend on -- rather than collapse onto the production name.
- **I3.** `Contents/MacOS`, `Contents/Helpers`, and
  `Contents/Resources/danterm-hooks` contain exactly the variant's declared
  entries and nothing else. A release bundle rejects dev-only entries, and a dev
  bundle is rejected by release verification.
- **I4.** Every declared entry with a byte-identical repo source is
  byte-identical to it, and
  `Contents/Resources/shell-integration` is tree-identical to
  `integrations/shell-integration` -- so a newly added integration asset needs no
  assertion edit. The plist source is a template because identity and version
  stamping transform it. Declared *executables* have no repo source and are
  never byte-compared: codesign rewrites them, so byte-identity could only hold
  before signing, and one contract that holds everywhere is worth more than a
  stronger one that forces a reduced mode at half the sites. Their correctness
  rests on I2, I3, I5, and the build-provenance assertions the producer contract
  tests already make.
- **I5.** The GUI and CLI binaries are distinct by inode and by content, on every
  variant and at every site.
- **I6.** `Assets.car` comes from the variant's own icon source.
- **I7.** No producer exits successfully having emitted an unverified bundle.
- **I8.** A bundle that has been through a transformation -- codesign, a zip
  round-trip, or the slot clone's rename-and-resign -- satisfies the same
  contract at full strength, verified after the last step that rewrites it.
  Today's weaker subset at the round-trip sites is drift, not design.
- **I9.** The paths the app resolves at runtime are entries of the same
  declaration that was verified.

## Proof obligations

- **PO1** (I1, I3, I4) -- For every entry the declaration emits, removing it or
  clearing its required mode fails verification and names the entry; for every
  entry that has a byte-identical repo source, perturbing its bytes fails as
  well. The test
  enumerates from the declaration, so a newly declared entry cannot arrive
  unguarded and no test edit is needed to cover it.
- **PO2** (I1) -- Executables have no repo source, so their provenance is proven
  at assembly instead of by the verifier: given distinct fake products, every
  declared executable destination receives the product the declaration names.
  This is the obligation that rejects the recorded incident's shape -- a bundle
  whose bootstrap slot holds the CLI binary satisfies mode, exact-set, and
  distinctness and still cannot open a pane.
- **PO3** (I3) -- An undeclared extra file in an exact-set directory fails.
- **PO4** (I2) -- A bundle whose `CFBundleExecutable` disagrees with the file in
  `Contents/MacOS` fails, and each variant rejects the other's shape. Separately,
  every variant still resolves to the identity it has today, including each
  bundle suffix the benchmark harness accepts.
- **PO5** (I5) -- A CLI hardlinked to the GUI and a CLI byte-copied from the GUI
  each fail. These are two distinct real causes and need separate proof.
- **PO6** (I7) -- Every producer emits a bundle that verifies, and a producer
  whose assembly is sabotaged exits non-zero. Each producer must also propagate a
  verifier failure rather than exit zero -- a launch-and-open-pane check passes
  whether or not the producer ever called the verifier, so the call itself needs
  proof. The seam is a shimmed executable on `PATH`, as the existing fixtures
  already shim `swift`; a test-only branch inside a producer is not acceptable.
- **PO7** (I8) -- The full contract holds after codesign, after a zip round trip,
  and after the slot clone's rename-and-resign -- the last of which must fail
  when the renamed executable and the rewritten `CFBundleExecutable` disagree.
  This includes confirming empirically that codesign leaves `Info.plist` and
  `Contents/Resources` bytes untouched; if it does not, narrow that single
  invariant with a stated reason rather than adding a reduced mode.
- **PO8** (I9) -- The runtime call sites and the packaging contract cannot
  disagree, because they read one value.
- **PO9** -- Both workflows invoke the verifier after signing and after
  unzipping. No local execution can establish this, so it is the one claim a
  grep still owns.

## Non-goals

- `package.nix` keeps its own three-line GUI/CLI check. It verifies a pinned,
  already-published zip with no repo checkout, so most of the contract is
  unrunnable there and a moving contract pointed at a frozen artifact would fail
  spuriously on every future addition. Add a comment saying why it is
  deliberately independent.
- The `fetchzip` unpacker path is not covered: nothing will check the hooks'
  executable bit as Nix unpacks a release. The CI zip round-trip covers the
  equivalent risk for the artifact CI produces.
- Notarization, stapling, and the nested-code-signs-before-container ordering
  check are untouched. That ordering check is a different contract with no
  executable form and stays as-is.

## Accepted risks

- **AR1.** Exact-set rules make a stray file (a `.DS_Store` in `Helpers`) fail a
  local build. Correct behavior; the message names the offending file.
- **AR2.** Bundle assembly gains a dependency on a built Swift binary. Mild: both
  producers already run multiple SwiftPM invocations, and the emitter is the same
  shape as the existing `DanTermInstanceIdentityTool`.
- **AR3.** `scripts/tests/dev-build-configuration-contract_test.sh` shims three
  products as byte-identical copies of `/usr/bin/true`, which the GUI/CLI guard
  correctly rejects once the dev path gains it. The fixture must emit distinct
  bytes per product, as the release fixture already does. That the dev fixture
  got away with identical binaries measures exactly the guard the dev path was
  missing.
- **AR4.** Because declared executables are not byte-compared (I4), a *different*
  but validly signed executable substituted at a declared path *after assembly*
  would pass verification. The assembly-time version of this failure is the one
  with a real mechanism, and PO2 closes it; nothing downstream of assembly
  swaps binaries. Closing the residue would mean normalizing signatures to
  compare payloads, which is durable mechanism bought against no mechanism that
  produces the failure.

## Rejected ideas

- **RI1.** A bash script holding the assertion list (the audit's stated fix).
  Leaves the contract hand-written in three places -- the verifier plus each
  producer's copy loops -- leaves the assembly duplication open to reopen the same
  files, and nothing fails when it drifts from the Swift runtime paths.
- **RI2.** A plain data manifest with no Swift owner. Same drift gap against the
  runtime call sites; it would need a compensating lint over `app/` and `lib/`
  string literals, and that lint would be the load-bearing part.
- **RI3.** Deriving the variant from the bundle's own `Info.plist`. That makes the
  plist an input, so it can only ever be self-consistent, never wrong. The caller
  states intent and the plist is checked against it.

## Critical files

`lib/DanTermProtocol/Sources/DanTermProtocol/` (the declaration, beside
`InstanceIdentity.swift`), a build-only emitter under `tools/`, a shared
assembler and verifier under `scripts/` with a sibling test, `build-app.sh`,
`dev-build.sh`, `scripts/dev-slot-launcher.py`, `scripts/terminal-benchmark.sh`,
`scripts/terminal-viability.sh`, `.github/workflows/ci.yml`,
`.github/workflows/release-stable.yml`, the two producer contract tests under
`scripts/tests/`, `scripts/run-test-suite.sh`, `agent-docs/build-details.md`,
`docs/ci.md`.

The runtime path constants to re-point live in `app/SwiftTerminalBackend.swift`,
`DoctorProber.swift`, and `CLIPathInstaller.swift`; I9 is the requirement, and
finding them is implementation.

## Verification

Behavioral, run locally:

- `just test` -- gains the verifier's own test step, and the two existing
  producer contract tests now exercise the full contract for real.
- `bash ./dev-build.sh --no-install` and `bash ./build-app.sh --version 0.0.0-test`
  each produce a bundle and verify it; deleting a file from the result and
  re-running the verifier must fail naming that file.
- `just launch-slot` must still start a dev bundle and open a session, which is
  the end-to-end proof that the re-pointed runtime paths still resolve and that
  the slot clone verifies after its rewrite. Release the slot with
  `just stop-slot <n>` afterwards.
- `scripts/terminal-benchmark.sh` and `scripts/terminal-viability.sh` must each
  still assemble, launch, and open a pane -- the proof that their reduced
  variants declare enough to run.
- Confirm PO7's codesign question empirically before relying on it.

## Commit progress

- [x] Declare `BundleLayout` and re-point the four Swift runtime call sites at
      it. No build-script change yet; the gate stays green on its own terms.
- [x] Add the emitter product and `scripts/verify-bundle-layout.sh`, plus its
      test in `run-test-suite.sh`. Nothing calls the verifier in anger yet.
- [x] Add `scripts/assemble-app-bundle.sh`; both producers become compile +
      assemble + verify. Deletes their inline assertions and `dev-build.sh`'s five
      plutil literals. Fixes the dev fixture's identical-binaries shim.
- [x] Declare the benchmark and viability variants, preserving the identities
      they have today; both harnesses assemble and verify through the shared path
      instead of literal ones. The slot clone verifies after its
      rename-and-resign.
- [x] Workflows: delete the two redundant verify blocks, add verifier calls at
      the signing and round-trip sites, retarget the meta-test at the verifier
      invocation, update `agent-docs/build-details.md` and `docs/ci.md`.

## Implementation notes

- `Info.plist` uses a distinct template source kind. Bundle identity and version
  stamping transform it, so it cannot satisfy the byte-identical repository
  source rule that applies to copied files.
