# Plane-independent nominal glyph routing

## Problem and evidence

The renderer asks the configured face for a nominal glyph only when a
single-scalar cell fits in one UTF-16 code unit. It sends every astral scalar
straight to the clipped CoreText fallback. Unicode plane therefore decides the
draw path even when the configured face maps the scalar without shaping.

This has two consequences:

- A configured font with astral coverage pays for one `CTLine` per mapped cell
  instead of using the nominal-glyph path used for mapped BMP cells.
- The packaged symbols face can rescue only BMP Private Use Area (PUA) misses.
  Supplementary PUA symbols depend on an installed fallback font even when the
  packaged face maps them.

The CoreText contract supports the required direction. Its nominal cmap API
accepts UTF-16 surrogate pairs, returns the full glyph in the first output slot,
and returns zero in the second. For an unmapped astral scalar, it returns zero in
both slots; the packaged face does so for U+1F600 while mapping other astral
scalars. A local probe found no supplementary mappings in the default system
monospace face, so ordinary emoji remains fallback work. The packaged Symbols
Nerd Font maps 3,500 BMP PUA scalars and 6,896 plane-15 PUA scalars, all with
one-cell advance; it maps no plane-16 PUA scalar. Its glyphs cannot be drawn as
one unclipped batch because 802 mapped glyphs cross a horizontal cell boundary.

## Decision

Resolve every single scalar by nominal cmap coverage rather than Unicode plane.
Keep the existing printable-ASCII shortcut, but let every other single scalar
reach the configured styled face whether its UTF-16 representation occupies one
or two code units.

Use this routing order:

1. A procedural sprite keeps first claim.
2. A nominal glyph in the configured styled face keeps second claim.
3. A configured-face PUA miss may use the packaged symbols face when that face
   maps it.
4. Everything else uses CoreText fallback.

The packaged face may claim mapped scalars in all three Unicode PUA ranges:
U+E000-U+F8FF, U+F0000-U+FFFFD, and U+100000-U+10FFFD. Draw its known nominal
glyph rather than asking CoreText to shape the scalar again, but preserve the
per-cell clip that keeps overhanging symbol ink out of neighboring cells.

Keep multi-scalar grapheme clusters on CoreText layout. Nominal cmap mapping is
not shaping and cannot replace that path.

Critical implementation and proof surfaces are
`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`
and `lib/TerminalCore/Tests/TerminalRenderExecutionTests/`.

## Invariants

- **I1. Plane independence.** Two single scalars mapped by the same configured
  face follow the same nominal-glyph policy even when one is BMP and one is
  astral.
- **I2. Precedence.** Sprite classification and configured-face coverage keep
  precedence over the packaged symbols face.
- **I3. Deterministic PUA coverage.** A configured-face PUA miss that the
  packaged face maps renders from that packaged resource, including in plane
  15; it does not depend on a font installed on the machine.
- **I4. Fallback fidelity.** An unmapped scalar and every multi-scalar cluster
  still receive CoreText font fallback and shaping.
- **I5. Grid ownership.** Font choice never changes terminal width or glyph
  origin. Packaged symbols and fallback content remain clipped to their planned
  cell spans. Configured-face nominal glyphs retain the existing unclipped
  overhang policy.
- **I6. Optional resource.** If the packaged symbols resource is unavailable,
  rendering follows the ordinary fallback path without partial symbol routing.
- **I7. Run isolation.** Reused draw scratch cannot carry candidates, glyphs, or
  positions from one styled run into another.

## Proof obligations

- **PO1 (I1).** With a deterministic configured face that maps an astral scalar
  whose ink escapes its cell, rendered ink appears outside that cell under the
  configured-face nominal-glyph policy. The clipped fallback path cannot satisfy
  this assertion. Mixed BMP and astral content also matches isolated controls at
  each planned column.
- **PO2 (I2).** Representative sprite, configured-face BMP PUA, and
  configured-face astral PUA cells render through their higher-priority owners
  when the packaged face also maps the scalar.
- **PO3 (I3).** Representative BMP and plane-15 packaged symbols are byte-equal
  to an independent clipped `CTLine` render of the scalar in the packaged face,
  positioned at the cell origin, at display scales 1 and 2. The BMP cases pin
  today's shipped symbol output while plane 15 adds deterministic packaged
  coverage. The packaged font census proves all 3,500 BMP and 6,896 plane-15
  mappings have one-cell advance and records that plane 16 currently has none.
- **PO4 (I4).** The same deterministic configured face used for mapped astral
  coverage returns zero in the first nominal-glyph slot for an unsupported
  astral scalar, which then keeps usable CoreText fallback output and cell
  containment. Ordinary emoji and multi-scalar clusters keep fallback and
  shaping as well.
- **PO5 (I5).** A packaged symbol cannot alter either neighboring cell, and a
  following ASCII glyph remains at its planned column. Incremental,
  row-restricted, and dirty-rect bitmap equivalence remains green. The current
  assertion that U+F0219 renders byte-identically with and without the packaged
  symbols face is intentionally replaced by PO3's packaged plane-15 contract.
- **PO6 (I6).** Rendering without the packaged resource matches the ordinary
  fallback result and leaves neighboring cells unchanged.
- **PO7 (I7).** Consecutive runs that use different combinations of configured
  astral glyphs, packaged symbols, fallback cells, and ordinary text each match
  the same run rendered alone.

Write each new behavioral test first and verify that it fails for the expected
routing or placement reason. Run the targeted renderer suite, then the full
`just test` gate with sandbox escalation.

## Non-goals, accepted risks, and rejected ideas

- **Non-goal:** Add or calibrate an astral benchmark workload. The change makes
  no directional speed claim; it claims only that a mapped configured-face
  astral cell no longer creates or draws a `CTLine`.
- **Non-goal:** Change grapheme formation, terminal width, font-family
  configuration, sprite coverage, or non-PUA fallback policy.
- **Accepted risk AR1:** The default system monospace face has no supplementary
  cmap coverage, so the nominal astral path benefits configured fonts rather
  than the default font. The plane-independent structure and deterministic
  packaged PUA behavior justify the change without projecting an emoji win.
- **Accepted risk AR2:** Configured-face astral glyphs may overhang a cell after
  they join the unclipped nominal path. This matches mapped non-ASCII BMP glyphs,
  and the existing general-text reach remains conservative for that behavior.
- **Accepted risk AR3:** The repository contains no deterministic configured
  face that maps a non-PUA astral scalar, so PO1 proves plane-independent routing
  with mapped plane-15 PUA and cannot by itself catch a future implementation
  that wrongly restricts configured-face astral lookup to PUA. The general I1
  contract and review of the shared nominal path remain the backstop.
- **Rejected idea RI1:** Cache per-cell CoreText lines. A cache preserves the
  plane-based routing error, adds font and style invalidation, and misses on
  changing content.
- **Rejected idea RI2:** Rely on an installed Nerd Font for supplementary PUA.
  That makes packaged behavior machine-dependent and cannot guarantee which
  face supplies the glyph.
- **Rejected idea RI3:** Draw all packaged symbols in one unclipped submission.
  The packaged font contains glyphs whose ink crosses a horizontal cell
  boundary, so that direction loses the grid-isolation contract.

## Implementation discretion

- The internal representation used to associate a scalar's UTF-16 code units
  with its resolved glyph, provided mixed BMP and astral candidates cannot be
  misindexed.
- The internal font-injection seam used by renderer tests, provided it does not
  expand the public API or depend on process-global font registration.
