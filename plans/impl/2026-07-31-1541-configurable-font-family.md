# Custom font family in `config.json`, with a non-blocking "font not found" warning

## Context

DanTerm's JSON config (`~/.config/danterm/config.json`, schemaVersion 1) exposes
`theme.default`, `theme.remote`, `font.size`, and `ui.alertClearMode`. The font
*family* is not configurable: `TerminalRenderMetrics.init` hardcodes
`NSFont.monospacedSystemFont(ofSize:weight:)`. Users want to pick their own
monospace face.

The hazard is that a font name is the first config value DanTerm cannot validate
by looking at it. Every existing setting degrades on syntax alone -- an empty
theme string, a non-finite font size -- and the pure core decides that with no IO.
Whether `"JetBrains Mono"` exists is a CoreText question. Worse,
`CTFontCreateWithName` never fails: given an unknown name it silently substitutes
a last-resort face, so a typo'd family would render the terminal proportionally
with no signal at all.

So the requirement is three-part: launch normally on a bad value (fall back to
system monospace), make installed families discoverable in Preferences, and tell
the user about an unavailable typed value without a modal. Today the only config
feedback channel is a blocking `NSAlert` (`AppRuntime.presentConfigError`), which
is wrong for a soft, fully-recovered failure that would re-fire on every launch.
Decided surfaces: **a searchable, editable installed-family combo box plus inline
warning in the Preferences panel** (where the user sets the value) and **a
`danterm doctor` check** (where a user already goes to diagnose config health).
No new alert kind, no modal.

Scope decisions already settled:

- Schema is a single `font.family` string. No fallback arrays, no per-style
  families. Absent or empty = system monospace, i.e. today's behavior.
- The only warned condition is **not installed**. An installed-but-proportional
  face renders as asked, no warning.
- Preferences lists all installed families, not only monospaced ones. The combo
  box stays editable so a user can enter a PostScript alias or a family they
  intend to install later.

## Contract

- **I1 -- Core stays deterministic.** The pure core validates `font.family` as
  syntax only (non-empty string), exactly as it validates every other leaf. It
  never asks CoreText anything.
- **I2 -- Support never depends on Core.** `lib/DanTermSupport` compiles and
  tests standalone against `DanTermProtocol` alone; the availability probe added
  there must not name any Core type.
- **I3 -- Only a verified-installed family reaches rendering.** The requested
  name from config is never handed to the render layer; only a name the probe
  resolved, or nil for system monospace. Resolution is *canonicalizing*: a
  PostScript face name is an alias for its family, and the probe yields the
  family. `"Menlo-Bold"` therefore renders regular Menlo, with bold and italic
  still derived by the render layer -- passing the caller's string through would
  make an already-bold face the terminal's base face and smuggle in the
  per-style selection this schema deliberately excludes.
- **I4 -- Every path that applies config resolves it.** Launch, external reload,
  and a successful Preferences save all produce a coherent
  (config, resolved family, warning, pane projection) state with no manual
  reload step.
- **I5 -- An unusable font never leaves a terminal blank or frozen.** Passing the
  availability probe does not guarantee usable grid metrics; a face can be
  installed and still lack the nominal `M` glyph the cell geometry is derived
  from. Rendering must fall back rather than bail.

## Design

### The layering seam

The check splits along the existing purity boundary, and this is the
load-bearing idea of the plan:

| Concern | Layer | Why |
|---|---|---|
| `font.family` is a non-empty string | `DanTermCore` (pure) | syntax only, same shape as `font.size` today (I1) |
| Which families are installed, and does a requested name match one? | `DanTermSupport` (portable IO) | queries against the OS font registry, the same category as the PATH/filesystem probes already there |
| Build the actual `CTFont` | `TerminalRenderExecution` | already owns `TerminalFontSet` and CoreText |
| Compose config facts for doctor | `cli/` boundary | the only place Core and Support are both in scope (I2) |
| Show the warning | `app/PreferencesPanel` + `cli` doctor | both already consume core projections |

`update()` stays pure: the resolution verdict is injected into the model by the
impure caller, exactly like ids and time are, per the inject-vs-ambient rule --
the resolved family is SAVED into the model and ASSERTED in tests, so it must be
injected rather than read ambiently inside the core.

### Model state: one resolved value, no duplicate request

The requested name lives in exactly one place, `model.config.fontFamily`. The
model additionally carries a single ephemeral `resolvedFontFamily: String?` --
the canonical installed name, or nil meaning "fell back to system monospace". It
is not snapshotted; it is re-derived from disk each launch.

"The configured font is missing" is therefore derived, never stored:
`config.fontFamily != nil && resolvedFontFamily == nil`. Storing the requested
name a second time alongside the resolution would let the pair drift from
`model.config` on any path that updates one without the other.

