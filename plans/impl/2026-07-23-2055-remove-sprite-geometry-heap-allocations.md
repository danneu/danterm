# Remove per-draw heap allocations from sprite-geometry families

## Context

Commit `37424eb` replaced `BraillePixelLayout`'s two `[Int]` position arrays
with fixed inline scalar fields, because `[Int]` is the wrong representation for
a permanently-2x4 grid: it heap-allocates, permits invalid arity, and makes a
tiny immutable value look dynamically shaped. An audit of the other procedural
glyph families in `lib/TerminalCore/Sources/TerminalSpriteGeometry/` found the
same class of smell elsewhere. There is no sprite-geometry cache, so every
geometry entry point is recomputed on the per-cell draw path -- these are all
hot-path allocations.

This plan sweeps three independent cases. Each is representation-only: geometry
output must be byte-for-byte identical; no arithmetic changes. In every case the
allocation removal is **by construction** -- a heap collection type (`[...]`,
`Set`, a per-call array literal) is replaced by inline scalar storage, a
value-type bitmask, or immutable static storage. There is no optimizer-dependent
elision to measure: the source-level heap type is gone. Tests that read a removed
field get rerouted onto a public accessor, exactly as the braille change
rerouted onto `rect(column:row:)`. Read
`plans/impl/2026-07-23-1944-remove-braille-heap-allocations.md` for the
precedent before starting.

These three changes are independent and should land as **three separate
commits** in the order below.

---

## Change 1: `GeometricShapePixelTriangle` -- fixed scalar vertices, not a collection

A corner triangle is by definition exactly three vertices; the factory even
`assert`s `points.count == 3`. Today it stores `points: [SpritePixelPoint]`
(`GeometricShapeSpriteGeometry.swift:25`) and builds it from an array literal +
`.map` (lines 47-59) -- two heap allocations per call.

**Contract:**
- `GeometricShapePixelTriangle` stores its three vertices as fixed scalar
  storage (not a collection), preserving the closed-path vertex order. No
  computed collection accessor that re-presents the value as dynamically shaped.
- The factory computes the three vertices (applying the horizontal/vertical
  mirror per vertex) without building an intermediate array or mapped
  collection. Its retained invariant assertions must likewise compare the scalar
  coordinates directly -- no array/set/mapped-collection construction -- so the
  debug-build draw path stays allocation-free.
- The one render consumer, `TerminalRenderExecution.drawGeometricShapeTriangle`
  (~line 588), builds its `CGPath` directly from the three vertices, with no
  per-draw collection. `GeometricShapeSprite.swift` is untouched (it only
  forwards the geometry value).

**Test obligation** (`GeometricShapeSpriteGeometryTests.swift`): assert the same
vertex positions and closed-path order through the public scalar accessors,
covering the mirrored-corner and bounded-size-matrix cases already present
(lines 26, 40, 119-124). Collections constructed only inside tests are off the
hot path and are fine.

---

## Change 2: `BranchNodePattern.directions` -- a direction bitmask, not `Set<BranchDirection>`

`directions: Set<BranchDirection>` (`BranchDrawingSpriteGeometry.swift:23`) is a
`Set` over a fixed 4-element universe (`up/right/down/left`) -- morally a
bitmask, heap-allocating a Set buffer per pattern value. This repo already
models the identical concept as a `UInt8` `OptionSet` in `BlockElementQuadrants`
(`BlockElementSpriteGeometry.swift:11-22`); this change removes the allocation
and the inconsistency.

**Contract:**
- Represent `BranchNodePattern.directions` as a fixed value-type bitmask over the
  four cardinal directions, mirroring `BlockElementQuadrants`. The bit
  convention must match the existing `mask` bits used by the producer
  (`BranchDrawingSprite.pattern(for:)`, up=1/right=2/down=4/left=8) so the
  producer builds the bitmask directly from `mask` rather than reconstructing a
  collection.
- The node `masks` lookup table in `pattern(for:)`
  (`BranchDrawingSprite.swift:25-27`) becomes immutable static storage -- it is a
  compile-time constant currently rebuilt as an array literal on every
  classification. (Same treatment as Change 3.)
- The geometry consumer (`BranchDrawingSpriteGeometry.swift:137`) tests each
  cardinal direction's bit for membership; the `BranchDirection` enum stays for
  the `append(_:)` switch.

