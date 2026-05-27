# Migrate per-pane theme/config application into the reconciler

## Context

Per-pane theme application is the last derived-surface concern still done
imperatively. The `refactor(reconcile):` commit series (focus borders, pane
toolbars, search overlays, sidebar, window chrome, MRU switcher, preferences
panel) moved every other "derive AppKit/surface state from the model" concern
into pure-projection reconcile passes; theme was planned for that series
(`plans/wip/fwiw-my-message-wasn-t-zazzy-muffin.md:84,215`) but never landed, and
`plans/impl/2026-05-27-remove-sync-preferences-panel-reconcile.md:92` explicitly
deferred it.

Today the effective theme is pushed to a surface from **~9 hand-wired sites**:

- 7 `.applyPaneTheme` emits in `update()` (`app/Update.swift:206,484,544,556,573,595,689`)
- `reapplyAllPaneThemes()` (`app/AppRuntime.swift:1016`) called from `reloadAllConfig`
  (`:1025`), `commitRestoreSession` (`:1218`), and `GhosttyApp`'s app-level
  `RELOAD_CONFIG` handler (`app/GhosttyApp.swift:346`)
- `applyPaneConfig()` called directly from `GhosttyApp`'s surface-level
  `RELOAD_CONFIG` handler (`app/GhosttyApp.swift:354`)

Every model path that changes `effectiveTheme` must *remember* to emit the
command — easy future drift as remote/config/theme flows change. The fix folds
all of it into one pure projection + one reconcile pass, so theme application
becomes a derived consequence of the model, exactly like the other passes.

**Outcome:** delete `.applyPaneTheme`, `applyPaneConfig`, and
`reapplyAllPaneThemes`; theme application happens in a single
`reconcilePaneConfig()` pass driven by `desiredPaneConfig(in:)`. The drift surface
collapses to one place. Behavior is preserved **except** one error-path edge: a pane
referencing a **missing** theme file no longer retries `loadConfigWithTheme` on every
theme transition — `applyDiff` advances its cache even when the apply closure
early-returns on a nil config (`ModelOperations.swift:1110`), so it retries only on a
theme-name change or a config-reload generation bump. Effectively unobservable (the
theme selector offers only valid names; a typo'd `remote-theme` reverts cleanly on
`commandEnded`; a config reload bumps the generation and retries), so no test.

## Key design decision: a model-resident config generation, not a cache reset

A naive `[PaneId: themeName]` projection diff is **insufficient** for a full
Ghostty config reload: `loadConfigWithTheme` (`app/GhosttyApp.swift:96`) rebuilds
each themed surface from base files + DanTerm overlay + theme, so after a base
reload a themed pane's *resulting* config changes even though its theme **name**
is unchanged — a name-only diff would skip it. Today `reapplyAllPaneThemes`
re-applies unconditionally to cover this.

We encode this as a generation counter **in the model**, bumped by a new Msg, and
include it in the projected value so a reload re-fires the diff for every themed
pane. Chosen over a runtime cache-reset because:

- The codebase already models external config-file reloads as a model event
  (`.configLoaded(DanTermConfig)`, `app/Update.swift:579`); `.ghosttyConfigReloaded`
  is its Ghostty-side twin.
- It keeps the reconcile pass purely model-driven and unit-testable (the whole
  point of the migration template), rather than reaching into reconciler-private
  cache state from imperative sites that live outside `send()`
  (`AppDelegate.swift:531`, `PreferencesPanel.swift:362`).

**One app-wide generation; the surface-scoped reload path is dormant in DanTerm.**
libghostty delivers `RELOAD_CONFIG` to either the **app** target (config files
changed -> every surface) or a single **surface** target. The surface path exists in
Ghostty -- `Surface.notifyConfigConditionalState` (`.ghostty-src/src/Surface.zig:1679`)
emits a surface-targeted soft `reload_config` on a per-surface conditional-state
change -- but it fires **only** from `colorSchemeCallback` (`Surface.zig:5046,5061`),
reachable **only** via the `ghostty_surface_set_color_scheme` /
`ghostty_app_set_color_scheme` C exports (`embedded.zig:1702,1509`). DanTerm calls
neither and observes no `NSAppearance`/`effectiveAppearance` (verified: zero hits in
`app/`, `cli/`), and the `reload_config` keybind dispatches to the **app** target,
not surface (`App.zig:447`). So `config_conditional_state` is set once at surface
creation and never changes -- the surface-level `RELOAD_CONFIG` handler
(`GhosttyApp.swift:353`) is currently unreachable.

So a single app-wide generation suffices:

- `model.ghosttyConfigGeneration` (app-wide) -- bumped on any base-config reload; a
  bump re-layers **all** themed panes. Folded into `PaneConfigKey`, so `applyDiff`
  re-fires every themed pane after a reload.

