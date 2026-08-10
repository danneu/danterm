# Nerd Font symbol rendering for private-use scalars

## Context

Neovim plugins that use Nerd Font icons (neo-tree, nvim-web-devicons, lualine)
render as `?`-in-a-box tofu in the Swift terminal engine. Powerline separators
render correctly, which makes the failure look selective: the separators are
procedural sprites (`PowerlineSprite.coarseRange`, U+E0B0-E0BF plus U+E0D2 and
U+E0D4), while devicons take the font path and find no font.

The desired outcome is that Nerd Font icons render in the Swift engine, in their
own cell, at a consistent size.

### Load-bearing premises

Both were measured against the shipped base face
(`.AppleSystemUIFontMonospaced-Regular` at 13 pt) on macOS 25.5 with
`SymbolsNerdFontMono-Regular.ttf` already installed in `~/Library/Fonts`.

**P1. CoreText does not perform font fallback for BMP private-use scalars.**
U+E0B0, U+F07B, and U+E5FF all resolve to `LastResort` (glyph 4 -- the tofu box)
from both `CTFontCreateForString` and `CTLineCreateWithAttributedString`. This
survives every way of requesting fallback: a cascade-list entry built from the
PostScript name, from the family name, from a descriptor explicitly advertising
the PUA character set, and via `NSFontDescriptor.cascadeList`. The same font used
as the run's *base* maps all three directly. Fallback on macOS is script-driven,
and private-use scalars have no script.

The exclusion is specific to the BMP block: U+F0219 (plane 15) already resolves
to an installed Nerd Font today, and CJK resolves to PingFang. So the gap is
U+E000-F8FF, and only DanTerm can close it.

**P2. The symbols font advances exactly 1 em for every icon.** U+F07B and U+E0B0
both advance 13.0 pt at 13 pt. DanTerm's cell is 8.04 pt wide (SF Mono's advance
is 0.618 em), so icons arrive 1.6x too wide for their cell.

## Decision

Route BMP private-use scalars to a DanTerm-selected symbols face, and size that
face so its em equals one cell.

The governing principle is to defer to macOS wherever macOS will take the work.
DanTerm supplies exactly one thing CoreText refuses to supply -- the choice of
face for a block it declines to fall back on (P1) -- and then hands the drawing
back to CoreText at its natural advance. Everything downstream is a CoreText
default: no glyph transform, no per-codepoint data, no measurement of individual
glyph bounding boxes.

**Routing.** The symbols face claims a scalar only where every existing path has
already declined it: sprite classification keeps priority, the base face keeps
priority over the symbols face, and the symbols route applies only to
U+E000-F8FF scalars the symbols face actually maps. Everything else -- ASCII,
CJK, emoji, combining clusters, supplementary-plane content, and private-use
scalars either face already handles -- keeps its current path unchanged.

The base-face precedence is load-bearing, not defensive. The shipped base face
maps five BMP private-use scalars (U+F6D5-U+F6D8 and U+F8FF, the Apple logo),
and the symbols face maps none of them; claiming the block unconditionally would
replace working glyphs with tofu.

**Sizing.** The symbols face is constructed at a point size equal to the cell
width, so its natural advance is exactly one cell. Because a single factor
applies to the whole font, every icon keeps its designed size relative to every
other icon. This is the property Ghostty's per-codepoint constraint table exists
to protect (`.ghostty-src/src/font/face.zig#constrainInner` reconstructs each
glyph's *icon-set* bounding box via `relative_width`/`relative_x` precisely so
that per-glyph scaling cannot make sibling icons inconsistent). DanTerm gets it
without the table because it scales the face, not the glyph.

The table's remaining work does not apply here: its `.stretch` mode exists for
glyphs that must tile seamlessly across cell edges, and DanTerm already draws
those procedurally.

**Font source.** `SymbolsNerdFontMono-Regular.ttf` (MIT, Nerd Fonts
`NerdFontsSymbolsOnly`) is vendored into the repository and bundled into the app,
with its `LICENSE` travelling alongside it. Relying on a system install was
rejected -- see RI2. One tracked copy must be reachable both from the assembled
`.app` and from `swift test --package-path lib/TerminalCore`, since the renderer
suite is where this behavior is proven and package tests cannot see the app
bundle.

Critical files: `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`
and the single shared resource-assembly step every build script already calls,
`scripts/bundle-theme-resources.sh`.

## Invariants

- **I1.** A BMP private-use scalar that the symbols face maps, and that no sprite
  family and the base face do not already claim, renders that font's glyph rather
  than a missing-glyph box.
- **I1b.** A private-use scalar the base face maps renders exactly as it does
  today. The symbols route never displaces a glyph an existing path produces.
- **I2.** Sprite-classified scalars keep rendering as sprites; adding the symbols
  face does not divert any scalar a sprite family claims.
