# Removing libghostty, and what it unlocks

Scratch notes, 2026-08-06. Two questions: (a) what is the best way to execute
Milestone 10 ("Remove libghostty"), and (b) what in DanTerm's code exists only
because libghostty was there, and should be simplified or re-architected once
it is gone.

Not a plan file. Findings, with a proposed slicing at the end.

Everything below was checked against the tree, not recalled. File references
use `path:line` for tracked DanTerm files (they are ours and will move with the
change) and `file#identifier` for refetchable reference trees.

## Status: this migration is independent of Milestone 9

The roadmap orders Milestone 10 after Milestone 9, but this migration does not
take Milestone 9's power/performance or daily-use criteria into scope. Those
criteria neither block nor supply acceptance conditions for the tasks below.
The cutover is gated only by requirements created directly by making Swift the
sole backend: the production bundle must launch Swift sessions, the normal and
UI gates and release-shaped smoke must pass, and no shipped path may retain a
Ghostty dependency.

There is one release-shaped cutover blocker. Swift is the default backend and
`SwiftTerminalBackend.isReady` requires
`Contents/Helpers/PTYSessionBootstrap`, but `build-app.sh` neither builds nor
bundles that executable. Dev, viability, and benchmark bundles do. The current
CI/release layout checks assert only the GUI and `danterm` CLI helpers, so a
production bundle can pass packaging checks and then terminate during
`applicationDidFinishLaunching` because its default backend is not ready.

One framing decision worth making explicitly up front: **removing libghostty as
a linked dependency is not the same as removing Ghostty as a reference source.**
`.ghostty-src/` is cited by ~20 tracked docs, by `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`,
and is in the skip-list of both parity lints (`scripts/kitty-parity-lint.py:49`,
`scripts/alacritty-parity-lint.py:73`). It should survive; only the xcframework
build should die. See "Where the Ghostty reference source goes" below.

## What actually depends on libghostty today

### Runtime (app target)

Backend selection is one env var read at launch:

- `app/AppDelegate.swift:35-47` -- reads `DANTERM_TERMINAL_BACKEND`, resolves
  through `resolveTerminalBackend`, and constructs one of two backends.
- `lib/DanTermCore/Sources/DanTermCore/TerminalBackendBoundary.swift:29-47` --
  `TerminalBackendKind`, `TerminalBackendSelectionError`, `resolveTerminalBackend`.
  Swift is already the default; Ghostty is explicit opt-in only.
- `app/main.swift:65` -- `ghostty_init` before anything else. The only reason
  `main.swift` imports GhosttyKit.
- `Command.setAppFocus` still forwards app activation to the process backend,
  but `SwiftTerminalBackend.setAppFocused` is a no-op. The model's app-active
  state remains real notification/focus policy; only this backend command is
  legacy.

Files that exist *only* for the Ghostty backend and can be deleted outright:

| File | Lines | Note |
|---|---|---|
| `app/GhosttyApp.swift` | 553 | the backend itself |
| `app/TerminalView.swift` | 1039 | the Ghostty session view |
| `app/GhosttyBindingAction.swift` | 17 | |
| `app/GhosttyText.swift` | 14 | |
| `app/ClipboardWriteSurface.swift` | 39 | multi-MIME clipboard write; Swift writes a plain string |
| `lib/DanTermCore/.../ClipboardWriteItems.swift` | 26 | only consumer is `GhosttyApp` |
| `lib/DanTermCore/.../TickCoalescer.swift` | 31 | coalesces `ghostty_app_tick`; no Swift analogue |
| `lib/DanTermCore/.../BackingGeometry.swift` | 26 | only consumer is `TerminalView` |
| `lib/DanTermCore/.../CopyOnSelect.swift` | 10 | reads Ghostty's `copy-on-select` enum tag |
| `lib/DanTermCore/.../UrlResolution.swift` | 15 | Ghostty's `OPEN_URL` action payload |

Plus their tests (`ClipboardWriteItemsTests` 77, `TickCoalescerTests` 102,
`BackingGeometryTests` 110, `CopyOnSelectTests` 50, `UrlResolutionTests` 63,
`tests-ui/ClipboardWriteTests.swift` 124). About **2,300 lines of app/core code
plus ~530 lines of tests**, before counting build and script deletions.