**Test obligation:** the direction-construction sites in
`BranchDrawingSpriteGeometryTests.swift:91,128` and
`BranchDrawingSpriteExecutionTests.swift:38-44` build/inspect directions through
the bitmask instead of a `Set`; branch connectivity behavior is unchanged.

---

## Change 3: Hoist compile-time-constant Legacy tables to `static let`

The Legacy Computing families rebuild constant lookup tables as fresh array
literals on every draw call. `LegacyComputingSpriteGeometry.swift` already hoists
one (`static let smoothMosaicGrids`, ~line 109) -- extend that pattern to the
rest.

**Contract:**
- The rule, not a fixed list: hoist **every** compile-time-constant array
  literal in `decode` and `runs` (`LegacyComputingSpriteGeometry.swift`) and in
  `sixteenth(...)` (`LegacyComputingSupplementSpriteGeometry.swift`) to
  `static let`. Audit each function for literals rather than working a
  checklist, so none is missed.
- Non-exhaustive examples to confirm the audit is complete: `policies`,
  `segments`, `shapes` and the two identical `masks` tables (in `decode` and in
  `runs`); `edgePairs`, `cornerTriangles`, `positions`; the inline
  eighth-fraction literals `[0, 2, 4, 7]` (the `0x1FB81` arm) and the
  `[2, 3, 5, 6, 7]` table that appears in two arms (`0x1FB82...0x1FB86` and
  `0x1FB87...0x1FB8B`); and the 32-entry `ranges` table in `sixteenth(...)`.
- **Verification gate (critical):** hoist a literal **only if** it captures no
  function parameter or local (e.g. cell width/height via `xs`/`ys`, a decoded
  index). Any table whose values depend on the call's inputs is genuinely
  per-call and must be left alone -- inspect each candidate and skip the ones
  that close over locals. This is a pure move for the truly-constant ones;
  behavior and output are unchanged.

This change adds no new types and touches no test-visible behavior; existing
Legacy suites are the regression guard.

---

## Out of scope (genuinely dynamic -- leave alone)

`BoxDrawingPixelGeometry.rects/strokes`, `BoxDrawingPixelStroke.points` (2-or-3
arity varies by kind), `BranchPixelGeometry.rects/arcs`, `BlockElement` return
rects, Legacy Computing run-length output and the per-cell pixel raster buffer,
Legacy Supplement return rects and `circlePieces`, and all Powerline
paths/commands. Their counts legitimately scale with the glyph or cell size.

## Accepted risks

- **AR1: The direction bitmask does not validate its raw value.** Mirroring
  `BlockElementQuadrants`, the bitmask type admits raw bits outside the four
  cardinal directions rather than normalizing or rejecting them. The producer
  only ever supplies masks from the fixed 16-entry table (values 0-15, all
  valid), and an out-of-range bit would render identically (unread). Adding
  validation would make this type stricter than the precedent it mirrors, for a
  state the producer cannot reach.

## Implementation discretion

Field names, any test helper shape, the exact enum-to-bit mapping mechanism, and
the precise `CGPath` call sequence are left to implementation. The plan fixes
only: fixed-arity scalar/bitmask representation, an allocation-free draw path,
preserved vertex order and direction-bit convention, and the behavioral proof
obligations above.

## Verification

- Per family, run the geometry + execution suites:
  - `swift test --package-path lib/TerminalCore --filter GeometricShape`
  - `swift test --package-path lib/TerminalCore --filter Branch`
  - `swift test --package-path lib/TerminalCore --filter LegacyComputing`
- Full gate: `just test` (core Swift Testing + core-purity lint + protocol +
  support). Confirms nothing else references the removed `points` array or the
  `Set<BranchDirection>` type.
- The execution suites (`*SpriteExecutionTests`) render to a bitmap and assert
  pixel output, so byte-for-byte-identical geometry is enforced, not just field
  equality. Allocation removal is guaranteed by the representation change itself
  (per Context), so no separate allocation-profiling gate is required.

## Commit progress
- [x] 1. GeometricShapePixelTriangle: fixed scalar vertices, not a collection
- [ ] 2. BranchNodePattern.directions: a direction bitmask, not Set<BranchDirection>
- [ ] 3. Hoist compile-time-constant Legacy tables to static let
