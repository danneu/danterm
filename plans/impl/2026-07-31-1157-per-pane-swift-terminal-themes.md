# Per-Pane Themes for the Swift Terminal Engine

## Problem and desired outcome

Every layer of DanTerm's theme system above the pane session already works and is
backend-agnostic: `PaneModel.theme`, `effectiveTheme(for:)`, the remote-session
override, split inheritance, snapshot persistence, `danterm theme set`, the theme
browser, and `Reconcile.reconcilePaneConfig`'s `applyTheme`/`clearTheme` dispatch.
The Swift engine drops all of it on the floor --
`app/SwiftTerminalSessionView.swift#applyTheme` and `#clearTheme` are empty
bodies, and `TerminalPaneSession.swift#planIfNeeded` hardcodes
`RenderPresentation(theme: .dark, ...)`. `RenderTheme`'s memberwise init is
`private`, so `RenderTheme.dark` is the only theme that can exist.

Desired outcome: a Swift-engine pane renders the theme the user selected, through
every existing selection path, and reports that theme's default colors to
applications.

Themes also arrive in Ghostty's config syntax and are parsed at runtime, twice:
`app/ThemeCatalog.swift` scans the bundled `ghostty/themes/` directory and runs the
swatch parser over every file at startup. Ghostty's file format is an import format,
not something DanTerm should keep interpreting once libghostty is gone.

Load-bearing premises, both verified:

- All 463 files in `lib/ghostty-themes/` define `background`, `foreground`,
  `cursor-color`, `cursor-text`, `selection-background`, `selection-foreground`,
  and a complete `palette = 0=#...` through `15=#...`. None defines a link color.
  That is what makes an import that rejects incomplete themes achievable today
  rather than a future migration.
- The OSC 10/11 work in `plans/wip/osc-default-color-queries.md` is staged but
  uncommitted. It answers from a `TerminalDefaultColors.baked` static read
  directly inside `Terminal#dispatchOSC`. Per-pane themes make that static wrong,
  so this plan amends that work rather than layering on it.

## Decision

Own the theme collection in the repository, pack it at build time, resolve it at the
app boundary, and hand the engine a complete value.

- **`themes/*.json` is DanTerm's canonical, tracked theme collection.** One file per
  theme, committed, so a theme update reviews as a color-level diff. Ghostty syntax
  is an import format: a deterministic importer generates these files, and an
  explicit update command re-runs it when a newer Ghostty catalog is pulled in. The
  raw `lib/ghostty-themes/` cache stays ignored and is not a build input for
  DanTerm's runtime -- only for libghostty's own loader (AR5). When that backend
  goes, the cache and AR5 go with it and DanTerm's themes are unaffected.
- **Import is explicit; builds validate and pack but never rewrite.** No build path
  regenerates or edits a tracked file. Every runnable app build validates each
  committed theme and packs them into one bundled catalog resource, so the runtime
  performs a single read and a single decode. CI additionally re-runs the importer
  and fails on any diff against the tracked files, which is what keeps "committed"
  and "derivable from the sources" the same thing.
- **One shared validate-and-pack step, on every build path.** Five scripts assemble
  a runnable `.app` with their own theme-copy block today: `build-app.sh`,
  `dev-build.sh`, and the `scripts/terminal-{benchmark,characterization,viability}.sh`
  harnesses. The packing and its validation live in a single step all five -- and any
  future assembler -- invoke, rather than being duplicated per script. An assembler
  that copies raw Ghostty themes and stops now yields a bundle with no themes at all,
  so this is a correctness requirement, not tidiness.
- **Each tracked theme records its provenance** -- the upstream collection and the
  release it was imported from -- so a redistributed color set is traceable to its
  source. Committing the collection makes DanTerm a redistributor rather than a
  consumer of a build artifact, so the applicable upstream notice must be confirmed
  and carried in-repo before the import lands.
