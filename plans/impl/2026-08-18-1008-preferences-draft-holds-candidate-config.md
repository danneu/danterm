# Preferences draft: delete the dead reset/dirty surface, hold a candidate config

## Context

Audit finding S26 (docs/scratch/2026-08-11-simplification-audit.md) reports the
six preference fields enumerated by name in five places in the reducer, and
twelve near-identical prefSet*/prefReset* arms. Verification found the audit was
written one day after commit 6f1f0603 made the preferences panel
immediate-apply: every control change sends a set message followed by
`.prefSave`, and the panel no longer has reset buttons, dirty labels, or a Save
button. The core-side machinery for that removed UI survives as dead production
surface: nothing outside tests sends a `prefReset*` message, and the panel's
`apply()` never reads the six `*DirtyLabel` projection fields or `saveEnabled`.

So half the duplication the audit reports dissolves by deletion. The rest is
not a mapping worth centralizing but a second representation worth removing:
`PreferencesDraft` restates six `DanTermConfig` fields, so `.preferencesOpened`,
`.configLoaded`, and `.prefSave` each enumerate all six. A draft that holds a
candidate config removes the restatement and all three enumerations with it.

Evidence already established:

- `Msg` has no Codable/CaseIterable/wire/persistence coupling; IPC and recovery
  snapshots never name preference messages; `Msg.coalescesReconcile` has a
  `default:` arm. Removing or reshaping these cases is a pure source refactor.
- The memberwise `PreferencesDraft` constructor has exactly one call site in the
  whole tree (the `.preferencesOpened` arm); no test constructs a draft
  directly.
- `prefSave`'s post-save draft normalization (remoteTheme, fontFamily, and
  fontSize when valid) is load-bearing for what the panel fields display and is
  pinned by existing tests. It is not part of the dead surface.

## Decision

1. **Delete the dead surface.** The six `prefReset*` Msg cases and reducer
   arms; the six `*DirtyLabel` fields, `saveEnabled`, and the dirty-flag
   computations in `PreferencesPanelProjection`; the tests that exist only to
   pin them. The projection keeps values, choices, and warnings -- everything
   the panel actually renders.
2. **The draft holds a candidate config, not a parallel copy of it.**
   `PreferencesDraft` becomes a candidate `DanTermConfig` plus the one piece of
   state a config cannot carry: the raw font-size text, which must stay raw
   while it is mid-edit. Seeding is then a whole-value assignment plus the
   `configFontSizeText` rendering of the size, and both `.preferencesOpened`
   and `.configLoaded` use it. The six-field draft, its six-field seeding
   mapping, and the six-field save mapping all go away together.
3. **One edit message.** The six `prefSet*` cases collapse into one
   `prefSet(PreferenceEdit)` case carrying a six-case payload enum, handled by
   one reducer arm with one draft-open guard. This mirrors the existing
   payload-enum Msg pattern (`sessionReport`, `ipcRequest`). Each case writes
   its candidate-config field, except the font size, which writes the raw text.
   The panel's `applyPreferenceChange` takes the edit and builds the message;
   the message vocabulary stays `.prefSet` / `.prefSave`.
4. **`prefSave` semantics are unchanged**; only its shape follows from 2. It
   resolves the candidate in place -- remote theme, font family, and the parsed
   and bounded font size when the text parses -- then commits the whole
   candidate as the new config, instead of copying six fields into a config
   built from the old one. Validation, the no-change/no-command result, and
   post-save draft normalization all behave exactly as they do today.

Files: `lib/DanTermCore/Sources/DanTermCore/{Msg,Update,Projections,Model}.swift`,
`app/PreferencesPanel.swift`, core test files under
`lib/DanTermCore/Tests/DanTermCoreTests/` (UpdatePreferencesTests,
ConfigCopyOnSelectTests, PreferencesFontFamilyTests, ConfigFontFamilyTests,
UpdatePaneFontSizeTests, UpdateRemoteTests, SnapshotTests), and
`tests-ui/PreferencesPanelTests.swift`.

## Invariants

- I1: While the panel is open, an external config reload re-seeds every draft
  field from the new config -- the draft cannot silently diverge from the
  config it mirrors.
- I2: A preference edit mutates the draft only while the panel is open; with no
  draft it is a no-op. This guard exists once.
- I3: The draft owns exactly one candidate `DanTermConfig` plus the raw
  font-size text. No preference is stored twice: a config-backed preference
  added later flows through open, reload, and save with no new mapping. The
  font size is the sole exception, and its two halves have disjoint roles --
  the raw text is what the panel renders and what save parses, and the
  candidate's number is only what survives a save whose text does not parse.
  The panel never renders the candidate's number.
- I4: Saving an unparseable font size emits no save command and leaves the
  user's text in the field; saving valid values normalizes the draft to what
  was committed (resolved remote theme, resolved font family, rendered font
  size).
- I5: The preferences projection carries only state the panel renders. Panel
  behavior is unchanged: same fields, same warnings, same immediate-apply
  flow.

## Proof obligations

- PO1 (I1): the existing configLoaded-while-open tests, rewritten to drop
  dirty-label assertions before the seeding change lands, stay green through
  it.
- PO2 (I2): the "pref messages are no-ops when draft is nil" test, reshaped to
  the new message and widened to exercise all six `PreferenceEdit` cases --
  the existing test omits font family and copy-on-select. Each case must emit
  no commands and leave the whole model unchanged.
- PO3 (I4): the invalid-font-size-after-save and post-save normalization tests
  (UpdatePreferencesTests, UpdatePaneFontSizeTests) keep passing with only
  their dead assertion lines removed. These also pin I3's font-size split: the
  panel keeps showing the unparseable text while the committed size holds.