I verified each of those five core helpers has exactly one non-test consumer and
it is a Ghostty file. Two caveats:

- `ScrollbarMath.swift` looks Ghostty-flavored (its doc comment says "sent to
  ghostty's scroll_to_row action") but is live for the Swift backend via
  `app/ScrollableTerminalView.swift:145,155,182`. **Keep**; fix the comment.
- `UrlResolution.swift` is safe to delete only because the Swift path has its
  own, *stricter* policy: `SwiftTerminalSessionView.safeWebURL`
  (`app/SwiftTerminalSessionView.swift:1089-1096`) admits `http`/`https` only,
  where `resolveOpenUrl` also resolved bare `~`-paths to `file:`. That is a
  deliberate narrowing (doc 08 / the "safe web links" slice), not an oversight
  -- but it *is* a user-visible behavior difference and should be named as such
  in the removal commit rather than discovered later. `expandTilde` itself lives
  in `Model.swift` and is used elsewhere; only `UrlResolution.swift` goes.

### Build

- `Package.swift:17-20` -- the `GhosttyKit` binary target, and its use in the
  `DanTerm` target's dependencies.
- `Package.swift:48-58` -- linker settings. **I grepped every source under
  `app/` and `lib/*/Sources`: nothing imports Metal, MetalKit, IOSurface,
  IOKit, or Carbon, and the `kVK_*` constants are hand-defined in
  `ModelOperations.swift:1028-1031` rather than pulled from Carbon.** So
  `Metal`, `MetalKit`, `IOKit`, `IOSurface`, `Carbon`, and `libc++` are all
  there for GhosttyKit's transitive needs and should come out with it.
  `CoreText`, `Cocoa`, and `QuartzCore` stay -- live `CALayer`/`CATransaction`
  use remains in `SwiftTerminalSessionView`, `PaneWrapperView`, `SwitcherPanel`,
  and `AppRuntime`.
- `build-lib.sh` (219), `scripts/load-ghostty-version.sh` (45), `.ghostty-version`,
  `build.zig.zon.nix`.
- `flake.nix` -- the patched-Zig overlay (`flake.nix:132-153`) exists solely so
  `build-lib.sh` can compile Ghostty against the macOS 26.4+ SDK. That whole
  block, and the `terminal-workflows`-adjacent dev shell plumbing around it,
  gets much smaller.
- `build-app.sh:22`, `dev-build.sh:46` -- the "xcframework not found" preflight.
  Separately, `build-app.sh` must first reach parity with `dev-build.sh` by
  building `TerminalPTY`'s `PTYSessionBootstrap` in release configuration and
  copying it to `Contents/Helpers`. CI/release bundle checks must require it,
  and the stable release must sign it before signing the outer app. This is a
  cutover prerequisite, not cleanup that may wait until after Ghostty is gone.
- `scripts/provision-worktree.sh:21-22` -- links `lib/GhosttyKit.xcframework`
  and `lib/ghostty-themes` into worktrees. Both entries go; worktree
  provisioning gets meaningfully cheaper, which matters for the parallel-worktree
  workflow this branch just set up.
- `.gitignore` currently ignores all `lib/*` and then allowlists every source
  package solely because the two generated Ghostty outputs live under `lib/`.
  Once those outputs are gone, delete the broad ignore and allowlist so a future
  source package cannot be silently left untracked.
- `scripts/bundle-theme-resources.sh:31-45` -- copies raw Ghostty-format themes
  into `Contents/Resources/ghostty/themes` "for the legacy backend". The runtime
  catalog is already the committed JSON in `themes/`. Delete the legacy half;
  the app bundle stops shipping a second copy of every theme.
- CI: `.github/workflows/cache-ghosttykit.yml` deletes entirely; `ci.yml` loses
  two "Load Ghostty version" + two "Cache/Build GhosttyKit" step pairs (lines
  ~127-181, 231); `release-stable.yml` loses one (lines 29-55). This is the
  single biggest CI wall-clock and cache-complexity win in the change.

Note `scripts/import-ghostty-themes.py` is **not** a libghostty dependency
despite the name -- it downloads a pinned iTerm2-Color-Schemes release archive
(which happens to be named `ghostty-themes.tgz`) and converts it to DanTerm
JSON. Keep it; consider renaming to `import-themes.py` in the lexicon pass.

### Test gate

Steps in `scripts/run-test-suite.sh` that go away or shrink:

- `./scripts/tests/load-ghostty-version_test.sh` (74) -- delete
- `./scripts/tests/build-lib-contract_test.sh` (140) -- delete
- `./scripts/tests/build-lib-fetch_test.sh` (76) -- delete or repoint (see below)
- `./scripts/tests/build-lib-stale-guard_test.sh` (62) -- delete
- `./scripts/tests/terminal-characterization-harness_test.sh` -- delete with the
  harness
- `./scripts/terminal-backend-boundary-lint.sh` + its test -- **shrinks, does not
  disappear.** Its first loop (GhosttyKit-import allowlist) and third loop
  (Ghostty theme paths) become dead; its second loop -- "Swift terminal engine
  imports only in the adapter allowlist" -- is the one that still earns its
  keep, and arguably matters *more* after removal, since it is the only thing
  stopping engine types from leaking across the app boundary.
- `scripts/terminal-characterization.sh` (685) + `terminal-characterization-driver.py`
  (116) -- these drive a *real Ghostty build* to record pane-read/recovery
  behavior. Their job is done: Milestone 1's characterization criterion is
  checked, and the recorded corpus is committed. **Delete the recorders, keep the
  fixtures.** `lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/ghostty/inspection-recovery.json`
  replays through `TerminalCore` with no libghostty involved
  (`GhosttyInspectionRecoveryReplayTests.swift`), so it stays a gating headless
  regression test forever. Same for `Fixtures/libvterm/`.
- `scripts/terminal-benchmark.sh` -- drop the `ghostty` arm (lines 32-49, 204,
  312, 352-374). The `finalDraw: {available: false, reason:
  "unavailable-for-ghostty-backend"}` branch and the whole two-arm shape
  collapse to one backend.
- `scripts/terminal_benchmark_snapshot.py` -- remove the special provisioning
  of `lib/GhosttyKit.xcframework` and `lib/ghostty-themes`. Treat the cutover
  commit as the oldest supported live comparison baseline instead of carrying
  Ghostty build prerequisites in current benchmark tooling forever; keep
  historical saved measurements and research prose.
- `scripts/dev-slot-launcher.py:28` and `dev-build-configuration-contract_test.sh`
  -- stop forwarding `DANTERM_TERMINAL_BACKEND`.

### Docs

`docs/upgrading-ghostty.md` retires. `AGENTS.md` needs edits in Boundaries,
Build, and the "Read before you touch it" table.
`agent-docs/build-details.md`, `agent-docs/reference-sources.md`,
`agent-docs/worktree-development.md`, `docs/ci.md` all need passes. Historical
`plans/impl/*` and `docs/research/*` should **not** be rewritten -- they are a
record of what was true then.

## Where the Ghostty reference source goes

This is the one part of removal that needs a real decision rather than a
deletion. `.ghostty-src/` is currently materialized by `build-lib.sh fetch`,
which is a mode of the script we are deleting.

Options:

1. **Add `ghostty` to `scripts/fetch-references.py`'s inventory** and delete
   `build-lib.sh` whole. This is my recommendation. The reference mechanism
   already handles pinned revisions, `--list`, and per-name fetch for 21 other
   trees (libvterm, kitty, wezterm, xterm, vte, tmux, foot, iterm2, the shells,
   Darwin, swift-collections). Ghostty is conspicuously the one reference *not*
   using it, purely for the historical reason that its checkout doubled as a
   build input. Once it stops being a build input, that exception has no
   rationale. `.ghostty-src/` becomes `references/ghostty/`, the `.gitignore`
   entry moves, and the two parity lints' skip-lists lose an entry (they already
   skip `references/`).