- **The schema** carries a schema version, the theme name, foreground, background,
  cursor and cursor-text, selection foreground and background, and the 16 ANSI
  palette colors in ANSI index order 0 through 15. On import, index order comes from
  each source entry's explicit `palette = N=` index, never from source line order.
  Whether renderer-derived presentation colors are baked at import or derived
  deterministically at load is discretion; either way the same input yields the same
  colors.
- **Name to theme, app-side.** A pure all-or-nothing decode in `DanTermCore` turns
  one theme entry into a complete theme value; an `app/` bridge maps it to
  `RenderTheme`. A malformed resource yields no theme at all, never a partially
  configured pane. The engine never reads a theme resource, and `TerminalCore`
  gains no dependency on `TerminalRenderPlanning`.
- **The catalog and browser consume the packed catalog.** Theme names, sort order,
  and picker behavior are unchanged; the swatch colors the browser renders are a
  projection of the decoded theme rather than a second parse of a second format.
- **`RenderTheme` becomes constructible**, with the ANSI palette held at exactly
  16 entries by construction rather than an array plus a runtime check. Indices
  16-255 keep today's xterm cube and greyscale formulas and stay theme-independent.
- **`RenderTheme` gains `selectionForeground`**, sourced from every theme file,
  and the frame planner forces it on selected cells. `searchMatchBackground` has
  no source in any theme file and is derived (see discretion).
- **The pane's theme is an explicit input at both ends.** A resolved theme reaches
  `TerminalPaneSessionController` at construction, so a pane created with a theme
  never plans a `.dark` first frame; a `setTheme` mutator handles live switches by
  marking full damage and republishing.
- **OSC 10/11 answer from per-pane state.** `Terminal` carries injected
  `TerminalDefaultColors` instead of reading the `baked` static, so a themed pane
  reports the colors it actually paints. `TerminalCore` still receives neutral RGB
  values, never `RenderTheme`.
- **`clearTheme()` returns the pane to `RenderTheme.dark`**, since a global default
  theme for the Swift backend is out of scope.
- **An unresolvable theme leaves the pane's presentation untouched.** The reconciler
  caches the key it dispatched and will not retry, so reverting to `.dark` would
  turn a transient read failure into a permanently wrong pane; a no-op is stale but
  coherent.

## Invariants

- **I1** A pane renders the theme named by its effective theme; a pane with no
  effective theme renders the baked dark theme.
- **I2** A theme value is complete by construction. No missing field, invalid color,
  or partial decode can produce a pane with some colors themed and others not; an
  incomplete theme fails the import or the build instead of reaching the bundle.
- **I2b** The tracked collection is exactly what the importer derives from the pinned
  Ghostty catalog, and no build path writes to it.
- **I3** `OSC 10;?` and `OSC 11;?` report the same default foreground and background
  the pane's frames are planned from, including after a theme switch.
- **I4** The engine reads no theme resource, and `TerminalCore` depends on neither
  `TerminalRenderPlanning` nor AppKit.
- **I4b** No DanTerm-authored code -- engine, app runtime, or catalog -- interprets
  Ghostty theme syntax. Ghostty theme files are read only by the importer and by
  libghostty's own config loader on the legacy backend; no build path reads them to
  produce DanTerm's runtime themes.
- **I5** A theme change republishes the pane's entire frame. No cell, decoration, or
  reused row retains a previous theme's colors.
- **I6** Selected text renders `selectionForeground`, except under a visible block
  cursor, which keeps `cursorText` on `cursor`.
- **I7** A theme apply that cannot be resolved leaves the pane's presentation
  exactly as it was.
- **I8** A theme name that is not a bundled theme cannot cause a file read outside
  the themes directory.
- **I9** For every bundled theme, `searchMatchBackground` is distinguishable from
  both that theme's `selectionBackground` and its `defaultBackground`.

## Proof obligations

- **PO1** (I1, I3, I5) On a quiescent controller, `setTheme(other)` publishes exactly
  one full-damage frame whose planned colors are the new theme's; `setTheme(same)`
  publishes nothing. A hidden pane publishes on the next `setVisible(true)`, and a
  pane inside a DEC 2026 synchronized update publishes when the update ends --
  deferred, never lost. `clearTheme()` on a themed pane publishes one full-damage
  dark frame and restores the baked default colors OSC 10/11 answer with; a
  `clearTheme()` on an already-dark pane publishes nothing.
