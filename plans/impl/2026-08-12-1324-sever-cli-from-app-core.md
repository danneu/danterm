# Sever the danterm CLI from the app core (S11 ideal fix)

## Problem

The `DanTermCLI` target compiles all of DanTermCore and DanTermSupport
same-module through two tracked symlinks (`cli/DanTermCore`,
`cli/DanTermSupport`, no `exclude:`), solely so `danterm doctor` can call
seven internal symbols: `evaluateDoctor` / `renderDoctorReport` /
`doctorExitCode` / `DanTermConfigDocument` (core) and `gatherDoctorFacts` /
`resolveInstalledFontFamily` / `DanTermConfigPaths` (support). Nothing else
in `cli/` names a core or support symbol -- every other dependency is
already DanTermProtocol.

Consequences: the shell client is a 13M binary, every core edit rebuilds
it, every core compile error breaks it, and AGENTS.md's layering claim
holds by convention rather than by construction. This is audit finding S11
(docs/scratch/2026-08-11-simplification-audit.md).

## Decision

Make the CLI's dependency graph its real one: `cli/*.swift` +
DanTermProtocol + an importable DanTermSupport module, and delete both
symlinks. Four moves, each to the place whose consumers justify it:

1. **Config schema -> DanTermProtocol.** `DanTermConfig`, `AlertClearMode`,
   and `DanTermConfigDocument` move from DanTermCore into DanTermProtocol
   as public API. The config file is a cross-process contract -- the app
   and the CLI's doctor read the same `~/.config/danterm/config.json` --
   which is the same rationale that already placed `DoctorFacts`,
   `SocketPath`, and `EnvVars` in the leaf. The `renderableFontSizeRange`
   global stays behind in core (its consumers are core-side).

2. **Config-font probing -> DanTermSupport.** `gatherConfigFontFacts`
   moves from `cli/DoctorConfigFont.swift` into the doctor prober, which
   can now see the document type via the protocol leaf; the CLI file is
   deleted. The permissions fact stays a CLI-supplied parameter (it comes
   from the app over the socket, which only the CLI can ask).

3. **Doctor evaluator -> cli/.** `Doctor.swift` (evaluator + renderer +
   exit-code mapping; self-contained over DanTermProtocol + stdlib) moves
   into `cli/` as internal code. The CLI is its only caller -- the app
   never runs it -- so it needs no public surface and no shared module.

4. **DanTermSupport becomes a root-package target.** Follow the existing
   DanTermProtocol precedent exactly: a root `.target` over
   `lib/DanTermSupport/Sources/DanTermSupport` depending on the
   `DanTermProtocol` target, with the CoreText linker setting moving off
   the CLI target onto it. Do NOT add `.package(path: "lib/DanTermSupport")`
   -- that package's own manifest depends on `../DanTermProtocol` as a
   package, which would put two DanTermProtocol modules in one graph. The
   app target keeps its `app/DanTermSupport` symlink and must not also
   depend on the new target.

The support module gains the minimum surface the CLI's
`gatherDoctorFacts(configFont:permissions:)` call needs, at `package`
access: the CLI and DanTermSupport are targets of the same root package,
so nothing here needs a durable external-package API. `public` is
reserved for a declaration proven to need an external-package consumer.
Nothing recursive; `CLIPathInstaller` and its `Dependencies` stay
internal. (The config schema moving into DanTermProtocol is public, not
`package` -- `lib/DanTermCore` depends on `lib/DanTermProtocol` as a
separate package.)

Docs travel with the change: the pure-core-support-split ADR
(docs/design/2026-05-28-pure-core-support-split.md) gets a dated amendment
updating the layer diagram and its "one public-surface addition" claim;
stale placement comments in `DanTermConfigPaths.swift`,
`DoctorProber.swift`, `DoctorFacts.swift`, and the root `Package.swift`
CoreText comment are corrected; `scripts/run-test-suite.sh` gains a
portable-profile purity-lint step for DanTermProtocol so the moved config
codec stays lint-covered (the pure profile cannot apply: existing protocol
files use FileManager).

## Invariants

- I1: No DanTermCore source compiles into the CLI binary, and the CLI
  target's declared dependencies are exactly DanTermProtocol and
  DanTermSupport. Holds by construction once the symlinks are gone.
- I2: One config schema. The app and doctor decode `config.json` through
  the same document type; a schema change cannot desynchronize them.
- I3: `danterm doctor` output, exit codes, and the rest of the CLI surface
  are byte-for-byte unchanged. No wire or SKILL.md change.
- I4: DanTermSupport still names nothing in DanTermCore; the standalone
  `swift test --package-path lib/DanTermSupport` build remains the
  structural proof.
