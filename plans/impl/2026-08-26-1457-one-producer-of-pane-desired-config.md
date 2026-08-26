# One producer of a pane's desired terminal config

## Problem

`ee1441ff` made the engine's render metrics name the font they were built
from, so no rendering surface keeps a shadow copy of its font inputs. It
left the creation path untouched, and recorded the follow-up: a session is
still created from loose font fields that can drift.

The follow-up understates it. The drift surface is not the font pair -- it
is the whole pane config at creation. Five of `PaneConfigKey`'s six fields
(theme, font size, font family, option-as-alt, grid override) are derived
by hand at three sites:

- `desiredPaneConfig` in `lib/DanTermCore/Sources/DanTermCore/Projections.swift`,
  which the reconciler diffs and pushes;
- normal session creation in `app/AppRuntime.swift`;
- the restore path in `app/AppRuntime.swift`.

Today's correctness rests on those three agreeing by convention. A pane
mounts with what creation computed, and the first reconcile pass after
`installPane` re-pushes everything (its cache entry is empty) with what
`desiredPaneConfig` computed. Nothing checks that the two match; the view's
own equality guard hides a mismatch in the fields it dedupes and silently
re-renders for the rest.

Two pieces of evidence that the creation path is ad hoc rather than
designed:

- `copyOnSelect` is in the key but not in the request, so it is the one
  pane-config fact that is only ever pushed after mount.
- The creation sites fall back to the config's default font size when the
  pane is absent from the model, while `themeName` in the same argument
  list falls back to nil. Two different ghost-pane behaviors, neither
  chosen. Both are unreachable: `.createSession` is emitted only after the
  pane is in the model, and the restore site force-unwraps the same pane
  two arguments above its own fallback.

## Decision

Give the pane's desired terminal config exactly one producer, and have
creation and reconcile both read it.

- A `DanTermCore` value carries the pane's font as one fact: the per-pane
  effective size and the model's verified-installed family.
- A pure derivation in `DanTermCore`, taking the pane and the model,
  produces a pane's whole `PaneConfigKey`. `desiredPaneConfig` becomes that
  derivation mapped over the live panes. It must take the model as a
  parameter, not read an ambient one: the restore path derives against a
  staged model while the live model is still the pre-restore one.
- `PaneConfigKey` holds the font value in place of two fields.
- The session request carries the produced key rather than loose
  appearance fields, and both creation sites build it from the same
  derivation.
- `TerminalSession.setFont` takes the core font value.

The boundary constraint the previous plan recorded does not bind here.
`scripts/terminal-backend-boundary-lint.sh` confines *engine module
imports* to its adapter allowlist; a `DanTermCore` type is legal
throughout the app, which already speaks `OptionAsAlt` and
`PaneGridOverride` at this same seam. The engine keeps its own font type
because it cannot depend on `DanTermCore`, and the conversion between the
two happens only inside allowlisted adapter files.

Because the key becomes a construction input, `copyOnSelect` becomes one
too. A request field the receiver ignores is the asymmetry that let
creation drift in the first place.

## Invariants

- **I1.** A pane's desired terminal config has one producer. Creation and
  reconcile derive it by calling the same function, against the model each
  is working from.
- **I2.** A pane's font size and resolved family travel as a single value
  from that producer to the adapter seam. No type between them holds the
  two as separately settable fields.
- **I3.** The engine's own font type appears only in files the terminal
  backend boundary lint allows.
- **I4.** A session request naming a pane the model does not hold fails
  session creation. No appearance fact falls back to a configuration
  default at the creation seam.
- **I5.** A pane is mounted with its full desired config. The first
  reconcile pass after a pane mounts finds nothing to change for it.
  The pane-config setters are not uniformly idempotent -- applying a
  theme discards the pane's swapchain and rerenders whether or not the
  theme moved -- so a redundant first push costs a second render of a
  just-mounted pane, not nothing.
- **I6.** One font change rebuilds a pane's metrics once. (Preserved from
  `ee1441ff`, now structurally rather than by convention: there is one
  field left to diff.)

## Proof obligations

