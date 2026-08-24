# Correct Packaged Nerd Font Symbol Geometry

## Problem

DanTerm sets the symbols face's point size from the cell width. At the
default Retina geometry this is 8.5 pt, while normal text is 13 pt. This
makes U+E0A0 and similar symbols visibly short.

The symbols face must use normal text height when its ink fits without changing
terminal cell geometry or distorting glyph aspect ratios.

## Decision

Render the packaged symbols face at the configured text size. Fit and center each
mapped glyph from its ink bounds with one isotropic, never-magnifying rule.

- Derive the symbols face's starting size from the metrics' `baseFontSize`,
  including when a caller supplies a base font whose size differs from the cell
  box used by the metrics.
- Scale each nonempty glyph uniformly by the smaller of its horizontal fit,
  vertical fit, and 1. A glyph that already fits keeps its configured size; no
  glyph is magnified or stretched.
- Center the fitted ink bounds horizontally and vertically in the planned span.
  A mapped glyph with no ink remains blank.
- Apply the same rule to every mapped packaged glyph. Do not add per-codepoint
  policy or generated metadata.
- Keep the existing span clip as the final containment boundary. Unusual outline
  overshoot may be clipped, but it cannot affect adjacent cells.
- Preserve routing precedence: procedural sprites, configured-font glyphs,
  packaged PUA symbols, then normal fallback.
- Amend renderer decision D3 in
  `docs/design/2026-08-06-swift-terminal-engine.md` with this isotropic,
  shrink-only fitting and centering contract.

`PackagedSymbolsFace.face(pointSize:)` remains the public untransformed
reference-font API used by GlyphPreview. This change adds no public API,
configuration, or terminal protocol.

## Invariants

- **I1.** U+E0A0 renders at configured text size when its ink fits the cell and
  retains its source aspect ratio.
- **I2.** Every packaged symbol stays inside its planned span and cannot
  change grid geometry or neighboring cells.
- **I3.** Fitting is isotropic and never magnifies a glyph, so rendered outlines
  retain their source aspect ratio.
- **I4.** Each fitted ink box is centered horizontally and vertically in its span.
- **I5.** Missing or unreadable symbol resources retain the existing fallback
  behavior.
- **I6.** Symbol geometry starts from the metrics' own base font size and fits
  into that metrics value's cell box at its display scale.

## Proof Obligations

- **PO1 (I1, I4).** At 1x and 2x, a lualine-style U+E0A0 followed by ` master`
  has at least the regular font's cap height and vertically centered padding to
  within one backing pixel.
- **PO2 (I2).** Rendered ink bounds stay inside the planned span, a full-em icon
  uses the available span width instead of being silently clipped, and neighboring
  text matches an independently positioned control.
- **PO3 (I3).** Representative narrow, full-em, and plane-15 symbols retain their
  source aspect ratio within backing-pixel quantization, and a fitting glyph is
  never magnified. A mapped zero-ink glyph renders blank and leaves later cells
  unchanged.
- **PO4 (I6).** Representative font sizes, display scales, and the Menlo family
  derive symbol geometry from the metrics' base font size and cell box. This
  includes the test seam whose supplied base-font size differs from its grid.
- **PO5 (I5).** Existing proofs for absent resources, resource identity,
  sprite/configured-font precedence, and raw public reference-face projection
  remain green. Retire the existing point-size and font-advance assertions, which
  no longer define grid geometry, in favor of PO2's rendered containment proof.
  Replace the natural clipped-layout comparison with PO3's fitted aspect-ratio
  and centering proof.

Write PO1's failing test first and verify that it fails because the branch ink
is shorter than regular text. Run the targeted `TerminalRenderExecutionTests`
suite and `just lint` during the loop, then run `just test` as the final gate.

## Accepted Risks

- **AR1.** Shrink-only fitting makes narrow icons appear larger than wide icons;
  preserving each glyph's aspect ratio without magnification takes priority over
  uniform apparent size across the face.

## Rejected Ideas

- **RI1. A face-wide anisotropic transform.** Mapping the font's em width to the
  cell while keeping text height vertically stretches square and round icons.
- **RI2. Ghostty-style generated metadata.** It adds font-version-specific
  per-icon policy where measured ink bounds already provide one general rule.
- **RI3. A U+E0A0 special case.** It leaves the same defect possible for other
  symbols and cell aspect ratios.
- **RI4. A user-facing icon-size setting.** One correct derived geometry is
  sufficient; configuration would expose an engine defect as user policy.

## Implementation Discretion

- Where the per-glyph fit calculation lives is implementation discretion; it
  must not introduce codepoint-specific policy.

## Commit progress

- [x] 1. fix(renderer): fit packaged symbols without distortion
