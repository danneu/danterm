# Libghostty removal research

Date: 2026-08-06

## Conclusion

Remove libghostty as a cutover, not as a backend swap hidden inside the current
abstraction. The Swift engine is already the default and the DanTerm-owned
`TerminalSession` boundary is useful independently of Ghostty, but the
process-wide `TerminalBackend` abstraction, backend selector, Ghostty config
bridge, fallback timers, and several session methods exist only to support the
temporary two-backend period. Keeping those after the last adapter is deleted
would preserve the migration scaffolding as permanent architecture.

The best target is:

- one DanTerm-owned terminal runtime that creates Swift terminal sessions and
  owns their bounded process teardown;
- the existing narrow `TerminalSession` protocol retained between the runtime,
  AppKit containers, and UI test shims;
- DanTerm JSON as the only live configuration authority;
- event-driven recovery only;
- no launch-time backend selection, Ghostty initialization, Ghostty resources,
  binary target, Zig toolchain, or Ghostty build/cache workflow.

Do not start the destructive part of the removal until the remaining Milestone
9 gates are closed. `plan-terminal-engine/14-roadmap.md` still has power and
performance plus sustained daily use unchecked. The roadmap explicitly makes
those prerequisites for Milestone 10.

## Cutover blockers found during this audit

### 1. The release bundle cannot run the default Swift backend

`resolveTerminalBackend(nil)` now selects Swift, and
`SwiftTerminalBackend.isReady` requires an executable at
`Contents/Helpers/PTYSessionBootstrap`. `dev-build.sh`, the viability harness,
and the benchmark harness build and copy that helper. `build-app.sh` does not.
The CI and release bundle-layout checks only assert the GUI and `danterm` CLI
helpers, so they do not catch the omission.

As written, a production bundle built from this branch reaches
`applicationDidFinishLaunching`, finds the Swift backend not ready, and
terminates. Fix this before removing the fallback:

- make `build-app.sh` build the `TerminalPTY` package's
  `PTYSessionBootstrap` product in release configuration and copy it into
  `Contents/Helpers`;
- make CI and release layout checks require it;
- sign the helper explicitly before the outer app in the stable release job;
- add a build-script contract test so dev and release bundle assembly cannot
  diverge again.

This is the highest-priority finding because existing Swift behavioral proof
mostly exercises custom dev/test bundles, not the canonical release bundle.

### 2. IPC paste semantics are not implemented by the Swift adapter

The core deliberately distinguishes top-level `pane.input` text (paste
semantics) from structured input text (typed semantics). The Swift controller
also has distinct APIs: `sendPaste` sanitizes control bytes and consults
bracketed-paste mode, while `sendText` sends raw UTF-8.

`SwiftTerminalSessionView.sendText` and `.sendInputText` both currently call
`controller.sendText`. Therefore the top-level IPC text path does not satisfy
the behavior promised in `Command.swift`; it bypasses safe paste and bracketed
paste. `pasteClipboard()` correctly calls `sendPaste`, which helps explain why
ordinary UI testing does not reveal the gap.

Add a failing adapter-level test and route `TerminalSession.sendText` to
`controller.sendPaste` before declaring the Swift backend self-sufficient.
Keep `sendInputText` on raw committed-text delivery. After removal, rename the
two APIs to describe behavior (`sendPaste` and `sendCommittedText`) so the old
Ghostty call names cannot cause this regression again.

### 3. Milestone 9 is still open

The roadmap has not yet closed:

- the full power/performance gate, including maintained sleep/wake evidence;
- the judgment that Swift is suitable for sustained daily use without a
  required Ghostty fallback.

The current tree has a WIP power-gate plan, but the roadmap is the canonical
status. Finish and record Milestone 9 before deleting the fallback. Otherwise
the removal itself destroys the escape hatch used to establish the daily-use
claim.

## Current dependency map

### Runtime and app wiring

- `app/main.swift` imports `GhosttyKit` and unconditionally calls
  `ghostty_init`, even when Swift is selected.
- `app/AppDelegate.swift` reads `DANTERM_TERMINAL_BACKEND`, constructs one of
  two backends, exposes an Open Ghostty Config menu item, and forwards app
  focus and screen changes through legacy hooks.