2. Keep `build-lib.sh fetch` as a one-mode script. Cheaper commit, but leaves a
   file named "build-lib" that builds nothing and a second reference-fetching
   mechanism to maintain.

Option 1 costs one extra migration step: ~20 tracked docs cite `.ghostty-src/`
paths, and `agent-docs/reference-sources.md` documents the layout. That is a
mechanical `sed`-able rewrite for the docs that are still normative
(`AGENTS.md`, `agent-docs/reference-sources.md`, `Terminal.swift`, the two
parity lints); historical plans and research docs keep their old paths, same as
any other stale path in an archived record.

## Simplification unlocked, ranked by value

### 1. Collapse the two-backend abstraction (biggest structural win)

`app/TerminalBackend.swift` defines two protocols that will have exactly one
conformer each. Look at what the Swift backend actually does with the
`TerminalBackend` half (`app/SwiftTerminalBackend.swift:31-38, 105-106`):

```
var preferences: GhosttyPrefs { GhosttyPrefs(theme: nil, fontSize: nil) }  // always nil
var configFilePath: String? { nil }                                        // always nil
var recoveryScheduling: TerminalRecoveryScheduling { .eventDriven }        // always
func setAppFocused(_ focused: Bool) {}                                     // no-op
func reloadConfig() {}                                                     // no-op
var onEvent: ((TerminalBackendEvent) -> Void)?                             // never called
```