### One resolve-and-apply operation (I4)

The runtime owns a single operation that takes a `DanTermConfig`, resolves its
family through the Support probe, and hands both to the core in one message.
Launch, the reload menu item, and a successful Preferences save all go through
it. There is no second path that sets `model.config` without also setting
`resolvedFontFamily`.

This matters concretely for saves: `.prefSave` today mutates `model.config`
directly. After this change, saving `"Menlo"` must repaint live panes in Menlo,
and saving a typo must raise the warning, both without a reload or restart. A
name that does not resolve is still written to disk -- it is the user's file, and
they may be about to install the font.

### Rendering, with an explicit fallback (I5)

`TerminalRenderMetrics` gains an optional family. With nil it takes today's
`NSFont.monospacedSystemFont` path unchanged. With a name it builds the face from
that name; it keeps its existing `nil` return when the resulting face cannot
yield whole-pixel cell geometry.

The session view's `synchronizeGeometry()` currently bails outright on nil
metrics (`app/SwiftTerminalSessionView.swift:662`), which would leave a new pane
without geometry and an existing pane frozen on its old grid. It must instead
attempt the configured family and, on nil, retry with system monospace before
giving up. Grid reflow, `contentsScale`, and frame publication continue to flow
through this one choke point.

The resolved family reaches panes the same way `fontSize` does: it joins
`PaneConfigKey`, so `reconcilePaneConfig` re-pushes it on change, and it is part
of the session request at pane creation and restore.

### Surface A: Preferences installed-family combo box and inline warning

Opening Preferences queries the Support font catalog and injects the installed
family names into the pure Preferences state and projection; neither the core nor
the AppKit control reads CoreText ambiently. The projection also carries the
font-family text, its `Prev:` dirty label, and a warning string.

The panel presents a searchable, editable combo box. Its first choice is
`System Monospace (Default)`, which maps to no `font.family` key rather than to a
literal family name. The remaining choices are installed font families in a
stable alphabetical order. Selecting or typing changes only the draft; Save
writes the value and immediately applies it to live panes through I4.

The warning is non-nil only when the committed config's family is unresolved
**and** the draft field still holds that same name -- so it clears the moment the
user starts editing, instead of describing text that is no longer on screen.

Wording: `Font "Fira Codee" is not installed -- using the system monospace font.`

The panel renders the Font Family combo box above Font Size, following the
existing form/dirty-row structure, plus a warning label hidden when the
projection carries none.

### Surface B: `danterm doctor`

Doctor gains one check reporting whether the configured family is installed.
The fact-gathering respects I2: the CoreText probe lives in Support and knows
nothing about config; reading and decoding `config.json` uses the Core document
type; the two are composed into the doctor facts DTO at the `cli/` boundary,
which compiles both modules same-module via its tracked symlinks. `danterm
doctor` stays local-only and app-independent.

Ladder: no config file or no `font.family` -> skip; config undecodable -> warn
(defaults active); family installed -> ok; family not installed -> warn naming
the font and the fallback. Warnings stay advisory -- doctor's exit code is
unchanged.

The config file path constant moves from `app/` into Support so both the app and
the CLI resolve it identically.

`integrations/danterm/SKILL.md` documents the new doctor row, as AGENTS.md
requires whenever the CLI's stdout shape changes.

## Implementation discretion

- Whether `.prefSave` keeps optimistically updating `model.config` and the
  runtime follows with the resolution, or defers the model write to the
  resolve-and-apply message entirely. Both satisfy I4; the tests below pin the
  outcome.
- Exact probe and catalog signatures and matching strategy, subject to the
  canonicalization rule in I3.
- Shape of the doctor config-facts DTO and how the CLI threads it into fact
  gathering.

## Non-goals / accepted risks

- **AR1: Installing or uninstalling the configured font does not continuously
  re-resolve live panes.** Resolution happens at config-apply time. Rationale:
  the reload menu item already exists and is the documented way to re-read
  config; watching the font registry is durable mechanism for a rare event. The
  combo box catalog refreshes when Preferences is opened, not while it remains
  open.
- **AR2: An installed but proportional face renders as asked, with no warning.**
  Explicitly scoped out above; the user chose "not installed" as the sole warned
  condition.

## Files touched

Core: config value type + JSON document, model, msg, update, projections, doctor
evaluator. Support: new font-availability and installed-family catalog queries,
plus the config path constant moved in from `app/`. Protocol: doctor facts DTO.
Render: `TerminalRenderExecution`. App: runtime, reconcile, preferences panel,
session view, backend seam. Plus the root `Package.swift` (CoreText for the CLI
target) and `integrations/danterm/SKILL.md`.

## Tests (TDD -- failing test first, in each case)

Behavioral and structure-insensitive; each pins a claim above.