The surface-level handler still routes through this global bump (re-layering all
themed panes is correct, just looser than necessary), which costs nothing while the
path can't fire. **If OS-appearance reporting is wired into libghostty later** --
per-surface light/dark would then re-layer N surfaces x M themed panes on each flip
-- reintroduce a per-pane `PaneModel.configGeneration` scope at that point. This plan
deliberately does not pre-build it (YAGNI).

## Implementation

Follow the established 4-part template (`app/Reconcile.swift:8-13`); mirror the
**keyed-iff-active** search-overlay pass (`desiredSearchOverlays`
`app/ModelOperations.swift:1092`, `reconcilePaneChrome` overlay half
`app/Reconcile.swift:192-197`).

### 1. Model field + Msg (pure layer)

- `app/Model.swift:195` — add `var ghosttyConfigGeneration: Int = 0` as the last
  `AppModel` field, with an `// ephemeral` comment like its neighbors. **No
  snapshot change**: `AppModelSnapshot` (`Model.swift:289`) and `toSnapshot`
  (`ModelOperations.swift:1619`) are hand-mapped and only carry `groups` +
  `selectedTabId`, so the field is auto-excluded and resets to 0 on restore.
- `app/Msg.swift` — add `case ghosttyConfigReloaded` (config section). No
  `translateMsg` or `coalescesReconcile` change: `translateMsg`
  (`ModelOperations.swift:1906`) passes non-event Msgs through unchanged, and the
  new case defaults `coalescesReconcile` to `false`, so `reconcileDecision`
  (`ModelOperations.swift:1899`) returns `.reconcileNow`.
- `app/Update.swift` (config section, ~`:577`) — handler:
  `case .ghosttyConfigReloaded: model.ghosttyConfigGeneration += 1; return []`.

### 2. Projection (pure layer)

`app/ModelOperations.swift`, beside `desiredSearchOverlays` (~`:1098`):

```swift
struct PaneConfigKey: Equatable {
  let theme: String       // effective theme name; keyed iff non-nil (like search overlay)
  let generation: Int     // app-wide ghostty base-config generation; a bump re-fires the diff
}

func desiredPaneConfig(in model: AppModel) -> [PaneId: PaneConfigKey] {
  var result: [PaneId: PaneConfigKey] = [:]
  for pane in model.allPanes {
    if let theme = effectiveTheme(for: pane) {   // app/ModelOperations.swift:14
      result[pane.id] = PaneConfigKey(theme: theme, generation: model.ghosttyConfigGeneration)
    }
  }
  return result
}
```

### 3. Reconcile pass (impure executor)

- `app/Reconcile.swift:54` — add cache field to `ReconcilerCaches`:
  `var paneConfig: [PaneId: PaneConfigKey] = [:]`, with a doc note that it rides
  the persisted `TerminalView` in `surfaces` like `focusBorders` (`:22-24`), so it
  needs **no** cross-pass invalidation (unlike the host-recreated
  `paneToolbar`/`searchOverlay`).
- `app/Reconcile.swift` — add the pass (closures mirror the two branches of the
  deleted `applyPaneConfig`):

```swift
func reconcilePaneConfig() {
    applyDiff(desiredPaneConfig(in: model), &caches.paneConfig, apply: { paneId, key in
        guard let surface = surfaces[paneId]?.surface,
              let config = ghosttyApp.loadConfigWithTheme(key.theme) else { return }
        ghostty_surface_update_config(surface, config)
        ghostty_config_free(config)
    }, remove: { paneId in   // theme -> nil: revert to base
        guard let surface = surfaces[paneId]?.surface else { return }
        ghosttyApp.reloadConfig(surface: surface, soft: false)
    })
}
```

- `app/Reconcile.swift:66` — call `reconcilePaneConfig()` immediately **after**
  `reconcileSurfaceExistence()` (torn-down panes gone, surviving surfaces live),
  before `reconcileContainers()`. The surface lives in `surfaces[paneId]` and
  survives container rebuilds, so ordering vs. the container pass is irrelevant.

### 4. Delete the imperative theme machinery

- `app/Update.swift` — drop the 7 `.applyPaneTheme` emits and fix returns:
  `:484` -> `[.scheduleCheckpoint]`; `:544/:556/:573` -> `[]`; `:206/:595/:689`
  drop the append. Each becomes a pure model mutation; the post-`send()`
  reconcile applies the delta. (`.remoteSessionReported`'s second-transition
  `return []` at `:575` stays correct: unchanged theme + generation -> identical
  `PaneConfigKey` -> `applyDiff` skips.)
- `app/Command.swift:64` — delete `case applyPaneTheme`; `:112` — remove it from
  the `isPostReconcile` false-list.
- `app/AppRuntime.swift:543` — delete the `.applyPaneTheme` perform arm.
- `app/AppRuntime.swift:1002,1016` — delete `applyPaneConfig` and
  `reapplyAllPaneThemes`.

### 5. Rewire the reload entry points