- `app/GhosttyApp.swift`, `app/TerminalView.swift`,
  `app/GhosttyBindingAction.swift`, and `app/GhosttyText.swift` are the direct
  adapter. They total about 1,600 lines.
- `app/TerminalBackend.swift` mixes the durable per-session contract with the
  temporary process-wide backend contract. The latter exposes Swift no-ops or
  Ghostty-only values: `preferences`, `configFilePath`, `onEvent`,
  `recoveryScheduling`, `setAppFocused`, and `reloadConfig`.
- `TerminalSession.setDisplayID` and `.setScrollbarEnabled` are Swift no-ops.
  `syncSessionDisplayID` exists for Ghostty's display link; Swift only needs a
  backing/geometry refresh after a screen change.
- `Command.setAppFocus` has no Swift side effect. Model app-active state still
  matters for notification and focus policy, but the command to the backend can
  disappear.
- `AppRuntime.startEnrichedCheckpointTimer` exists only to start the periodic
  Ghostty fallback. Swift recovery is already mutation-driven.

### Core model and preferences

DanTerm JSON already owns `defaultTheme`, `fontSize`, `fontFamily`, and
`remoteTheme`, but the model still maintains a second, ephemeral
`GhosttyPrefs` snapshot. That duplication drives:

- `committedGhosttyPrefs`;
- `ghosttyConfigGeneration`;
- `ghosttyConfigReloaded` and `ghosttyPrefsRefreshed` messages;
- `preferencesOpened(ghostty:...)`;
- Ghostty-named projection fields and UI controls;
- a generation field in `PaneConfigKey` whose sole purpose is forcing a
  re-layer after Ghostty base-config reload.

Delete the duplicate authority. Open preferences directly from
`model.config`, compare the draft to `model.config`, and reset theme/font size
from `model.config`. `PaneConfigKey` then needs only theme, font size, and
resolved font family. Reload Config should reload only DanTerm JSON.

Several pure helpers and their tests become unreachable when the legacy
adapter goes away:

- `BackingGeometry` (Ghostty IOSurface scale/size adapter);
- `ClipboardWriteItems` and `app/ClipboardWriteSurface.swift` (libghostty MIME
  callback normalization; Swift OSC 52 has its own bounded text path);
- `CopyOnSelect` (Ghostty config behavior);
- `TickCoalescer` (`ghostty_app_tick` mailbox behavior);
- `UrlResolution` (Ghostty open-url fallback; Swift links use TerminalCore's
  safe hyperlink policy).

`ScrollbarMath` is not legacy and must stay: `ScrollableTerminalView` uses it
for the Swift engine's native scrollback UI.

### Build, packaging, and CI

- `Package.swift` declares the `GhosttyKit` binary target and links it into the
  app.
- `build-app.sh` and `dev-build.sh` refuse to build without the xcframework.
- `scripts/bundle-theme-resources.sh` packs DanTerm's tracked JSON catalog, then
  separately requires and copies raw Ghostty themes solely for the legacy
  backend.
- CI build and release-validation jobs load the Ghostty version, restore/cache
  the xcframework and raw themes, install Nix on cache misses, and build
  GhosttyKit.
- the stable release does the same and preserves the cache paths through its
  second checkout;
- `.github/workflows/cache-ghosttykit.yml` exists only to warm this cache;
- `build-lib.sh`, `.ghostty-version`, `scripts/load-ghostty-version.sh`, and
  their tests are entirely legacy;
- `build.zig.zon.nix` is not referenced outside the old Ghostty build material;
- the `zig-overlay` flake input and `zig_0_15` package export exist only for
  GhosttyKit. Remove them and update `flake.lock`. Keep Nix itself where other
  CI, packaging, shell-integration, and release-note/hash work still uses it.
- Metal, MetalKit, IOKit, IOSurface, Carbon, and `libc++` app linker settings
  have no use outside the legacy adapter in the current source search. Remove
  them and let a clean link prove the smaller set. Cocoa, CoreText, and
  UniformTypeIdentifiers remain live. QuartzCore also has no direct current
  source use and should be tested for removal rather than assumed necessary.