**Core config** (`DanTermConfigDocumentTests.swift`, following the existing
`invalidThemeDegradesPerField` shape):
- A valid `font.family` string projects onto the config.
- An empty / non-string `font.family` is ignored while a sibling `font.size`
  still applies -- the per-field degradation claim.
- Clearing the family removes the key; unknown `font` siblings survive the write.
- A family round-trips through encode -> decode -> config.

**Core update/projection:**
- Applying a config with an unresolved family sets the model's config and leaves
  `resolvedFontFamily` nil; the preferences projection then carries the warning.
- Opening Preferences with an injected installed-family catalog projects those
  choices without an ambient CoreText query.
- The warning is nil once the draft text is edited away from the committed name
  -- the clear-on-edit claim.
- **I4:** a successful save of an installed family updates both the pane
  projection's key and the warning state with no reload message in between; a
  save of a non-installed family still emits the config-write command.
- `desiredPaneConfig` keys change when the resolved family changes, so reconcile
  re-pushes.

**Core doctor** (`DoctorEvaluatorTests.swift`): the four ladder outcomes against
stubbed facts, and that no outcome changes the exit code.

**Support** (`FontAvailabilityTests.swift`, new -- must compile under
`swift test --package-path lib/DanTermSupport`, which is the standing structural
proof of I2): `"Menlo"` resolves (it ships on every macOS); a garbage name does
not; and per I3, both `"Menlo-Regular"` and `"Menlo-Bold"` resolve to the
`Menlo` family rather than to themselves; the installed catalog contains Menlo
without duplicate family entries.

**Render** (`lib/TerminalCore/Tests/`): metrics built with no family are equal to
metrics built with an explicit nil family -- today's behavior is untouched;
metrics built with an installed family differ and still produce positive
whole-pixel cell dimensions.

**I5 render fallback** (`tests-ui`, since it needs a live view): a session view
configured with a family that passes availability but cannot produce grid metrics
still ends up with valid metrics and grid dimensions, and an existing pane's grid
is not left frozen. Drive the unusable-face case through the existing
`symbolsFontURL`-style test seam rather than depending on a specific installed
font being present on the machine.

**Preferences UI** (`tests-ui`, new): injected family choices populate the combo
box in order with `System Monospace (Default)` first; choosing the default maps
to an empty draft and choosing or typing a family updates the draft. Applying a
projection that carries a warning shows the expected text; applying one without
it hides the label; the panel still satisfies its layout constraints in both
states. The pure projection tests cannot prove this AppKit wiring.

## Verification

1. `just test` -- protocol + core + support + purity lint. Confirms the new
   `import CoreText` passes the portable profile, that no CoreText call leaked
   into `DanTermCore`, and (via the standalone Support package) that I2 holds.
2. `swift test --package-path lib/TerminalCore` for the metrics cases.
3. `just test-ui` for the fallback and Preferences-panel harnesses.
4. `just build-run`, then by hand:
   - Set `"font": {"family": "Menlo"}`, reload config from the menu -> panes
     re-render in Menlo with a correct grid, cursor, and box-drawing sprites.
   - Change the family in Preferences and save -> live panes repaint immediately,
     no reload needed.
   - Open the Font Family combo box -> installed proportional and monospace
     families are searchable; choose System Monospace -> Save removes the key.
   - Set a typo'd family -> the app launches, renders system monospace, shows no
     modal; the Preferences font row shows the warning; editing clears it.
   - Remove the key -> rendering is identical to before this change.
   - `danterm doctor` warns for the typo, reports ok once corrected, exits 0 both
     times.

## Commit progress

- [x] 1. Schema + JSON document support for `font.family` (core only; no UI, no
      rendering)
- [x] 2. Font-availability probe and installed-family catalog in Support +
      config-path move + CLI CoreText link
- [x] 3. Model contract: `resolvedFontFamily` and the single resolve-and-apply
      path through launch, reload, and save (I4)
- [x] 4. Render the resolved family end to end, including the system-monospace
      metrics fallback (I3, I5)
- [x] 5. Preferences installed-family combo box + inline warning
- [ ] 6. `danterm doctor` config-font check + `SKILL.md` update

## Implementation notes

- **Commit 2:** moving `DanTermConfigPaths` into Support forced a rename of
  `app/DanTermConfigPaths.swift` to `app/DanTermConfigStore.swift`. The app target
  compiles both `app/` and the `app/DanTermSupport` symlink into one module, and
  SwiftPM refuses two same-named sources in a module ("multiple producers"). The
  app file keeps only the store + error type, which the new name describes; the
  two references to the old filename (`test-ui.sh`, the Nix config-location design
  note) were repointed. `test-ui.sh` also had to add the Support path file to its
  compile list, since it compiles a hand-listed subset of sources and the store's
  default argument still resolves the path.