- `reloadAllConfig` (`app/AppRuntime.swift:1023`) — keep `ghosttyApp.reloadConfig()`
  (app-level base, refreshes nil-theme panes) and `reloadDanTermConfig()`; replace
  `reapplyAllPaneThemes()` with `send(.ghosttyConfigReloaded)`. Covers all three
  callers (`AppDelegate.swift:531`, `PreferencesPanel.swift:362`, the
  `.reloadGhosttyConfig` perform arm). Nested `send` from a perform arm is already
  a shipped pattern here (`reloadDanTermConfig` -> `send(.configLoaded)`).
- `commitRestoreSession` (`app/AppRuntime.swift:1218`) — **delete** the
  `reapplyAllPaneThemes()` call. The `reconcile()` at `:1215` already runs
  `reconcilePaneConfig` against a clean cache (reset by `tearDownCurrentSession`)
  with live surfaces (set at `:1202`), so restored themes apply there.
- `GhosttyApp` app-level `RELOAD_CONFIG` (`app/GhosttyApp.swift:346`) — replace
  `runtime?.reapplyAllPaneThemes()` with `runtime?.send(.ghosttyConfigReloaded)`;
  keep `reloadConfig(soft:)` at `:343` and the `DispatchQueue.main.async` hop.
- `GhosttyApp` surface-level `RELOAD_CONFIG` (`app/GhosttyApp.swift:350-356`) —
  **keep** `reloadConfig(surface:soft:)` at `:350` (applies the new base to that
  surface, covering nil-theme panes), and replace the `applyPaneConfig(paneId:)`
  block with `runtime?.send(.ghosttyConfigReloaded)`. This handler is dormant today
  (see the design note: DanTerm never reports color scheme, so no surface-targeted
  reload fires), so the global bump never actually triggers here; routing it through
  the app-wide generation re-layers all themed panes — correct, just looser — and
  avoids per-pane machinery for an unreachable path. Revisit per-pane scoping only
  if OS-appearance reporting is wired later.
- `GHOSTTY_ACTION_CONFIG_CHANGE` (`app/GhosttyApp.swift:363`) — **unchanged**.
  libghostty has no config file watcher (verified in `.ghostty-src`); it only fires
  as the downstream confirmation of an app-initiated reload, so the rewired sites
  above cover every base-config reload with no gap.

## Tests

All assertions stay behavioral and structure-insensitive: assert the **desired
end-state** via the pure projection / model, not command emission.

Convert existing emit-assertions (the `.applyPaneTheme` `hasEffect` checks):

- `tests/UpdateThemeTests.swift:16,53,68` — assert `desiredPaneConfig(in: model)[id]?.theme`
  equals the set theme (and `== nil` for the no-theme split); keep the
  `.scheduleCheckpoint` assertion.
- `tests/UpdateRemoteTests.swift` (six sites incl. `:14,58,123,230,303`) and
  `tests/UpdatePreferencesTests.swift:334` — replace the `.applyPaneTheme` checks
  with `desiredPaneConfig`/model assertions; the `configLoaded` remote case now
  returns `[]` (update the `commands.count` expectation).
- `tests/UpdatePaneTests.swift:588` — drop the `.applyPaneTheme` check; assert the
  background-split pane's projected theme.
- `tests/ReconcileTests.swift:67-68` — delete the two `Command.applyPaneTheme`
  `isPostReconcile` lines (the case is gone).

Add (mirroring the `desiredSearchOverlays` test at
`tests/ModelOperationsTests.swift:1797`):

- `desiredPaneConfig`: keyed only for themed panes (nil -> no key; set -> key;
  clear -> no key).
- `desiredPaneConfig`: remote override takes priority over user theme
  (exercises `effectiveTheme`).
- `desiredPaneConfig`: a `.ghosttyConfigReloaded` bump changes **every** themed
  pane's `generation` (so a reload re-fires all themed panes) and leaves unthemed
  panes absent.
- `.ghosttyConfigReloaded`: increments `model.ghosttyConfigGeneration`, returns no
  commands.

## Verification

- `just test` — unit suite (pure, no Cocoa/GhosttyKit).
- `just build-run`, then manual QA:
  - Set a pane theme via the selector -> recolors; split it -> child inherits;
    clear theme -> reverts to base.
  - Start a remote (ssh) session -> remote theme; exit -> reverts.
  - **Reload config (menu / Cmd-Shift-,) while a pane is themed** -> pane keeps its
    theme (re-layered on the new base). This is the generation path.
  - Edit a Ghostty key (e.g. `font-size`) in config, reload -> themed pane shows
    the new font **and** keeps its theme colors (proves base+theme re-layering).
  - Restore a session containing a themed pane -> theme applied after restore.

## Implementation notes

- `reloadAllConfig` now sends `.ghosttyConfigReloaded` after `reloadDanTermConfig()`
  so any DanTerm `remote-theme` changes are in the model before the generation bump
  re-layers themed panes.
