# Import Themes Directly from iTerm2-Color-Schemes

## Problem and desired outcome

DanTerm now owns a tracked canonical collection in `themes/*.json`, but its
explicit importer and CI freshness check still read `lib/ghostty-themes/` and
validate provenance against `.ghostty-version`. That makes maintenance of
DanTerm's themes depend on Ghostty's version, build cache, and selected upstream
theme release even though iTerm2-Color-Schemes publishes the Ghostty-format
archive directly.

The current direct upstream release,
`release-20260720-153658-97e244c`, publishes `ghostty-themes.tgz` with SHA-256
`7329d0e2e958ee8404e516a6550bd07334edc611334a73f84d50477daa459f0c`.
The extracted archive contains 592 themes, and every theme satisfies DanTerm's
existing completeness contract. Relative to the tracked 463-theme collection,
it adds 129 names, removes none, and changes colors in eight existing themes:
Adwaita, Adwaita Dark, Catppuccin Frappe, Catppuccin Latte, Catppuccin
Macchiato, Catppuccin Mocha, Cursor Dark, and Electron Highlighter.

Desired outcome: DanTerm pins, verifies, and imports the upstream
iTerm2-Color-Schemes release directly. Theme updates and CI freshness checks no
longer require a Ghostty checkout, Ghostty build artifact, or Ghostty version,
while normal builds continue to consume only the committed JSON collection.

## Decision

- DanTerm owns an explicit pin for the iTerm2-Color-Schemes release, its
  `ghostty-themes.tgz` asset, and the asset's SHA-256. The import command obtains
  that exact artifact and rejects bytes that do not match the pin.
- Import remains an explicit, atomic update. It validates the complete archive
  before replacing tracked JSON and produces deterministic bytes, so a failed
  download, digest check, extraction, or theme parse leaves the collection
  untouched.
- Tracked provenance names iTerm2-Color-Schemes and the pinned release directly;
  it no longer names a Ghostty version or describes Ghostty as the source. This is
  a deliberate change to the provenance field set, so the pack validator
  (`scripts/pack-theme-catalog.py`), runtime catalog decoder
  (`lib/DanTermCore/Sources/DanTermCore/ThemeCatalogDocument.swift`), and their
  tests move together. The existing collection notice remains part of the tracked
  distribution.
- CI re-runs the direct importer and rejects any diff from `themes/*.json` without
  materializing `lib/ghostty-themes/`. Normal app builds remain offline: they
  validate and pack the committed JSON rather than fetching upstream content.
- The current direct release becomes the canonical collection. Its additions and
  color updates are intentional catalog changes; Swift-backend lookup, sorting,
  rendering, persistence, and theme selection behavior do not otherwise change.
  The legacy backend continues to resolve against its older raw catalog (AR3).
- Raw Ghostty-format files bundled for the legacy libghostty backend remain a
  separate compatibility artifact until that backend is removed. Their lifecycle
  does not determine DanTerm's JSON theme pin or freshness gate.

## Invariants

- **I1** Only an archive matching DanTerm's pinned release and digest can produce
  the tracked collection.
- **I2** Import is complete, deterministic, and atomic: invalid input produces no
  partial update, and the same pinned archive produces byte-identical JSON.
- **I3** The tracked collection is exactly the direct upstream archive projected
  into DanTerm's schema, with names and color values preserved.
- **I4** Theme import and CI freshness checking have no dependency on Ghostty's
  version, checkout, build, or ignored theme cache.
- **I5** Normal builds and the local test gate do not fetch upstream themes or
  rewrite tracked themes; builds continue to validate and pack the committed
  collection.
- **I6** Every tracked theme identifies the direct upstream collection and release,
  and the applicable collection notice remains distributed with it.
- **I7** The legacy backend's raw theme resources remain available without becoming
  an input to DanTerm's canonical theme import.

## Proof obligations