- **Commit 3:** the save leg took the plan's first discretion option (`.prefSave`
  optimistically updates `model.config`, the runtime follows with the resolution),
  and the follow-up is a resolution-only `.fontFamilyResolved(String?)` rather than
  a second `.configLoaded`. Re-sending `configLoaded` after a save also re-runs its
  draft reset, which would wipe an invalid font-size draft that `prefSave`
  deliberately leaves on screen (pinned by "invalid font size stays dirty while
  other fields save together"). The resolution is sent even when the disk write
  fails, matching the write-failure message's promise that the running settings
  stay active. Launch is the third caller and cannot send a `Msg` at all -- the Elm
  loop is not running during `AppRuntime.init` -- so it assigns the same pair
  directly; all three routes share the single `resolveConfiguredFontFamily`
  composition in `app/DanTermConfigStore.swift`, which is the only place the core's
  config type and Support's CoreText probe meet.

- **Commit 3:** `PaneConfigKey` gains the resolved family here rather than with the
  render commit, since it is a core projection and the plan's "keys change when the
  resolved family changes, so reconcile re-pushes" test belongs to the model
  contract. Until commit 4 consumes it, a family-only change makes
  `reconcilePaneConfig` re-push the (unchanged) theme and font size -- both
  idempotent.

- **Commit 4:** the I5 fallback lives in the session view, not in
  `TerminalRenderMetrics`. Metrics keep their single meaning ("this face cannot
  produce a usable grid") and return nil; the view is the layer that knows a
  second attempt is available, and it is also where the "existing pane frozen on
  its old grid" symptom would appear. Folding the retry into the initializer
  would have made a nil return unreachable and quietly changed what every
  existing caller's nil means.

- **Commit 4:** `test-ui.sh` compiles a hand-listed subset of sources and was
  already broken before this slice -- commit 2 put `resolveInstalledFontFamily`
  in Support but only added `DanTermConfigPaths.swift` to the list, so
  `DanTermConfigStore.swift` no longer compiled there. `just test-ui` is outside
  the `just test` gate, so nothing caught it. Adding `FontAvailability.swift` to
  the list is the minimal repair, and it was a prerequisite for running this
  slice's own harness.

- **Commit 4:** the I5 harness drives its unusable face through a named sentinel
  family on the UI shim's `TerminalRenderMetrics` rather than the `symbolsFontURL`
  seam the plan suggested. The shim already substitutes for the real metrics type
  in that harness, so a sentinel name is the seam that is actually reachable there;
  `symbolsFontURL` is an initializer parameter of the real type, which the UI tests
  never construct. The plan's actual requirement -- no dependence on a particular
  font being installed on the test machine -- holds either way.

- **Commit 5:** `System Monospace (Default)` is a reserved sentinel *on the draft*,
  not a panel-local display string. The combo box writes its selected item's title
  straight into `prefSetFontFamily`, and `resolveFontFamilyDraft` normalizes that
  one title back to nil alongside blank text. The alternative -- translating the
  entry to nil inside the panel -- loses to AppKit's ordering: after
  `comboBoxSelectionDidChange`, the combo also updates its text field, so
  `controlTextDidChange` fires with the selected title anyway and would have
  re-drafted it as a literal font name. One normalization point in the core beats
  two half-cases in the view.

- **Commit 5:** the catalog lives on `AppModel.installedFontFamilies` rather than
  inside `PreferencesDraft`. The draft is documented as "what the user actually
  typed"; the catalog is neither typed nor comparable for dirtiness, and it is
  panel-lifetime state exactly like the existing `committedGhosttyPrefs` sibling,
  so it follows that field's set-on-open / clear-on-close shape.

- **Commit 5:** the projected `fontFamilyText` is the raw draft, not the
  normalized value -- normalizing would let `apply()` rewrite the field under the
  user mid-edit (a trailing space would vanish as it was typed), which is why
  every other field in this projection is raw too.

- **Commit 5:** `PreferencesPanel` joins the UI harness, which needed the shim
  `AppRuntime` to gain the two inert `openDanTermConfig` / `reloadAllConfig` hooks
  the panel's "Config file" row calls, and the combo box, warning label, dirty row
  and reset button to be internal rather than private. The alternative -- digging
  the controls out of the `NSGridView` subtree by position -- would pin layout
  structure the tests have no business asserting.

## Follow Up

- A restore commits `model = staged.model` (`app/AppRuntime.swift#commitRestoreSession`),
  and `AppModel.config` / `resolvedFontFamily` are both ephemeral, so a restored
  session drops the on-disk config back to `.default` until the next config apply.
  This predates the font work -- theme and `font.size` are affected identically --
  but the font family now rides the same path. Worth deciding whether restore
  should re-apply the launch config instead of inheriting the snapshot's defaults.