The ignored framework is about 133 MiB locally, raw themes about 1.9 MiB, and
`.ghostty-src` about 811 MiB. Those are local/cache sizes, not shipped size, but
their removal substantially reduces checkout provisioning and cold CI setup.

The current `.gitignore` ignores all of `lib/*` and then allowlists every source
package because the generated Ghostty outputs also live under `lib/`. Once
those outputs are gone, remove that broad rule and its package allowlist. This
prevents a future source package from being silently untracked.

### Tooling and tests

- `scripts/terminal-characterization.sh` and its driver are an opt-in
  real-Ghostty capture path. The checked-in characterization fixture and the
  TerminalCore replay test are durable evidence; the producer can be deleted
  after cutover, as the migration plan explicitly says permanent parity testing
  is unnecessary after Ghostty removal.
- `scripts/terminal-benchmark.sh` still accepts `swift|ghostty` and emits a
  Ghostty-specific result shape. Make the harness Swift-only. Preserve checked-
  in historical measurements and research prose, but establish the cutover
  commit as the oldest supported live benchmark baseline instead of teaching
  new tooling to provision old Ghostty artifacts forever.
- `scripts/terminal_benchmark_snapshot.py` special-cases the framework and raw
  themes as prerequisites for comparison worktrees; that can disappear with
  the same baseline policy.
- `scripts/terminal-recording-schema-audit.py`, the fixture directory named
  `Fixtures/ghostty`, and `GhosttyInspectionRecoveryReplayTests` describe the
  provenance of retained evidence. Keep them. Renaming historical evidence
  would make it less clear, not less dependent.
- `terminal-backend-boundary-lint.sh` still has value as a Swift engine import
  boundary, but its Ghostty allowlist and theme-path exception can be deleted;
  rename the lint around the terminal engine/session boundary.
- Remove the build-lib, version-loader, legacy theme-bundling, Ghostty
  characterization, Ghostty-only clipboard, backing-geometry, copy-on-select,
  tick-coalescer, URL-resolution, backend-selection, and backend-event tests.
  Replace them with the cutover proofs below rather than merely shrinking the
  gate.

### Themes

DanTerm's runtime theme catalog is already in the desired state: builds pack
tracked `themes/*.json`, and runtime code reads that DanTerm-owned schema. Raw
`lib/ghostty-themes` is copied only for the old adapter and should be removed
from worktree provisioning and bundle assembly.

The explicit catalog updater consumes the iTerm2-Color-Schemes project's
`ghostty-themes.tgz` release asset as an import format. That is not a runtime,
build, or libghostty dependency, and the committed JSON deliberately breaks
format compatibility. Keep the importer and its provenance unless the upstream
project offers an equally complete, stable source format. Optionally rename
the script to `import-iterm2-themes.py` so its ownership is clear; do not spend
cutover risk on rewriting a working offline importer merely to remove a word.

### Documentation

Update active guidance and product text:

- `README.md`, `AGENTS.md`, `agent-docs/build-details.md`,
  `agent-docs/worktree-development.md`, `agent-docs/reference-sources.md`,
  `docs/ci.md`, `integrations/danterm/SKILL.md`, and the roadmap;
- delete `docs/upgrading-ghostty.md` and the cache-warmer workflow;
- remove `build-lib.sh` setup and backend-selection examples;
- update comments in runtime/core files that describe Ghostty calls rather than
  current product semantics.

Do not mass-rewrite accepted ADRs, implementation plans, research reports,
compatibility citations, fixture provenance, or theme names from the imported
catalog. Those are historical records or accurate source attribution. Update
an accepted document only where it presents stale current instructions; add a
short supersession note where necessary instead of rewriting the decision that
was true at the time.

## Recommended implementation shape

### Phase 0: close the gate and add cutover proofs

1. Finish Milestone 9 and record its evidence.
2. Fix production bundling/signing of `PTYSessionBootstrap` and add a clean
   release-bundle contract test.
3. Write the failing IPC paste behavior test, fix the Swift adapter, and retain
   distinct paste vs typed-input APIs.
4. Run the full test gate, UI gate, optimized app build, and a production-shaped
   Swift smoke launch before deleting Ghostty.