Six of nine members are constants or no-ops. The protocol reduces to `isReady`,
`createSession`, `terminateForApplicationExit` -- at which point it should stop
being a protocol and `AppDelegate` should just hold a `SwiftTerminalBackend`.

Consequences that fall out:

- **`TerminalBackendEvent` deletes entirely.** All three cases
  (`configReloaded`, `configChanged(prefs:scrollbarEnabled:)`, `quitRequested`)
  are emitted only from `GhosttyApp.swift:368,434,438,455`. With them go
  `Msg.ghosttyConfigReloaded`, `Msg.ghosttyPrefsRefreshed`,
  `AppModel.ghosttyConfigGeneration`, and the `terminalMessage(for:)` overload
  in `TerminalBackendBoundary.swift:85-95`. `Msg.requestQuit` itself stays:
  AppDelegate sends it from the Quit menu, application termination safety net,
  and related lifecycle paths (`AppDelegate.swift:689,767,796`). Only the
  Ghostty backend-event route to the product message disappears.
- **`TerminalRecoveryScheduling` deletes.** `AppRuntime.swift:1189` and `:1215`
  become unconditional: mutation-driven enriched checkpoints, always. The
  periodic fallback timer and `enrichedCheckpointInterval = 600.0` go with it --
  and note that interval's comment (`AppRuntime.swift:208`): *"Slowed from 60s
  to 10min until the libghostty memory leak is fixed"* (issue #31). That issue
  can be closed, and if any periodic tier survives, its interval should be
  re-derived rather than inherited.
- **Keep `TerminalSession` as the durable DanTerm/AppKit boundary.** It still
  decouples pane containers and UI test doubles from the terminal controller;
  one production conformer is not by itself a reason to erase that boundary.
  Audit its default implementations individually rather than deleting all of
  them as backend fallbacks. `readPrimaryHistoryTail` and
  `primaryHistoryTailReader` can become Swift-required behavior, but flight
  recording and pane-tape follow remain optional when the selected app bundle
  does not enable recording, independent of how many terminal backends exist.
- **Two no-op session members delete**: `setDisplayID` and `setScrollbarEnabled`
  are `{}` in the Swift session (`SwiftTerminalSessionView.swift:564-565`).
  `setDisplayID` takes `AppRuntime.syncSessionDisplayID()` (`:492-508`) with it,
  including its "mirror Ghostty's screen-change path" async nudge -- though the
  `refreshBackingProperties()` half of that method is live, so this needs a
  careful read rather than a blind delete.
- `paneVisibility` (`AppRuntime.swift:154`) is documented as "last libghostty
  occlusion value pushed". `setVisible` is real for the Swift backend, so the
  cache stays -- just the comment and the framing change.

### 2. Delete the `GhosttyPrefs` shadow config

This is the highest-value *correctness* simplification, because right now
DanTerm carries two representations of the same two settings.

`DanTermConfig` (`lib/DanTermCore/.../DanTermConfig.swift:9-25`) already owns
`defaultTheme`, `fontSize`, `fontFamily`, `remoteTheme`, `alertClearMode`.
`GhosttyPrefs` (`Model.swift:166-169`) owns `theme` and `fontSize` -- as
*strings*, read out of the Ghostty config file. Under the Swift backend it is
always `(nil, nil)`, and `Update.swift` keeps a hand-written mirror in sync in
three separate places (`:565-568`, `:698-701`, plus `.ghosttyPrefsRefreshed` at
`:660-666`) so the preferences panel's dirty/reset rows have something to
compare against.