- **PO2** (I1) A pane constructed with a theme already selected plans its first
  frame in that theme, covering both split inheritance and snapshot restore. The
  pane's view fills with that theme's background before its first draw and renders
  the controller's retained first plan without waiting for child output, so a
  restored themed pane never shows dark.
- **PO3** (I2) Runtime decode is all-or-nothing, parameterized over every schema
  field: removing any one, corrupting its color, giving the palette other than 16
  entries, or an unknown schema version yields no theme value at all and no
  partially configured pane.
- **PO4** (I1, I2) Import is total and faithful: run over every file in
  `lib/ghostty-themes/`, it emits one tracked theme per source theme under the same
  name, each round-tripping all six named colors and all 16 palette entries. Palette
  placement follows each entry's declared index, not its line position: a fixture
  whose `palette = N=` lines are shuffled imports identically to the same fixture in
  ascending order. A source theme missing a required key, carrying an invalid hex, or
  having an incomplete palette fails the importer rather than emitting a theme.
- **PO4b** (I2b) Re-running the importer against the pinned Ghostty catalog leaves
  the tracked collection byte-identical -- the CI freshness gate. Import output is
  deterministic: the same sources yield the same bytes across runs.
- **PO4c** (I2, I2b) Every script that assembles a runnable `.app` --
  `build-app.sh`, `dev-build.sh`, and the benchmark, characterization, and viability
  harnesses -- validates every tracked theme, fails the build if any is invalid,
  packs them into the bundled catalog, and leaves the tracked files unmodified.
  Proved per assembler, so an assembler that skips the shared step fails this
  obligation rather than silently shipping stale or absent resources. `test-ui.sh`
  is out of scope: it links a standalone test executable and assembles no bundle.
- **PO5** (I3) A `Terminal` constructed with non-baked defaults replies with them,
  and after a live `setTheme` a pane answers both queries with the new theme's
  colors. Bytes submitted before the switch answer with the old pair and bytes
  submitted after answer with the new one, in one ordered reply stream.
- **PO6** (I4, I4b) The existing purity and backend-boundary gates pass, with any
  allowlist growth named in review rather than silently widened. A gate asserts that
  no DanTerm-authored runtime source interprets Ghostty theme syntax -- the source
  format is reachable only from the importer and libghostty's own loader.
- **PO7** (I5) Extending the existing reuse-equals-from-scratch check: for set,
  extend, shrink, move, and clear selection, a damage-driven replan equals a
  from-scratch plan. This is now load-bearing, because retained rows carry the
  selection foreground.
- **PO8** (I6) Under a theme whose `selectionForeground` differs from every cell
  foreground, selecting a span changes exactly the selected cells' foregrounds and
  leaves background runs, selection runs, and the cursor byte-identical. A block
  cursor inside a selection draws `cursorText` on `cursor`, proved as pixels. A
  cell covered by both selection and the active search match draws
  `selectionForeground` over `searchMatchBackground`.
- **PO9** (I6) A uniformly styled row selected from a mid-row column produces
  exactly two text runs whose concatenated cells equal the unselected row's run.
- **PO10** (I1, I7) A theme name absent from the catalog, a resource that cannot be
  read, and a resource that fails to decode each leave the pane rendering what it
  rendered before.
- **PO11** (I8) A name containing path traversal resolves to no theme and reads no
  file. `remoteThemeOverride` arrives over IPC and flows into the dispatched theme
  key unvalidated, so this is the reachable path.
- **PO11b** (I2, I4b) The built `.app` contains the packed catalog, and every theme
  name it lists decodes to a complete theme value from the bundle as actually shipped
  -- proving the packing step, not just the importer in isolation. The runtime
  catalog exposes exactly the tracked theme names, in the existing case-insensitive
  sort order, and each browser swatch is projected from that theme's own decoded
  value.
