# One owner for the split ratio bound and the blank-font-size rule

Source: `docs/scratch/2026-08-26-improvement-audit.md`, MODEL-4 and MODEL-2
(Wave 9: one close vocabulary, one owner per rule). Two independent changes;
land as two commits, MODEL-4 first.

## Part A -- split ratio (MODEL-4)

### Problem

`SplitNodeModel.split` carries a bare `CGFloat` ratio. The restore builder
(`Model.swift#parseSplitNode`) stores whatever finite number the init file
holds; only the layout projection repairs it (`PaneLayout.swift#normalizedRatio`).
The snapshot codec and the IPC entity encoder pass the stored number through
raw. Evidence, checked against the tree: with `"ratio": 70` in a hand-authored
init file (a supported surface per the loader's own comment), the layout draws a
clamped split, `danterm ls` reports `70`, and every checkpoint writes `70` back.

Premises: the live drag path (`PaneLayout.swift#paneSplitRatio`) already yields
a finite value in `0...1` for any pointer, so restore is the only ingress that
can store an out-of-range ratio. `PaneGridOverride` already sets the pattern:
a failable value type, admission at ingress, no repair at use. PERSIST-6 (typed
split direction) has landed, so the split arm collision the audit named is gone;
PERSIST-2 edits the leaf arm and does not overlap.

### Decision

Give the ratio a failable bounded value type in the model, in the shape of
`PaneGridOverride`. Every holder of a split ratio -- the tree node, the ratio
mutation, the drag message, the layout's divider geometry -- carries that type,
so no reader is ever handed a number it must repair, and the projection's repair
is deleted. A persisted ratio that does not admit falls back to the same value an
omitted ratio gets (one half): an out-of-range ratio says nothing about which end
was meant, so unlike a font size there is nothing to clamp toward.

The JSON shape (`"ratio": <number>`) is unchanged on disk and on the IPC wire.

### Invariants

- I1. A split in the model never holds a ratio outside `0...1` or non-finite,
  from any ingress.
- I2. The ratio the snapshot writes, the ratio `danterm ls` reports, and the
  ratio the layout takes as input are the same stored number. The divider
  placement the view and accessibility read carries the effective ratio the
  layout actually drew (which minimum pane extents can pull away from the
  stored one), as it does today; that value is bounded too.
- I3. A persisted ratio that admits round-trips unchanged; one that does not
  admit restores as one half.
- I4. The core states the bound once; there is no second clamp or repair at
  projection.

### Proof obligations

- PO1 (I1, I2, I3): restore an init file whose split carries `"ratio": 70`;
  the exported snapshot and the IPC `ls` entity both report exactly `0.5`, and
  the projected pane rectangles equal those of the same tree with `0.5`.
  Restore `"ratio": 0.3`; snapshot and `ls` both report exactly `0.3`.
- PO2 (I1): a drag anywhere, including off-axis and non-finite pointer
  positions, yields an admitted ratio; a non-finite position yields the same
  ratio as a drag to the split's midpoint. (Existing `paneSplitRatio` tests
  cover finite positions only; the non-finite case is new.)
- PO3 (I2): in a container small enough that minimum pane extents constrain
  the split, the divider placement's ratio matches the drawn divider, not the
  stored ratio, and is in `0...1`.
- PO4 (I4): the projection's repair function is gone; a grep in `just lint`
  is not required -- deleting it is the change.

Existing suites that construct splits with literal ratios must keep compiling
and passing unchanged in meaning.

### Non-goals / accepted risks

- Non-goal: changing the on-disk or wire number format.
- Accepted risk: the ratio type touches every split construction site
  (~100 in tests). Rationale: a float-literal conformance keeps those sites
  textually unchanged.

## Part B -- blank font size (MODEL-2)

### Problem

`PreferencesDraft.fontSizeText` is `String?`; `nil` means "no `font.size` key".
The rule that turns an emptied field into `nil` lives in AppKit
(`app/PreferencesPanel.swift`, the field's change handler), so the core carries
a `""` state no surface can reach, the projection papers over it with `?? ""`,
and the same panel restates a second parse (`Double(text).map(boundedFontSize)
?? default`) to seed the stepper. The neighbouring setting already has the rule
in the core: `ModelOperations.swift#resolveFontFamilyDraft` normalizes blank
text to "no key". Vetted: no user-visible bug today; this is ownership.

### Decision

`fontSizeText` becomes a plain `String`; blank (after trimming) is the whole
"no key" state, and the core owns that rule through a peer of
`resolveFontFamilyDraft` that classifies drafted text as no-key, a bounded size,
or invalid. Save writes the first two and leaves the config untouched for the
third, keeping the text on screen for correction. The projection exposes the
resolved stepper value so the panel does no parsing of its own.

### Invariants

- I5. Blank or whitespace-only text saves as "no `font.size` key"; the field
  then shows empty over the default placeholder.
- I6. Unparseable non-blank text leaves the committed size unchanged and stays
  in the field.
- I7. The blank-means-no-key rule and the size parse exist in the core only;
  AppKit forwards the field's text verbatim. The projected stepper value is the
  bounded parse for valid text and the built-in default for blank or invalid
  text (today's panel behavior, preserved).

### Proof obligations

- PO5 (I5): seed `fontSize: 16`, set the draft text to `""` and to `"  "`,
  save; the config has no size and the projected field text is empty.
- PO6 (I6): set `"abc"`, save; size is still 16 and the projected text is
  `"abc"`.
- PO7 (I7): the projection's stepper value for a valid draft equals the bounded
  parse, and for blank and for `"abc"` (with committed size 16) equals the
  default; the panel reads it rather than parsing.

### Non-goals

- Changing what counts as a valid size (finite, positive, bounded) -- unchanged.

## Implementation discretion

- The ratio type's name and its literal conformance.
- The font-size resolution's return shape (enum vs. optional pair).

## Verification

`swift test --package-path lib/DanTermCore` plus `just lint` in the loop;
`just test` before each commit. After Part A, run a dev slot with an init file
carrying `"ratio": 70` and confirm `danterm ls` reports `0.5`. After each
commit, tick the item in the audit's `## Plan of work` with `-- done <sha>`.

## Commit progress

- [x] 1. fix(core): admit only bounded split ratios
- [ ] 2. refactor(preferences): make the core own blank font-size resolution

## Implementation notes

- The live init-file proof required reusable pooled-slot support. Entry 1 adds
  `just launch-slot --init <path>` so the app receives its normal `--init`
  argument while the launcher keeps ownership of the slot's isolated config,
  socket, checkpoints, bundle, and lock.