- PO4 (I5): the panel value-rendering and warning tests survive unchanged in
  substance; `just test-ui` passes -- run it explicitly, it is outside the
  `just test` gate and both the projection deletion and the message collapse
  touch its suite.
- PO5 (I1, I3): the reload-while-open clobber scenario, in order. Open
  Preferences against one config; while it stays open, deliver a
  `.configLoaded` carrying a distinct config with non-default `localeFallback`
  and `tailnet` -- the two config fields the panel does not edit; edit one
  visible preference; save. Both the emitted `saveDanTermConfig` payload and
  `model.config` must carry the reloaded values of those two fields. Reload
  while the panel is open is the only ordering that catches a stale candidate,
  so the test must not open the panel after the reload or save without an
  intervening edit.

## Non-goals / Accepted risks / Rejected ideas

- Non-goal: any visible change to the preferences panel.
- Non-goal: changing `prefSave` semantics or the draft's raw-text-until-save
  model.
- Accepted risk AR1: deleting projection fields makes projection equality
  coarser, so reconcile skips applies it previously performed. Benign by
  construction: every newly skipped apply rendered nothing, and the open/close
  transition logic keys on nil/non-nil, which is unchanged.
- Rejected idea RI1: the audit's `prefReset(PreferenceField)` parameterization.
  Reset has no UI since 6f1f0603; generalizing dead code preserves it. Delete
  instead. (If reset ever returns, `PreferenceEdit` is the natural vocabulary
  to extend.)
- Rejected idea RI2: the cheaper fallback of adding only a seeding
  initializer and keeping six set cases. No defect in the ideal to justify it:
  the collapse removes six copies of the I2 guard and follows an existing Msg
  pattern.

## Implementation discretion

- Declaration site and case naming of `PreferenceEdit` (recommendation from
  design review: top-level in Msg.swift beside the other intent payload enums,
  cases mirroring the panel's controls).
- Step ordering (recommendation: deletions first, then the candidate-config
  draft with its seeding and save rewrite, then the
  message collapse, keeping the build green between steps; the ~60 test
  sender sites and the tests-ui destructuring patterns update mechanically
  with the collapse).

## Verification

- `swift test --package-path lib/DanTermCore` for the core suites after each
  step; `just test` as the full gate.
- `just test-ui > .build/ui.log 2>&1` once from a GUI session, after the whole
  implementation lands (PO4).
- Manual smoke via a dev slot if desired: open Preferences, edit each field,
  confirm immediate apply and the not-installed font warning still render.

## Commit progress
- [x] 1. refactor(prefs): delete the dead reset and dirty surface
- [x] 2. refactor(prefs): let the draft hold a candidate config
- [x] 3. refactor(prefs): collapse the six set messages into one edit

## Implementation notes

- Sliced into three commits along the ordering the plan recommends under
  Implementation discretion, so the build stays green between steps and the
  mechanical rewrite of the ~60 test sender sites lands apart from the
  behavioral changes.
- Where a test carried a live assertion alongside its dead ones, the test was
  reduced and retitled rather than deleted, so no covered behavior was lost:
  the raw-draft-text rendering of the remote theme field, the rendering of a
  whole and a fractional saved font size, the copy-on-select checkbox value,
  and the post-save echo of the committed font family and font size. Tests
  whose every assertion was dirty-or-reset were deleted outright.
- `prefSave resets dirty state` was the one test with no live assertion whose
  subject still matters: it pinned that a second save writes nothing. It was
  rewritten to assert the command count directly instead of `saveEnabled`,
  which is the observable form of the same rule now that every control change
  sends `prefSave`.
- Commit 2 seeds the draft through a single `init(seededFrom:)` rather than an
  assignment at each call site, so open and external reload cannot drift, and
  the reload arm now replaces the whole draft instead of writing field by field.
- Commit 2 also widened `an invalid font size does not block the other fields
  from saving` to open against a committed size of 14. Every invalid-size test
  started from a nil committed size, so nothing pinned the half of I3 that says
  the candidate's number survives text that will not parse -- a save that
  cleared the size would have passed.
- The core tests that reach into draft fields were rewritten mechanically to
  `draft.config.<field>` / `draft.fontSizeText`. They were left as draft reads
  rather than moved onto the projection, so this commit's diff stays a
  representation change and does not also re-target what those tests assert.
- `PreferenceEdit` is declared top-level in Msg.swift beside the other intent
  payload enums, with cases named for the panel's controls. The panel's
  `applyPreferenceChange` now takes a `PreferenceEdit` and builds the `.prefSet`
  message itself, so no call site names `Msg` twice.
- Commit 3 rewrote the reducer's six guarded arms into one `.prefSet` arm that
  states the draft-open guard once and then switches on the edit. The guard was
  checked by deleting it and confirming the widened no-op test failed on all six
  cases before it was restored.
- Commit 3 fixed `tests-ui/SwiftTerminalSessionViewTestShim.swift`'s
  `setGridDimensions` signature, which the previous Follow Up named. That break
  predates this plan and is unrelated to preferences, but PO4 requires a passing
  `just test-ui` from this commit, and the suite did not compile without it. The
  shim drops the new `pinned` argument because no UI test asserts on it.

## Follow Up

- `tests-ui/SwiftTerminalSessionViewTestShim.swift:520` records only the
  dimensions its `setGridDimensions(_:pinned:)` receives and drops `pinned`.
  Nothing asserts on `pinned` today, so no coverage is missing right now, but a
  UI test that wants to pin the claimed-vs-unclaimed distinction described at
  `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift:768`
  must first widen the shim's recorded value.