After removal, `committedGhosttyPrefs` is just "the saved values of
`config.defaultTheme` and `config.fontSize`". The right shape is for
`PreferencesDraft`'s dirty/reset logic to compare against `model.config`
directly, exactly as it already does for `alertClearMode`, `remoteTheme`, and
`fontFamily` (`Update.swift:606-655`, `ModelOperations.swift:710-714`). That
deletes:

- `struct GhosttyPrefs`
- `AppModel.committedGhosttyPrefs`
- `Msg.ghosttyPrefsRefreshed`, and the `ghostty:` label on `Msg.preferencesOpened`
- the three mirror-assignment sites in `Update.swift`
- the string round-trip through `configFontSizeText` for the draft's committed
  side (the draft itself still needs raw text -- that part is legitimate)

and makes `PreferencesProjection`'s `ghosttyThemeText` / `ghosttyThemeDirtyLabel`
(`Projections.swift:44-100`) plain `themeText` / `themeDirtyLabel`.

### 3. Reconsider the bespoke `tests-ui` harness

`test-ui.sh` is a hand-maintained list of ~60 source paths compiled by a single
raw `swiftc` invocation, plus `tests-ui/SidebarViewTestShim.swift` and
`SwiftTerminalSessionViewTestShim.swift` which stub `AppRuntime`, `TerminalView`,
and friends. The plans are explicit about why it exists:
`plans/impl/2026-06-11-theme-browser-ui-harness.md:5` calls it "the
**GhosttyKit-free** UI harness", and each view had to be individually "promoted"
into it.

Once the app target has no binary framework dependency, the premise changes.
Worth investigating (I did not prove this out): can `tests-ui` become a normal
SwiftPM test target depending on `DanTerm` the way `app-tests` already does,
with the WindowServer requirement handled by keeping it out of the gate list
rather than by a separate build? If yes, that deletes the file list, the shims,
the "promotion" ritual for every new view, and `scripts/tests/test-ui-harness_test.sh`.
If no, the reason should be written down, because right now the only recorded
reason is the one that is about to stop being true.

Note the harness shim class is literally named `TerminalView`
(`tests-ui/SidebarViewTestShim.swift:46`) -- that name frees up on removal.

### 4. Lexicon pass: finish what the pane/session rename started

Commit `8eb493de` just did "adopt pane and session terminology". A de-Ghostty
pass is the natural sequel, and it is cheap to do as one mechanical commit
*after* the deletions (so it does not touch code that is about to vanish):

- `AppDelegate.swift:279` -- the "Open Ghostty Config" menu item and its
  `openGhosttyConfig` action (`:592`), `MenuCommandPolicy.swift:15,29`. This
  frees the Cmd-Opt-, shortcut, which should probably become "Open DanTerm
  Config" -- there is already an `openDanTermConfig` in the runtime.
- `PreferencesPanel.swift` -- ~12 `ghosttyTheme*` identifiers for what is now
  just the theme field.
- `ThemeBrowserView.swift:62,218` -- "reverting to the user's Ghostty config" is
  now false; Reset reverts to the DanTerm catalog default.
- `AppRuntime.swift:204` -- "Matches Ghostty's title coalesce interval" for
  `reconcileCoalesceInterval = 0.075`. Keep the number, restate the rationale on
  our own terms (or measure it).
- `RemoteThemePickerSheet.swift:2`, `LinkPreviewView.swift:10`,
  `TerminalLaunchEnvironment.swift:23`, `Command.swift:18-29`,
  `Msg.swift:96`, `Update.swift:709` (`// MARK: - Ghostty Callbacks` for what
  are now generic session events), `Projections.swift:10`,
  `ModelOperations.swift:11`, `Debouncer.swift:7`, `ScrollbarMath.swift:1,28`,
  `Model.swift:98`.
- `lib/DanTermCore/Tests/.../UpdateGhosttyTests.swift` (643 lines) is **not**
  Ghostty-specific -- it pins session-event `Msg` routing (bell, notification,
  metadata, creation-failure cleanup). Rename to `UpdateSessionEventTests`, keep
  every test.