- I5: App behavior is unchanged; the app keeps compiling core and support
  same-module via the `app/` symlinks with no new access annotations
  beyond the doctor surface.
- I6: No declaration is made `public` for a same-package consumer;
  CLI-facing support declarations use `package` access.

## Proof obligations

- PO1 (I3): the existing doctor evaluator suite passes unchanged after
  relocating to `cli-tests/` (`@testable import DanTermCLI`, the
  established pattern there). The deterministic evaluator and prober
  tests are the acceptance gate for I3. A `danterm doctor` diff is a
  smoke check on top of them, and only counts when the two runs are
  comparable: build the CLI from this worktree in one configuration,
  capture output and exit code, make the source moves, rebuild the same
  product in the same configuration, and diff with machine state
  unchanged in between. Never diff against an installed binary of
  unknown revision.
- PO2 (I2): prober tests cover the config-font fact through
  `gatherDoctorFacts` -- installed, not-installed, unset, and unreadable
  config all reportable. This is the first behavioral coverage of
  config-font fact gathering; the CLI-side helper has none today.
- PO3 (I1): the root package builds with both symlinks deleted. A
  substantial drop in `danterm` binary size from 13M is corroborating
  evidence, not an acceptance gate.
- PO4 (I4, I5): the four package suites and the root-package suite in
  `just test` stay green, including the standalone support build.

## Non-goals

- No change to the CLI command surface or `integrations/danterm/SKILL.md`.
- DanTermCore does not become an importable module; nothing outside the
  doctor/config surface goes public.
- The app's same-module symlink compilation (core-module-via-symlink ADR)
  is not revisited.

## Accepted risks

- AR1: DanTermProtocol's charter widens from "wire protocol + CLI parsing"
  to cross-process contracts generally (it already held DoctorFacts and
  SocketPath); the ADR amendment states this so the widening is a decision,
  not drift.
- AR2: The split's "annotation-free" property is deliberately spent on a
  small `package`-access doctor surface in support. The cost is confined
  to the root package -- no durable external API -- and is smaller than
  the IPC line framer precedent the ADR documents as the accepted escape
  hatch.

## Rejected ideas

- RI1: Evaluator into DanTermProtocol as public API (the audit finding's
  sketch) -- public surface for a single client; cli-internal placement is
  strictly smaller.
- RI2: Minimal `font.family` re-decode in support, schema staying in core
  -- two decoders of one file drift silently.
- RI3: `exclude:` on the core symlink only -- the evaluator lives in core,
  so this cannot work without the moves anyway.

## Critical files

- `Package.swift` (new DanTermSupport target, CLI dependencies, CoreText)
- `cli/DanTermCore`, `cli/DanTermSupport` (deleted), `cli/main.swift`,
  `cli/DoctorConfigFont.swift` (deleted), `cli/` gains Doctor.swift
- `lib/DanTermCore/Sources/DanTermCore/`: Doctor.swift, DanTermConfig.swift,
  DanTermConfigDocument.swift move out; files referencing the config types
  gain `import DanTermProtocol` (same pattern app-side, e.g.
  `app/DanTermConfigStore.swift`, `app/PreferencesPanel.swift`)
- `lib/DanTermSupport/Sources/DanTermSupport/`: DoctorProber.swift,
  DanTermConfigPaths.swift, FontAvailability.swift (public surface +
  config-font probe)
- Test suites: `cli-tests/`, `lib/DanTermSupport/Tests`,
  `lib/DanTermProtocol/Tests`, `lib/DanTermCore/Tests` (relocations and
  import additions)
- `docs/design/2026-05-28-pure-core-support-split.md`,
  `scripts/run-test-suite.sh`

## Verification

1. Build `.build/debug/DanTermCLI` from this worktree and capture its
   `DanTermCLI doctor` output + exit code before starting.
2. `just test` -- all package suites, root-package suite, purity lints
   (including the new protocol step).
3. Rebuild `.build/debug/DanTermCLI` in the same configuration, rerun
   `DanTermCLI doctor`, diff against the capture (smoke check; machine
   state must be unchanged since step 1).
4. `ls -la .build/debug/DanTermCLI` -- note the size drop.
5. `swift test --package-path lib/DanTermSupport` standalone -- the
   sibling-independence proof still compiles.

## Implementation discretion

- The exact `package` annotation set on support (e.g. whether
  `DoctorProbeEnv.live` must be annotated as a default argument) --
  settled at compile time, kept minimal.
- Where the two config test files land (protocol tests vs. staying in
  core tests importing the moved types).

## Commit progress

- [x] 1. refactor(protocol): own the shared config contract
- [x] 2. refactor(cli): sever the app core dependency