- **PO12** (I9) The derivation is deterministic and, run across every bundled
  theme, yields a `searchMatchBackground` separated from both that theme's
  selection and default backgrounds by at least the separation today's baked
  constant achieves. Separation is the sum of squared per-channel differences over
  the three 0-255 components; candidate generation and tie-breaking stay
  implementation discretion.
- **PO13** (I1) Under a theme whose 16 palette entries are all distinct from the
  baked ones, cells written with SGR indices 0 through 15 plan that theme's
  corresponding entry, and representative indices from the 16-231 cube and the
  232-255 greyscale ramp plan the same colors they plan under `.dark`.

### Verification

`just test` covers the importer, the decode, derivation, engine planning, and the
purity and boundary lints. CI adds the re-import-no-diff freshness gate, which needs
the pinned Ghostty catalog present. `just test-ui` covers the session view's dispatch
seam and the pre-frame fill. The bundle check runs against a built `.app`. End-to-end:
`just build-run`, open a pane, `cmd-shift-B` to pick a theme and confirm the browser
still lists every theme with its swatch and that the pick applies live; split the
pane and confirm the child inherits it;
restart and confirm restore keeps it without a dark flash; run
`printf '\033]11;?\033\\'` in a themed pane and confirm the reply matches the
painted background.

## Non-goals

- A global default theme, preferences-panel support, or a real `reloadConfig()` for
  the Swift backend.
- A public, user-authored theme format. `themes/*.json` is tracked and reviewable but
  private: its schema is not a configuration API, carries no stability or
  compatibility promise, and users cannot hand-author or drop in a theme file.
- Hand-editing a tracked theme. The collection is importer output; a color change
  belongs upstream or in a later DanTerm-authored theme, not in an edited import.
- User-visible changes to theme names, catalog ordering, or picker behavior.
- OSC 4/10/11 color setting and OSC 104/110/111 reset.
- A link color, a themed 256-color cube, or configurable font and line height.

## Accepted risks

- **AR1** Giving `RenderTheme.dark` a `selectionForeground` changes how styled
  selected text renders under the default theme: red text inside a selection now
  draws the selection foreground. This is the intended behavior and follows from
  the decision, but it is a visible default change, not a pure refactor.
- **AR2** With no global default in scope, a Swift-backend pane that has no per-pane
  theme renders dark even when the user set a global theme in preferences. Users who
  theme globally rather than per-pane see no effect. This is the largest visible gap
  the chosen scope leaves.
- **AR3** A theme applies to rendering synchronously on the main actor but to OSC
  replies through the PTY host's serial queue, so a query already in flight can
  answer with the previous theme. Correct by ordering, and closing it with a fence
  per switch would stall the main actor for no user-visible gain.
- **AR4** Per-pane default colors join `Terminal`'s synthesized equality, which
  couples them to recording-replay comparisons. Replay needs the same injection
  point the machine hostname already uses, or a later theme-unrelated test fails.
- **AR5** The legacy libghostty backend applies a theme by handing the source file to
  `ghostty_config_load_file`, so the raw Ghostty themes stay in the bundle as opaque
  input to libghostty's own loader until that backend is removed. Dropping them now
  would break per-pane theming on the currently-default backend; no DanTerm code
  reads them, so I4b holds.

## Rejected ideas

- **RI2 Make `TerminalCore` depend on `RenderTheme`.** Reverses the existing
  dependency direction; render planning consumes terminal state, not the reverse.
- **RI3 Parse Ghostty theme syntax at runtime.** Keeps an import format as an
  architectural dependency, splits completeness rules between a swatch parse and a
  full parse, and defers every malformed-theme failure to the moment a user picks
  the theme instead of to the build.
- **RI7 Regenerate the runtime themes from the raw Ghostty cache on every build.**
  Makes DanTerm's canonical theme collection a function of an ignored,
  externally-sourced artifact: no reviewable diff when a color changes, and the
  collection cannot outlive libghostty's removal without a migration.