- `scripts/import-ghostty-themes.py` -> `import-themes.py`, and the
  `lib/ghostty-themes` cache path.

### 5. Smaller items

- `app/main.swift` loses `ghostty_init` and its GhosttyKit import, and becomes a
  plain AppKit entry point (~75 lines of the current 142 are restore/init-file
  resolution that stays).
- `TerminalSessionRequest` (`TerminalBackend.swift:56-66`) currently passes
  `themeName`/`fontSize`/`fontFamily` per session because Ghostty owned its own
  config. With one backend these could be read from `DanTermConfig` at the
  session-creation seam instead of being threaded through a request struct --
  worth considering, though the per-pane theme override
  (`PaneModel.theme`, remote theme) means the parameter is not purely redundant.
- The `#if DANTERM_TERMINAL_CHARACTERIZATION` flag stays (the Swift viability
  and capture-API gates use it), but its Ghostty-recording half in
  `SwiftTerminalBackend.writeRecording` should be re-read for whether it is
  still earning its conditional compilation.

## One real divergence found while researching

**IPC `text` input lost paste semantics under the Swift backend.**

`Command.sendText` is documented (`Command.swift:18-21`) as the paste path: it
"strips control bytes and applies bracketed-paste mode if active", and is what
direct IPC callers reach via the top-level `text` field.
`Command.sendInputText` is the structured-input path that deliberately
*bypasses* that. Under Ghostty they were genuinely different calls --
`ghostty_surface_text` vs `ghostty_surface_key` with keycode 0
(`TerminalView.swift:813-833`).

Under the Swift backend both map to the same raw call:

```
func sendText(_ text: String)      { controller.sendText(text) }   // :543
func sendInputText(_ text: String) { controller.sendText(text) }   // :547
```

`TerminalPaneSessionController` *does* have the right method --
`sendPaste(_:)` (`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift:491`),
which sanitizes and consults bracket mode on the owner queue -- and
`pasteClipboard()` correctly uses it (`SwiftTerminalSessionView.swift:744-747`).
The IPC `text` path does not.

This is a live behavior difference on the current default backend, not a
removal-time concern, and it should be resolved *before* the two commands are
collapsed on the grounds of "they do the same thing now" -- because they do the
same thing only by accident. Either wire `sendText` to `controller.sendPaste`
(restoring the documented contract), or decide the contract changed and update
`integrations/danterm/SKILL.md`, which is the source of truth for the CLI
surface. My read: it is a bug; the doc comment and the CLI contract both still
promise paste semantics.

## Tasks

Ordered. Two waves: erase Ghostty from the tree, then spend the freedom it buys.
Each item is meant to be independently green -- nothing here needs a flag day,
because the Swift backend is already the default. Detail for each lives in the
sections above.

### Wave 0 -- independent, do whenever

- [ ] **Fix the IPC `text` paste divergence.** Point
      `SwiftTerminalSessionView.sendText` at `controller.sendPaste` so the
      documented contract (control-byte stripping + bracketed paste) holds
      again, or change the contract and update `integrations/danterm/SKILL.md`.
      Write the failing adapter-level proof first, and keep structured input
      text on raw committed-text delivery. Must land *before* task 11
      reconsiders the two commands. See "One real divergence found while
      researching".
- [ ] **Make the production bundle capable of launching Swift sessions.** Add a
      failing build-script contract first, then make `build-app.sh` build and
      bundle release `PTYSessionBootstrap`; require it in CI and stable-release
      layout checks; sign it before the outer app; and smoke a production-shaped
      bundle through pane creation, one PTY command, output, and clean exit.
      This must land before the Ghostty backend is deleted.

### Wave 1 -- remove Ghostty

- [ ] **1. Retire the Ghostty characterization recorder.** Delete
      `scripts/terminal-characterization.sh` (685),
      `terminal-characterization-driver.py` (116), the harness test, and the
      gate step. Keep every fixture and `GhosttyInspectionRecoveryReplayTests`
      -- they replay through `TerminalCore` with no libghostty involved.
