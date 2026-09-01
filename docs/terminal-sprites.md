# Terminal Sprite System

DanTerm renders selected terminal glyphs as procedural sprites instead of
delegating them to a font. This document is the implementation contract for
that system: where decisions belong, how geometry is represented, which rules
all sprite families share, and which behavior is deliberately family-specific.

Read this document before changing sprite classification, geometry, rendering,
or tests.

## Purpose

Sprites give terminal-oriented symbols stable cell geometry independent of font
availability and fallback behavior. They are appropriate when a symbol's
meaning depends on exact contact with cell edges, repeatable pixel allocation,
or composition with neighboring cells.

The sprite system owns:

- the exact Unicode scalars DanTerm recognizes as procedural glyphs;
- the mapping from each supported scalar to a family-specific pattern;
- deterministic geometry in cell-local physical pixels;
- conversion and drawing at the Core Graphics boundary;
- degradation rules for cells too small to represent the preferred shape.

It does not own terminal character width, grid placement, text shaping, font
fallback for unsupported scalars, or terminal state.

## Architecture

Sprite work is divided between two layers:

```text
TerminalRenderExecution
  render-state integration, cell translation, and Core Graphics conversion
        |
        v
TerminalSpriteGeometry
  exact Unicode membership, pattern decoding, and declared ink reach
  deterministic cell-local physical-pixel geometry
  no Core Graphics, colors, display points, or terminal positions
```

`TerminalSpriteGeometry` decides whether a cell is a supported sprite and what
shape it is. Its inputs and outputs are value types, so both halves can be
tested without AppKit, Core Graphics, a display, or a terminal instance.

`TerminalRenderExecution` obtains the presentation inputs needed by that family,
translates the cell-local result to its terminal position, and draws it.

This boundary is part of the contract. Membership is one answer, in the pure
layer, because more than one stage of the renderer needs it: the executor
decodes a cell to draw it, and a consumer holding no metrics -- the frame
planner -- must be able to ask the same question. Geometry stays pure because
its allocation, symmetry, connectivity, and degradation rules must be
deterministic and exhaustively testable.

Every family declares its ink reach beside its decode, because membership does
not imply containment. All eight declare `.band` -- their geometry is cell-local
rects or paths clipped to the cell.

## Geometry contract

All sprite geometry is expressed in cell-local physical pixels. The cell's
origin is `(0, 0)`, and its dimensions are integer physical-pixel counts.
Hard-edged geometry uses integer coordinates and half-open rectangles:

```text
[minX, maxX) x [minY, maxY)
```

Display scale and terminal row or column translation are applied only by
`TerminalRenderExecution`. Geometry code must not use display points, terminal
positions, colors, `CGContext`, or other drawing-framework types.

Every family defines:

- its exact Unicode range or finite scalar set;
- its scalar-to-pattern mapping;
- its pixel allocation and rounding policy;
- its behavior at zero, minimum, and constrained cell sizes;
- whether it is contained, edge-connected, or intentionally overscanned;
- its required symmetry, shared axes, thickness, gaps, and coverage;
- whether it produces rectangles, paths, strokes, fills, or a combination;
- its antialiasing, cap, join, and clipping behavior at the render boundary.

Geometry calculations follow these common rules:

- Allocate scarce pixels for the whole shape, not for each part independently.
- Use controlled overlap for adjoining fills when it prevents background seams.
- Use exact partitions or explicit gaps for regions that must remain separate.
- Derive mirrored and rotated forms from shared geometry.
- Connected glyphs share center axes, thickness, and edge contact.
- Put assertions for pixel budgets, containment or bounded overflow,
  separation, connectivity, and permitted remainder beside the calculation.
- Define deterministic degradation instead of relying on incidental clipping or
  invalid geometry.

## Shared abstractions

`TerminalSpriteGeometry` is shared because it is pure, not because every
formula should be generic.

Start each new glyph family with a focused, family-specific implementation.
Promote a helper only when the current family genuinely requires it or a second
family demonstrates identical semantics. A promoted helper must have one
explicit allocation, rounding, and clipping policy.

The shared primitives in
[`SpritePixelGeometry.swift`](../lib/TerminalCore/Sources/TerminalSpriteGeometry/SpritePixelGeometry.swift)
represent cell-local integer points and half-open rectangles. Path commands,
fractions, strokes, transforms, overscan, and other helpers may remain local to
a family until another family needs the same semantics.

Similar formulas are not automatically the same abstraction. Shapes with
different seam, connection, scarcity, or clipping behavior should remain
separate even if their arithmetic looks alike.