### Phase 1: remove runtime coexistence

1. Delete unconditional `ghostty_init`, backend environment selection, and the
   four legacy adapter files.
2. Remove `TerminalBackendKind`, selection errors, process-wide backend events,
   and their core translations.
3. Replace the process-wide `TerminalBackend` protocol with one concrete
   DanTerm terminal runtime (a rename of `SwiftTerminalBackend`) that creates
   sessions and owns termination. Keep `TerminalSession` as the narrow,
   testable app boundary.
4. Remove Swift no-op session methods, backend focus commands, display-link
   routing, Ghostty scrollbar fan-out, and periodic recovery selection.
5. Rename `SwiftTerminalSessionView` and `SwiftTerminalBackend` only after the
   parallel types are gone, so the rename is mechanical and reviewable.

### Phase 2: collapse configuration to one authority

1. Delete Ghostty config menus/callbacks and make Reload Config mean DanTerm
   JSON only.
2. Remove `GhosttyPrefs`, committed Ghostty state, Ghostty generation state,
   and the associated messages/projections/tests.
3. Rename theme UI identifiers to product terms and compare/reset all draft
   fields against `DanTermConfig`.
4. Delete legacy-only pure helpers and UI clipboard glue once reachability
   searches are empty.

This should be a separate commit from Phase 1: runtime deletion is easy to
audit against imports and symbols, while config collapse changes model/update
behavior and deserves focused tests.

### Phase 3: remove build and resource dependencies

1. Remove the binary target, unused linker settings, xcframework/raw-theme
   preflight checks, and raw-theme bundle copy.
2. Remove Ghostty version/build scripts, pins, Zig artifacts/input/export,
   cache workflow, and their test-gate entries.
3. Make worktree provisioning link only `references` and simplify `.gitignore`.
4. Simplify CI and release jobs, then build from a clean checkout with no
   `.ghostty-src`, xcframework, or raw-theme directory present.

### Phase 4: retire migration-only tools and update docs

1. Remove the real-Ghostty characterization producer while retaining its
   fixture and replay.
2. Make live terminal benchmarks Swift-only and document the cutover baseline
   boundary.
3. Simplify/rename the terminal boundary lint.
4. Update current docs and mark Milestone 10 complete only after the clean
   build, full test gate, UI gate, and smoke launch pass.

## Acceptance checks

The cutover should not rely on an `rg ghostty` count: accurate historical and
provenance mentions will remain. Use behavior and dependency checks instead.

- A clean checkout with none of `.ghostty-src`, `lib/GhosttyKit.xcframework`,
  or `lib/ghostty-themes` can run the normal test gate and build the dev and
  release app bundles.
- The release bundle contains executable and correctly signed `DanTerm`,
  `danterm`, and `PTYSessionBootstrap` binaries.
- A production-shaped bundle launches, creates a pane, runs a command through
  the PTY, renders output, and exits cleanly with no backend environment value.
- Top-level IPC text uses safe/bracketed paste; structured input text remains
  typed raw text.
- Preferences open/save/reset and live theme/font application use only
  DanTerm JSON state.
- Recovery remains mutation-driven and becomes quiescent after durability;
  there is no startup periodic fallback timer.
- App activation, window screen changes, visibility, pane teardown, and app
  termination retain their Swift behavioral proofs after no-op legacy commands
  are removed.
- The app target has no `GhosttyKit` import or binary dependency and no Ghostty
  symbols in the linked product.
- CI and stable release workflows contain no Ghostty build/cache step and the
  cache-warmer workflow is gone.
- The full `just test` and `just test-ui` gates pass, followed by the Milestone
  9 power/daily-use checks on the exact post-removal build.

## Expected simplification

The immediately identifiable deletion set is over 4,200 lines across the
legacy adapter, legacy-only helpers/tests, Ghostty characterization producer,
build scripts/tests, cache workflow, upgrade guide, and Zig dependency file.
That estimate excludes the additional model, runtime, CI, documentation, and
benchmark simplifications above.

The more important reduction is conceptual: one session implementation, one
config authority, one recovery policy, one launch path, one theme bundle, and
one terminal vocabulary. That is the architecture the migration plans intended
once temporary coexistence ended.