- [ ] **2. Drop the Ghostty benchmark arm.** `terminal-benchmark.sh` becomes
      single-backend (lines 32-49, 204, 312, 352-374), and
      `terminal_benchmark_snapshot.py` stops provisioning Ghostty artifacts.
      Document the cutover commit as the oldest supported live benchmark
      baseline while retaining historical results.
- [ ] **3. Delete the backend selection seam and the Ghostty adapter.**
      `GhosttyApp`, `TerminalView`, `GhosttyBindingAction`, `GhosttyText`,
      `ClipboardWriteSurface`, the five dead core helpers
      (`ClipboardWriteItems`, `TickCoalescer`, `BackingGeometry`,
      `CopyOnSelect`, `UrlResolution`) and their tests, `TerminalBackendKind` /
      `resolveTerminalBackend`, and `ghostty_init` in `main.swift`. Leave the
      now-single-conformer process boundary for task 7 so this deletion commit
      remains mechanically auditable. Largest commit; mostly `git rm`. Name the
      link-opening narrowing
      (`resolveOpenUrl` -> `safeWebURL`) in the message.
      `dev-slot-launcher.py` and `dev-build-configuration-contract_test.sh`
      stop forwarding or asserting `DANTERM_TERMINAL_BACKEND` in this same
      commit, alongside the selector they exercise.
- [ ] **4. Delete the build dependency.** `GhosttyKit` binary target plus the
      six now-unused linked frameworks (`Metal`, `MetalKit`, `IOKit`,
      `IOSurface`, `Carbon`, `libc++`); `build-lib.sh`,
      `load-ghostty-version.sh`, `.ghostty-version`, `build.zig.zon.nix`, the
      flake's patched-Zig overlay and lock entries, the two build-script preflights,
      `provision-worktree.sh:21-22`, the legacy half of
      `bundle-theme-resources.sh`, the broad `lib/*` `.gitignore` plus package
      allowlist, and all four build-lib/version gate tests. Preserve the newly
      added release `PTYSessionBootstrap` build while removing Ghostty setup.
- [ ] **5. Simplify CI.** Delete `.github/workflows/cache-ghosttykit.yml`; strip
      the version/cache/build step groups from `ci.yml` and
      `release-stable.yml`. Keep the non-Ghostty Nix uses, and retain the new
      `PTYSessionBootstrap` layout and nested-code signing assertions.
- [ ] **6. Move the Ghostty reference into `fetch-references.py`.**
      `.ghostty-src/` -> `references/ghostty/`; update the normative citations
      (`AGENTS.md`, `agent-docs/reference-sources.md`, `Terminal.swift`) and both
      parity-lint skip-lists. Leave historical `plans/`/`docs/research/` paths
      alone.

### Wave 2 -- simplify now that nothing external constrains the shape

- [ ] **7. Collapse `TerminalBackend` to a concrete type.** Six of its nine
      members are constants or no-ops under Swift. Delete the protocol,
      `TerminalBackendEvent` and its `Msg` translations
      (`ghosttyConfigReloaded`, `ghosttyPrefsRefreshed`,
      `ghosttyConfigGeneration`), and `TerminalRecoveryScheduling` -- making
      `AppRuntime`'s enriched checkpoints unconditionally mutation-driven.
      Delete the periodic-fallback startup method/call,
      `enrichedCheckpointInterval = 600.0`, its stale leak-mitigation comment,
      and the obsolete generation member from `PaneConfigKey`; close issue #31
      with this deletion. The existing mutation-driven recovery-freshness tests
      in the normal gate are the behavioral proof obligation for removing this
      safety net.
      Delete `Command.setAppFocus` and the process-backend call it performs;
      model app-active state remains product behavior. Keep `Msg.requestQuit`;
      only its Ghostty backend-event translation goes away.
- [ ] **8. Tighten, but retain, `TerminalSession`.** Keep the protocol as the
      narrow DanTerm/AppKit and UI-test boundary. Delete the no-op
      `setDisplayID` and `setScrollbarEnabled` requirements and take
      `syncSessionDisplayID` with them, preserving its live
      `refreshBackingProperties` behavior under a product-named screen-change
      path. Audit default implementations individually: make bounded primary
      history behavior required of the Swift session, but keep optional flight
      recording and pane-tape follow results where bundle capability, not
      backend choice, still makes `nil` meaningful.