- **PO1** (I1, I2) Offline importer tests use committed archive fixtures to prove
  digest mismatch, corrupt archive, and incomplete-theme failures leave tracked
  output unchanged. The networked freshness job proves the real pinned archive
  downloads, verifies, extracts, and imports successfully.
- **PO2** (I2, I3) Re-importing the pinned release yields no diff. The imported name
  set exactly matches the archive, every shared name preserves all six named colors
  and 16 indexed palette colors, and stale tracked themes are removed only after a
  complete successful import.
- **PO3** (I3) A one-time review of the generated migration diff confirms 129
  additions, no removals, and color changes only in the eight identified shared
  themes. The durable assertion is the 592-theme total associated with this pin;
  that total moves when a future pin intentionally updates the collection.
- **PO4** (I4) Offline importer tests and CI freshness evidence pass with
  `.ghostty-version`, `.ghostty-src/`, and `lib/ghostty-themes/` absent. Only the
  networked freshness job exercises the real upstream archive; the local gate uses
  fixtures and validates the complete committed collection.
- **PO5** (I5, I7) The existing local test, build, and bundle contracts remain
  green without fetching upstream themes: tests exercise the importer from fixtures,
  ordinary builds pack the committed catalog without modifying it, and the legacy
  backend still receives its opaque raw resources. Collection-size expectations in
  the pack and bundle evidence match the pinned 592-theme collection.
- **PO6** (I6) Packed themes expose direct iTerm2-Color-Schemes provenance accepted
  by the runtime decoder, and the tracked notice and theme documentation identify
  the same release source.
- **PO7** Existing theme catalog, browser, per-pane rendering, restore, and OSC
  default-color behavioral tests remain green against the expanded collection.

## Non-goals

- Changing the private DanTerm JSON color and presentation fields, or making the
  format user-authored. The provenance field-set change is in scope.
- Automatically following the latest upstream release during ordinary builds or CI.
- Importing iTerm2 plist, terminal-specific formats other than the upstream
  Ghostty-format export, screenshots, or background images.
- Removing libghostty or its temporary raw theme resources.
- Renaming, filtering, or editorially modifying upstream themes during import.

## Accepted risks

- **AR1** Updating the pin intentionally changes the visible catalog: users gain 129
  themes and see upstream color changes in eight existing themes. Pinning the release
  keeps that change reviewable and prevents later upstream drift.
- **AR2** The explicit update and CI freshness jobs require network access to the
  pinned GitHub release. The local test gate remains offline, and app builds do not
  add a new network requirement beyond materializing their existing build
  prerequisites.
- **AR3** The non-default legacy libghostty backend keeps its older raw catalog while
  the shared browser exposes the new canonical collection. New-only themes therefore
  do not apply on that backend, and recolored shared themes can differ from their
  swatches; filtering or synchronizing a backend scheduled for removal would add
  transitional mechanism with no lasting value.

## Rejected ideas

- **RI1 Keep importing through Ghostty.** This preserves an unnecessary coupling:
  DanTerm's catalog release and provenance would continue to move only when Ghostty
  changes its own pin.
- **RI2 Follow the latest upstream release automatically.** An upstream publication
  could silently add, remove, or recolor themes. Theme updates remain explicit pin
  changes with a reviewable generated diff.
- **RI3 Import from the full upstream source repository.** The release's
  Ghostty-format archive already provides the exact complete values DanTerm needs;
  importing a broader source tree would add formats and conversion policy outside
  this outcome.

## Implementation discretion

- Where the upstream pin lives and whether the verified archive is cached between
  explicit update or freshness runs.
- Whether the importer retains a local-source override for development, provided
  canonical updates and CI evidence use the pinned verified archive.

## Implementation notes

- The importer accepts `--archive` for a local copy of the pinned release asset,
  but still verifies that copy against the canonical SHA-256. Without the option,
  explicit updates and CI download the pinned asset directly.
