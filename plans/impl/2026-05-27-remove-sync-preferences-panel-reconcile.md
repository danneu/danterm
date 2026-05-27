# Remove `syncPreferencesPanel` With a Preferences Reconcile Pass

## Summary

Replace the remaining preferences view-sync command with the same model-derived
reconciler pattern used for sidebar, window chrome, and switcher. The
preferences panel UI becomes a pure projection of `AppModel`, while config
writes, Ghostty reloads, and per-pane theme application remain real commands.

## Key Changes

- Add an internal `PreferencesPanelProjection: Equatable` and
  `desiredPreferencesPanel(in:) -> PreferencesPanelProjection?` in the pure
  model operations layer.
- Projection returns `nil` when `model.preferencesDraft == nil`; otherwise it
  contains:
  - selected alert clear mode
  - remote theme, Ghostty theme, and font-size field text
  - optional complete dirty-row label strings, where `nil` means hidden
  - save button enabled state
- Preserve current dirty semantics exactly:
  - remote theme dirtiness compares `resolveRemoteTheme(draft.remoteTheme)` to
    committed config
  - Ghostty default labels render as `Prev: (default)`
  - invalid font-size stays dirty after save because it is not committed
- Add `caches.preferencesPanel: PreferencesPanelProjection?` and
  `reconcilePreferencesPanel()`.
  - Make `AppRuntime.preferencesPanel` internal before adding the pass, with a
    comment matching `switcherPanel` that says the cross-file reconciler reads it.
  - Compute `new = preferencesPanel == nil ? nil : desiredPreferencesPanel(in: model)`.
  - If unchanged, do nothing.
  - If non-nil and changed, call `preferencesPanel?.apply(new)`.
  - Always advance the cache, including clearing it back to `nil`.
- Insert `reconcilePreferencesPanel()` after `reconcileSwitcher()` and before
  `syncSurfaceVisibility()` so surface visibility remains the last pass.
- Replace `PreferencesPanel.sync(committed:draft:ghostty:)` with
  `apply(_ projection:)`.
  - The panel should only apply already-rendered projection values.
  - Guard text-field and popup assignments when values are unchanged to avoid
    unnecessary field-editor churn while typing.

## Command And Update Cleanup

- Delete `Command.syncPreferencesPanel`, its `perform` arm, and its
  `isPostReconcile` classification.
- Remove every `.syncPreferencesPanel` emission from preference and config
  update paths.
- New command behavior:
  - `.preferencesOpened`, `prefSet*`, `prefReset*`, and
    `ghosttyPrefsRefreshed` return `[]` unless they already have another real
    side effect.
  - `.configLoaded` returns only `.applyPaneTheme` commands when remote panes
    need theme reapply.
  - `.prefSave` returns only persistence, Ghostty reload, and per-pane theme
    commands.
- Keep `showPreferencesPanel()` reading Ghostty prefs and dispatching
  `.preferencesOpened(ghostty:)`; reading Ghostty config is still a runtime
  side effect used to populate model state.

## Test Plan

- Add pure projection tests for:
  - no draft returns `nil`
  - clean open draft renders field values, no dirty labels, save disabled
  - each dirty field renders the correct `Prev: ...` label and enables Save
  - remote theme dirtiness uses normalized `resolveRemoteTheme`
  - Ghostty default previous labels use `(default)`
  - invalid font-size remains dirty after `.prefSave`: open preferences, set an
    invalid `fontSize`, save, assert commands are empty, and assert
    `desiredPreferencesPanel(in:)` still shows the font-size dirty row with Save
    enabled
- Update existing preference and remote tests:
  - remove all assertions that `.syncPreferencesPanel` is emitted
  - assert `[]` for draft-only changes and no-op saves
  - assert config reload with no remote theme change emits no command
  - assert config reload with remote panes emits only `.applyPaneTheme`
  - keep existing assertions for save/remove config keys, reloadGhosttyConfig,
    and remote pane theme updates
- Run `just test`.
- Run `just build` if the test suite does not compile all AppKit files touched
  by the change.
- Final sanity check: `rg "syncPreferencesPanel" app tests` should return no
  code or test hits.

## Assumptions

- No CLI or `danterm` command contract changes are involved, so
  `integrations/danterm/SKILL.md` does not need an update.
- The old no-draft rendering branch in `PreferencesPanel.sync` is no longer
  needed; a preferences panel without a draft is closing or absent, so the
  reconciler should clear its cache instead of rendering committed values.
- `applyPaneTheme` and `reloadGhosttyConfig` stay commands because they depend
  on external Ghostty config state, not only on model-rendered UI.