## Glyph family models

Each family below is a model for a distinct kind of sprite behavior. New work
should copy the model whose invariants match, not simply the implementation
whose shape looks most similar.

### Braille

Braille models separated repeated elements with a whole-shape pixel budget.
Its scalar encodes a 2-column by 4-row dot pattern.

Use the Braille implementation as the model for:

- bit-pattern composition from a Unicode scalar;
- fair allocation of repeated elements and their gaps;
- minimum viable and zero-sized degradation;
- representative exact layouts plus a bounded invariant matrix.

Implementation:
[`BrailleSprite.swift`](../lib/TerminalCore/Sources/TerminalRenderExecution/BrailleSprite.swift)
and
[`BrailleSpriteGeometry.swift`](../lib/TerminalCore/Sources/TerminalSpriteGeometry/BrailleSpriteGeometry.swift).

### Block Elements

Block Elements model edge-aligned fractional fills and complete coverage of a
finite Unicode range.

Use the Block Elements implementation as the model for:

- exhaustive scalar mapping;
- fractional edge-aligned fills;
- allocation of odd-sized cells;
- controlled overlap where adjoining regions must not expose a seam;
- pure shade intent with renderer-owned color blending.

Implementation:
[`BlockElementSprite.swift`](../lib/TerminalCore/Sources/TerminalRenderExecution/BlockElementSprite.swift)
and
[`BlockElementSpriteGeometry.swift`](../lib/TerminalCore/Sources/TerminalSpriteGeometry/BlockElementSpriteGeometry.swift).

### Geometric Shapes

The supported Geometric Shapes are filled and outlined corner triangles. They
model contained, antialiased path geometry.

Use the Geometric Shapes implementation as the model for:

- deriving variants from one canonical shape by mirroring;
- antialiased paths that are explicitly clipped to the cell;
- inner outlines made by clipping a doubled stroke;
- explicit degradation when a cell cannot contain an outline.

Implementation:
[`GeometricShapeSprite.swift`](../lib/TerminalCore/Sources/TerminalRenderExecution/GeometricShapeSprite.swift)
and
[`GeometricShapeSpriteGeometry.swift`](../lib/TerminalCore/Sources/TerminalSpriteGeometry/GeometricShapeSpriteGeometry.swift).

### Box Drawing

Box Drawing models connected glyphs whose topology must remain continuous
within a cell and across neighboring cells.

Use the Box Drawing implementation as the model for:

- independently weighted cardinal arms on shared physical-pixel axes;
- endpoints whose perpendicular weights determine how far each arm enters a
  junction, including double-track turns and crossings;
- light, heavy, single, and double topology;
- centered whole-axis dash allocation with explicit leading, internal, and
  trailing gap budgets;
- deterministic scarcity handling, including double tracks degrading to heavy
  when two tracks and their gap do not fit;
- undersized dashed lines degrading to their solid weight;
- rounded corners and diagonal strokes represented as pure cell-local paths;
- antialiasing and explicit cell clipping at the Core Graphics boundary.

Implementation:
[`BoxDrawingSprite.swift`](../lib/TerminalCore/Sources/TerminalRenderExecution/BoxDrawingSprite.swift)
and
[`BoxDrawingSpriteGeometry.swift`](../lib/TerminalCore/Sources/TerminalSpriteGeometry/BoxDrawingSpriteGeometry.swift).

### Powerline

Powerline models private-use separators that deliberately contact cell edges
and may compose multiple filled or stroked paths.

Use the Powerline implementation as the model for:

- family-local fractional physical-pixel paths and cubic Bezier commands;
- mirroring complete paths, including curve control points;
- fill, regular-stroke, and clipped inner-stroke rendering;
- clamped curve radii and multiple paths composing one glyph;
- full-cell edge contact with explicit clipping for seamless adjacent segments.

Keep its path vocabulary family-local until another family needs identical
semantics.

Implementation:
[`PowerlineSprite.swift`](../lib/TerminalCore/Sources/TerminalRenderExecution/PowerlineSprite.swift)
and
[`PowerlineSpriteGeometry.swift`](../lib/TerminalCore/Sources/TerminalSpriteGeometry/PowerlineSpriteGeometry.swift).

### Branch Drawing

Branch Drawing models edge-connected lines, directional fades, compound arcs,
and circle nodes with optional cardinal connectors.

Use the Branch Drawing implementation as the model for:

- directional alpha fades allocated as deterministic physical-pixel strips;
- compound glyphs assembled from a canonical arc vocabulary;
- filled and outlined nodes aligned to the shared box-drawing axes;
- connectors that meet the node and their requested cell edges;
- structural snapshots that pin every compound topology.

Its quadratic arcs and pixel fades are deliberate DanTerm policies.

Implementation:
[`BranchDrawingSprite.swift`](../lib/TerminalCore/Sources/TerminalRenderExecution/BranchDrawingSprite.swift)
and
[`BranchDrawingSpriteGeometry.swift`](../lib/TerminalCore/Sources/TerminalSpriteGeometry/BranchDrawingSpriteGeometry.swift).

### Symbols for Legacy Computing

The two Legacy Computing families model large, heterogeneous scalar sets whose
members share a raster boundary but not one shape vocabulary.

Use these implementations as the model for:

- decoding every scalar to explicit topology before rasterization;
- testing scalar mapping independently from containment and rendering;
- family-local physical-pixel runs for mixed fills, shades, and strokes;
- bitmasks for partitioned and separated block mosaics;
- quantized light and heavy strokes that remain stable across display scales;
- translated ellipse descriptors for curves that continue across cells;
- simpler contained pixel rasterization when exact path construction adds no
  correctness benefit.

Implementation:
[`LegacyComputingSprite.swift`](../lib/TerminalCore/Sources/TerminalRenderExecution/LegacyComputingSprite.swift),
[`LegacyComputingSpriteGeometry.swift`](../lib/TerminalCore/Sources/TerminalSpriteGeometry/LegacyComputingSpriteGeometry.swift),
[`LegacyComputingSupplementSprite.swift`](../lib/TerminalCore/Sources/TerminalRenderExecution/LegacyComputingSupplementSprite.swift),
and
[`LegacyComputingSupplementSpriteGeometry.swift`](../lib/TerminalCore/Sources/TerminalSpriteGeometry/LegacyComputingSupplementSpriteGeometry.swift).

## Adding or extending a glyph family

Practice TDD and keep each step at the layer that owns its behavior:

1. Enumerate the exact supported scalars, pattern mapping, geometry invariants,
   clipping class, and minimum-size behavior.
2. Write failing behavioral tests and verify that they fail for the intended
   missing or incorrect behavior.
3. Add focused cell-local geometry to `TerminalSpriteGeometry`, reusing only
   primitives whose semantics match.
4. Add exact membership, pattern decoding, and the family's declared
   `SpriteInkReach` to `TerminalSpriteGeometry`, route the family from
   `spriteDecode(for:)`, and register it in `SpriteVocabularyTests`. Declare
   `.beyondBand` for an intentionally overscanned family: a consumer that prices
   a row's ink by the declared reach repaints that band and no more, so an
   overscanning family claiming the band would leave its overspill on screen
   after an incremental redraw. A family whose range starts below
   `spriteClassificationMinimumScalar` must also lower that floor -- the shared
   entry rejects sub-floor scalars before routing, so an unregistered family
   below it renders from the font, silently.
5. Add cell translation, display conversion, and drawing to
   `TerminalRenderExecution`.
6. Add the implemented scalars to `implementedRanges` in
   [`GlyphPreviewLayout.swift`](../lib/TerminalHostTools/Sources/GlyphPreview/GlyphPreviewLayout.swift)
   and update its corpus test.
7. Run the focused geometry and execution tests, the preview corpus test, the
   full `TerminalCore` suite, redraw-equivalence coverage, and
   `git diff --check`.

A family is complete only when its full declared scalar set and behavioral
coverage are complete. Do not silently accept a subset behind a range check.

## Test contract

Tests assert visible geometry and final composition, not helper names or a
particular sequence of arithmetic operations.

Pure geometry tests own:

- exact geometry at ordinary, odd, constrained, minimum, and degraded sizes;
- allocation and rounding;
- symmetry and rotation;
- containment or declared bounded overflow;
- separation, connectivity, gaps, coverage, and edge contact;
- bounded size matrices for claimed invariants.

Render-execution and bitmap tests own:

- exact scalar membership and mapping;
- scale and display-point conversion;
- color and shade composition;
- antialiasing, clipping, caps, and joins;
- cell translation and isolation;
- adjacency and layering;
- incremental damage redraw producing the same final image as a full redraw.

Prefer exhaustive mapping tests for finite ranges and representative geometry
goldens combined with bounded invariant matrices. Test observable behavior in a
structure-insensitive way so implementations can be improved without rewriting
tests that merely encoded helper structure.