- **I3.** A symbols glyph occupies exactly the cell it was planned into, and
  leaves neighboring cells byte-identical to a control render. Fallback still
  never becomes a source of grid geometry (`09-renderer.md` I: "font fallback
  changes glyph choice without changing grid geometry").
- **I4.** Routing for every non-PUA scalar is unchanged -- ASCII stays on the
  precomputed-glyph fast path, and CJK/emoji/combining clusters keep resolving
  as they do today.
- **I5.** When the symbols font cannot be loaded, every cell renders exactly as it
  does today -- private-use cells included, neighbors unaffected. The feature is
  absent, not partially applied.
- **I6.** The assembled app bundle contains the symbols font and its license.
- **I7.** The face used at runtime comes from the packaged font resource, not from
  whatever copy happens to be installed on the machine.

## Proof obligations

- **PO1** (I1): a private-use scalar renders ink that is not the `LastResort`
  box, in a bitmap fixture at scale 1 and scale 2.
- **PO2** (P1): a test pins that the base face neither maps a BMP private-use
  scalar nor resolves one through a cascade list. This is the premise the whole
  mechanism rests on; if a future macOS starts substituting, this test is what
  reports it.
- **PO3** (P2, sizing): every BMP private-use glyph the vendored face maps
  advances exactly one cell width at the configured size. Enumerated over the
  whole mapped set, not sampled -- the premise is universal, and a future font
  revision is the thing this catches. (All 3500 currently mapped glyphs advance
  1 em; the check is cheap.)
- **PO4** (I2): a scalar inside both the private-use block and a sprite family's
  supported set still renders as a sprite. Powerline is the live case.
- **PO5** (I1b): a private-use scalar the base face maps and the symbols face does
  not renders identically before and after the change. U+F8FF is the live case.
- **PO6** (I3): ink present in the cell span, the trailing cell byte-identical to
  a control render, and no ink beyond it.
- **PO7** (I4): the existing renderer suite passes unchanged. Separately, a
  supplementary-plane private-use scalar that resolves today keeps rendering
  identically -- the plan leans on that path being untouched, and no existing
  test covers it.
- **PO8** (I5): with the symbols face absent, private-use content renders
  identically to a control render taken without the symbols route, neighboring
  cells included.
- **PO9** (I6): an assembled bundle contains the font and its license.
- **PO10** (I7): the runtime face is the packaged resource, established
  independently of process-global font lookup -- the development machine has the
  same font installed, so a name-based lookup would otherwise satisfy every other
  proof here while shipping a broken app.

## Non-goals

- User-configurable font family or fallback list. `09-renderer.md` lists this as
  a non-goal for the first engine slice; the built-in face is swappable later
  without changing the mechanism.
- Porting Ghostty's per-codepoint constraint table.
- Changing supplementary-plane PUA or CJK behavior, which already work.
- Matching Ghostty's icon size pixel-for-pixel.

## Accepted risks

- **AR1.** Private-use cells stay on the per-cell fallback path, whose cost
  `docs/research/4-fallback-glyph-batching.md` measured. That document closed H3
  ("stateless fallback batching") with an explicit revival trigger: a profile
  showing non-sprite cmap misses dominating real output. An icon-dense sidebar
  could become that profile. Accepted because correctness comes first and the
  trigger is already written down; sizing the face to the cell also leaves
  batched drawing available later, since the advance now matches the cell.
- **AR2.** Icons read smaller than Ghostty's, which scales icons up toward an
  icon-height metric. Accepted for v1: the degradation is uniform rather than
  cropped or inconsistent, and a single factor adjusts it later.
- **AR3.** Vendoring a ~2.5 MB font establishes a third-party-asset convention
  the repo does not yet have. Theme provenance is currently carried inside each
  asset; a font cannot do that, so the license file ships beside it.

## Rejected ideas

- **RI1. Cascade list on the base face.** The obvious cheap fix. Measured not to
  work for BMP PUA in four spellings (P1). Recorded because it is the first thing
  any reviewer will propose.
- **RI2. Rely on a system-installed symbols font.** The font is already installed
  on the development machine and the icons still fail, so an install is not
  sufficient; and depending on one makes rendering non-deterministic across
  machines and invisible to CI. `GlyphPreview` currently depends on a Font Book
  install (`README.md` documents it) and should be able to stop.
- **RI3. Extend the sprite system to devicons.** `docs/terminal-sprites.md`
  scopes sprites to symbols whose meaning depends on exact cell-edge contact and
  explicitly disclaims "font fallback for unsupported scalars". Devicons are
  thousands of arbitrary pictographs with no such property.

## Implementation discretion

- The seam that lets a test render without the symbols route (PO8's control).
  Constructing the face is already an input; nothing here requires a runtime
  toggle or configuration surface.
- Whether private-use cells draw through the existing per-cell fallback path or
  as a per-run batch with the symbols face. I3 and PO6 constrain the outcome; the
  advance now matching the cell makes either viable. Default to the existing
  path -- it is the smaller change and already carries the containment clip.
- How the single tracked font file is made reachable from both the app bundle and
  the package test bundle.

## Implementation notes

- The tracked Symbols Nerd Font Mono 3.4.0 resource lives under the
  `TerminalRenderExecution` target. SwiftPM copies it into package test and tool
  bundles, while the shared app assembler copies that same directory into
  `Bundle.main`; the loader avoids SwiftPM's fatal missing-resource accessor in
  an assembled `.app`, so an omitted app resource degrades to the old rendering
  path as required by I5.