- **PO1.** The config a session is created with equals the config the
  reconciler would push for that pane, for a pane created live and for a
  pane rebuilt by restore against a staged model. (I1)
- **PO2.** A per-pane font size step and a config font family change each
  reach a mounted pane as one applied font value. (I2, I6)
- **PO3.** The boundary lint passes, and fails if the engine font type is
  named outside the allowlist. (I3)
- **PO4.** Creating a session for a pane absent from the model reports
  session creation failure. (I4)
- **PO5.** A newly mounted pane's first reconcile pass applies no pane
  config change, including copy-on-select. (I5)
- **PO6.** A restored window's panes render at their restored font size and
  theme on their first frame, not after a later correction. (I1, I5)

## Non-goals

- The iOS `MobileCellMetrics` font scalar. Its sole production caller
  passes a hardcoded size, there is no family, and a single scalar cannot
  drift against itself. It joins this problem only when iOS grows a font
  family setting.
- The two app-side sites that resolve a configured family into a verified
  installed one. That is a side effect, correctly outside the core, and it
  already has a single producer.

## Accepted risks

- **AR1.** Carrying the reconciler's config key on the creation request
  couples the two seams to one vocabulary. That coupling is the point --
  they describe the same fact and must agree -- but a field added to the
  key later becomes a construction concern the implementer must answer.
  Accepted: the compiler asking that question is the property this plan
  buys.

## Rejected ideas

- **RI1.** Create sessions with no appearance and let the single reconcile
  path dress them after mount. It targets the right property by the wrong
  means, and costs three things: the theme's default colors are a genuine
  construction input to the terminal host, so a font-less mount would make
  font the odd one out; container layout runs before the pane-config pass,
  so a default-font mount hands the child a wrong initial grid and a
  wrong-metrics first frame; and restore cannot use the reconcile path at
  all, because staged sessions are built against a model the reconciler is
  not reading, so every restored pane would mount wrong and flash. Identity
  of derivation, not identity of push path, is what removes the drift.
- **RI2.** Introduce the font value and its derivation alone, leaving
  theme, option-as-alt, and grid override as loose request fields. It kills
  the named instance and leaves the class: three hand-built bundles, one
  field smaller, and the same follow-up note.

## Commit progress
- [x] 1. Carry a pane's font as one core value (I2, I6; PO2, PO3). Add the
  `DanTermCore` font value, fold `PaneConfigKey`'s two font fields into it,
  and make `TerminalSession.setFont` take it. The creation seam keeps its
  loose fields for now -- entry 2 replaces them wholesale with the key.
- [x] 2. Give a pane's desired terminal config one producer (I1, I4, I5;
  PO1, PO4, PO5, PO6). Extract the per-pane derivation, carry the produced
  key on the session request, build both creation sites from the derivation,
  fail creation for a pane the model does not hold, and seed the reconciler's
  pane-config cache at mount.

## Implementation notes

- The restore path needed no absent-pane guard of its own. It walks the
  staged model's own pane tree, so the pane the derivation takes is the loop
  variable and cannot be missing. Only the `.createSession` command, whose
  pane id arrives from outside, can name a pane the model does not hold.
- `installPane` is what seeds the reconciler's pane-config cache, and its
  `config` is optional. `installTerminalSession` -- the test-only install
  path, which is handed a bare session rather than a derivation -- derives
  from the live model when the pane is there and passes nil when it is not.
  A nil seed leaves the cache entry absent, which is the old behavior: one
  explicit push on the next pass.
- Restore stages a `StagedPane` (the finished host plus the config it was
  built with) rather than a bare host, so committing the restore installs
  each pane through the same `installPane` seam and seeds the same cache.
  Teardown clears the caches just before, so the seeds survive.
- `copyOnSelect` became a `SwiftTerminalSessionView` construction input. It
  was the one key field with no construction path at all, and with the cache
  now seeded at mount no later pass would have supplied it.
- Two existing tests drove `.createSession` for a pane id the model never
  held, which the new guard turns into a failure. Both now build a model with
  a real pane and use its id.