- **RI4 Fall back to `.dark` when a theme fails to resolve.** The reconciler will not
  retry the same key, so a transient failure would persist as a wrong-looking pane.
- **RI5 Leave OSC 10/11 answering from the baked static.** A themed pane would then
  lie about its background, recreating the Codex contrast bug the OSC work exists to
  fix.
- **RI6 Carry `selectionForeground` in `RenderFramePlan`.** It is baked into each
  text run's foreground; a plan field would be dead data the executor ignores and a
  second place for the plan and its runs to disagree.

## Implementation discretion

- The `searchMatchBackground` derivation. It must be total, deterministic,
  integer-only, and threshold-free; the intended shape is "furthest from both the
  selection and default backgrounds among a small fixed candidate set that includes
  today's baked constant", which makes the degenerate-palette case fall back on its
  own rather than through a special branch.
- The fixed-arity palette representation, and whether index lookup is total or
  optional at the resolver.
- The packed catalog's on-disk layout, and whether renderer-derived presentation
  colors are baked at import or derived at load; both are invisible above the decode
  boundary as long as the result is deterministic.
- Where provenance lives -- a field per theme file, a manifest beside them, or both
  -- so long as a tracked theme is traceable to the upstream release it came from.
- The internal threading that carries the selected theme across existing
  initializers, and how the planner's "already planned" check learns about
  presentation.
- Whether the app-side bridge earns its own file plus a named boundary-lint
  allowlist entry, or lives in the already-allowlisted backend adapter.

## Critical files

- `lib/TerminalCore/Sources/TerminalRenderPlanning/TerminalRenderPlanning.swift` --
  `RenderTheme` construction, palette arity, `selectionForeground`.
- `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift` --
  selection foreground override, ordered after reverse/dim and before the cursor.
- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` and
  `TerminalDefaultColors.swift` -- per-pane defaults replacing the staged static.
- `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift` and
  `TerminalPaneLaunch.swift` -- initial theme and `setTheme`.
- `themes/*.json` -- new: the tracked canonical collection, plus its provenance and
  upstream notice.
- `lib/DanTermCore/Sources/DanTermCore/ThemeColorParser.swift` -- the Ghostty-syntax
  parse, which moves to the importer; the pure all-or-nothing JSON decode replaces
  it as the runtime path.
- `app/ThemeCatalog.swift` and `app/ThemeColorFileLoader.swift` -- discovery and
  swatches, repointed at the packed catalog with names and ordering unchanged.
- `build-app.sh`, `dev-build.sh`, and
  `scripts/terminal-{benchmark,characterization,viability}.sh` -- today each bundles
  themes with its own block and its own source-path fallback; all five must route
  through the one shared validate-and-pack step. The raw Ghostty themes stay only for
  libghostty's loader (AR5).
- `.github/workflows/ci.yml` -- the re-import-no-diff freshness gate.
- `app/SwiftTerminalSessionView.swift`, `app/SwiftTerminalBackend.swift`,
  `app/AppRuntime.swift` -- the bridge, the initial-theme path, and the two
  no-op stubs.
- `scripts/terminal-backend-boundary-lint.sh` and `tests-ui/` shim -- gates that
  must move with the change.

## Commit progress

- [x] 1. feat(themes): import canonical theme catalog
- [x] 2. build(themes): pack the runtime theme catalog
- [x] 3. feat(renderer): support complete theme presentation
- [ ] 4. feat(terminal): apply themes per pane

## Implementation notes

- The packed layout is `Contents/Resources/themes/catalog.json`, with a catalog
  schema version and one case-insensitively sorted array of the complete tracked
  theme documents, including provenance.
- The renderer stores ANSI colors as 16 fixed fields behind a failable array
  boundary. Search-match backgrounds choose the maximum minimum squared RGB
  distance from selection and default backgrounds across three fixed candidates;
  the candidates include the previous baked search color and deterministic
  fallbacks, so the result is never less separated than the old color.