- [ ] **9. Delete the `GhosttyPrefs` shadow config.** Point the preferences
      draft's dirty/reset logic at `model.config` directly, as it already does
      for `alertClearMode` / `remoteTheme` / `fontFamily`. Removes
      `GhosttyPrefs`, `committedGhosttyPrefs`, `Msg.ghosttyPrefsRefreshed`, the
      `ghostty:` label on `preferencesOpened`, and three hand-written mirror
      sites in `Update.swift`. Add pure-core behavioral coverage proving that
      theme and font-size dirty detection and Reset behavior remain unchanged
      against `model.config`, including the committed-side font-size text
      round-trip. Make Reload Config reload DanTerm JSON only.
- [ ] **10. Investigate folding `tests-ui` into a real test target.** Its only
      recorded rationale is "the GhosttyKit-free UI harness". If SwiftPM can host
      it against `DanTerm` the way `app-tests` does, that deletes `test-ui.sh`'s
      60-file list, both shims, the per-view "promotion" ritual, and
      `test-ui-harness_test.sh`. If it cannot, write down the real reason.
- [ ] **11. Reconsider the two text-input commands.** With paste semantics
      restored (Wave 0), decide whether `Command.sendText` and
      `Command.sendInputText` are still two things. Do not collapse them on the
      grounds that they currently behave identically.
- [ ] **12. Reconsider `TerminalSessionRequest`.** Theme/fontSize/fontFamily are
      threaded per session because Ghostty owned its own config; with one
      backend some of that could be read from `DanTermConfig` at the creation
      seam. Not purely redundant -- per-pane and remote theme overrides are real.
- [ ] **13. Shrink `terminal-backend-boundary-lint.sh`.** Drop the GhosttyKit
      allowlist and Ghostty-theme-path loops; keep (and lean harder on) the
      engine-import allowlist, which is the only thing holding the app boundary.
- [ ] **14. Lexicon pass.** "Open Ghostty Config" menu item and its Cmd-Opt-,
      shortcut, `PreferencesPanel`'s ~12 `ghosttyTheme*` identifiers,
      `ThemeBrowserView`'s now-false reset copy, `Projections`'
      `ghosttyThemeText`, `// MARK: - Ghostty Callbacks`, the "matches Ghostty's
      title coalesce interval" rationale, `import-ghostty-themes.py` ->
      `import-themes.py`, and `UpdateGhosttyTests` -> `UpdateSessionEventTests`
      (rename only -- all 643 lines are generic session-event tests).
- [ ] **15. Docs and roadmap.** Update `README.md`, `AGENTS.md` (Boundaries,
      Build, the read-before table), `agent-docs/build-details.md`,
      `agent-docs/reference-sources.md`, `agent-docs/worktree-development.md`,
      `docs/ci.md`, and `integrations/danterm/SKILL.md`; retire
      `docs/upgrading-ghostty.md`; add supersession notes rather than rewriting
      historical ADRs/research/plans; decide the version bump (`TODO.md` line
      1); check off Milestone 10 in `plan-terminal-engine/14-roadmap.md`.
- [ ] **16. Prove the final cutover from a clean checkout.** With no
      `.ghostty-src`, `lib/GhosttyKit.xcframework`, or `lib/ghostty-themes`, run
      the normal gate, UI gate, dev build, and release build. Verify the release
      bundle's three executable/signing boundaries (`DanTerm`, `danterm`,
      `PTYSessionBootstrap`), smoke pane launch/input/output/exit with no backend
      environment value, and confirm the app target has no GhosttyKit dependency
      or linked Ghostty symbols. Historical/provenance `Ghostty` mentions are
      expected, so do not use a raw word-count as the acceptance gate.

## Accepted risks
- **Tracked-source line citations may drift before implementation.** They record
  where claims were verified on 2026-08-06, not edit instructions; implementers
  re-resolve the named files and symbols at implementation time.

## Open questions
- Is the `tests-ui` bespoke build actually forced by the WindowServer
  requirement, or only by GhosttyKit? Nobody wrote it down.
- What should DanTerm's version bump be for the switchover? Already in `TODO.md`
  line 1; the answer probably wants to be "minor, and say so loudly in the
  release notes", since the terminal engine changing is the largest behavioral
  change the app has ever shipped.
