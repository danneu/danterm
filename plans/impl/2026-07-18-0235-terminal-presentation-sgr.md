# Milestone 2 slice 5: terminal presentation state and SGR/reset behavior

## Context

Fifth implementation slice of Milestone 2, governed by
`plan-terminal-engine/04-terminal-core.md` (16/256/RGB presentation
attributes; bold, dim, italic, underline, reverse, hidden, strike;
background-color erase semantics; malformed-sequence recovery) and the
neutral-fixture mandate in `docs/research/1-external-tests.md`, which names
libvterm `t/30state_pen.test` and `t/64screen_pen.test` as Milestone 2
adoption material.

Why now: styled prompts are required before an interactive zsh pane is
meaningful, and style-bearing cells exercise the slice 4 reflow machinery
before PTY integration.

Load-bearing premises (verified against the code):

- The engine (`lib/TerminalCore`, standalone package, no app wiring) has no
  style state anywhere. `EscapeAbsorber` already delivers complete SGR
  `CSISequence` values -- colon sub-parameters are gated to final `m` only --
  and `Terminal.dispatchCSI` currently drops final `m` via `default: break`.
- Reflow moves whole private grid cells, so a style field on the cell rides
  scroll-off and reflow automatically; only synthesized cells (reflow-built
  wide tails, spacer heads, blank filler) need explicit decisions.
- The absorber drops a trailing empty parameter (`\e[31;m` dispatches
  `[31]`), diverging from ECMA-48/xterm/libvterm where a trailing `;` is an
  empty (= 0) parameter.
- Existing erase tests assert only cell kinds, text, and pending state, so
  they stay green under a default pen; the one existing test that must
  change is `CSIParserTests.uninterpretedDispatchIsNoOp`, which pins
  `\e[31m` as a bit-identical no-op.

## Decision

Introduce a semantic pen: a current-style value on `Terminal`, updated by
SGR, stamped onto cells as they are written, applied as background-color
erase fill, carried through scrollback and reflow, and exposed through the
public inspection surface and the neutral fixture schema.

Decisive constraints:

- Colors stay semantic -- default / indexed(0-255) / rgb -- the engine never
  resolves a palette; the renderer owns palette policy
  (`plan-terminal-engine/09-renderer.md`).
- Underline is a style enum (none / single / double / curly), per explicit
  scoping decision. Underline color (SGR 58/59) is consumed correctly but
  not stored.
- Public inspection: `TerminalCell` gains a style value (scrollback rows get
  it for free), and `Terminal` exposes the current pen read-only. Text
  projections (`screenText`, `fullHistoryText`) and `TerminalGeometry`
  stay style-free -- geometry remains layout-only per its documented
  equality contract.
- Fix the absorber to emit the trailing empty parameter as 0. Consequence
  to pin: `\e[31;m` means red then reset; trailing-separator forms of
  strict-arity non-SGR sequences (e.g. `\e[2;J`) become no-ops under the
  existing arity guards, consistent with the engine's established
  strictness.

### SGR behavioral scope

Zero parameters or parameter 0: reset pen to default. Full table:

| Params | Effect |
|---|---|
| 1 / 2 / 3 / 7 / 8 / 9 | bold / dim / italic / reverse / hidden / strike on |
| 4 | underline single; sub-params 4:0 none, 4:1 single, 4:2 double, 4:3 curly; unknown 4:x = single |
| 21 | underline double |
| 22 | bold off AND dim off |
| 23 / 24 / 27 / 28 / 29 | italic / underline / reverse / hidden / strike off |
| 30-37 / 40-47 | fg/bg indexed 0-7 (no bold-highbright coupling) |
| 39 / 49 | fg/bg default |
| 90-97 / 100-107 | fg/bg indexed 8-15 |
| 38 / 48 | extended fg/bg color (rules below) |
| 58 / 59 | extended underline color: consumed exactly like 38 / a lone param, result discarded |
| 5, 25, 10-19, 73-75 | consumed, ignored (blink, fonts, super/subscript -- contract omissions) |
| anything else | consumed, ignored |

Colon grouping: a maximal colon-linked run is one group; interpreting a
group's leading parameter consumes the group, so an unknown parameter with
sub-parameters can never corrupt later parameters.

Extended color (38/48/58), both wire forms:

- Colon form (`38:5:n`, `38:2:r:g:b`, `38:2::r:g:b`): payload is the rest
  of the group; the 5-arity `2` form skips a colorspace id. Missing or
  short payload: consumed, no color change.
- Semicolon form (`38;5;n`, `38;2;r;g;b`): selector consumes the following
  one or three parameters; truncation at sequence end consumes what exists
  with no color change; an unknown selector consumes only itself, and
  subsequent parameters continue as fresh SGR params.
- Components narrow to UInt8 by truncation mod 256 (libvterm parity);
  absorber-saturated 65535 becomes 255.

SGR sequences with intermediate bytes remain dropped.

## Invariants

- I1 Default-pen bit-identity: any byte stream containing neither SGR nor
  a trailing-separator CSI form produces a `Terminal` bit-identical to
  slice 4 output (every cell-creation site defaults to the default style;
  equality includes pen and cell styles). Trailing-separator CSI forms are
  the one deliberate behavior change (see Decision) and are pinned by
  their own tests.
- I2 Print stamps the pen at write time; no retroactive restyling. A
  grapheme cluster's style is fixed by its first scalar: continuation,
  width upgrade, and width downgrade preserve the cluster's own style, and
  SGR interpretation touches neither pending wrap nor an open cluster.
- I3 Structural style coherence: a wide tail always carries its head's
  style; a spacer head carries the style of the wide cell it defers. Holds
  in viewport and scrollback, including reflow-synthesized tails and
  spacers (extend `expectValidGrid` to enforce it).
- I4 Background-color erase: EL/ED/ECH produce padding cells carrying the
  pen's fg and bg with attributes and underline cleared (libvterm
  `64screen_pen` "EL sets only colours" semantics); the row revealed by
  scroll-off is filled the same way; wide pairs intersected by an erase get
  the BCE style on both halves. Resize is not an erase: resize-synthesized
  filler is default-styled.
- I5 Style preservation: styled cells keep their styles through scroll-off
  into scrollback and through width/height reflow.
- I6 Recovery: unknown, truncated, or malformed SGR input is consumed
  without corrupting later parameters or any non-pen state; text
  projections and chunk-invariant replay are unaffected by styles.

## Proof obligations

Reuse the existing harness: `Terminal` public API, `expectValidGrid`
(`TerminalGridAssertions.swift`), bit-identical-equality idiom, the fixture
replay runner (`TerminalFixtureTests.swift`), and the xorshift fuzz
`Generator`. TDD per repo convention: failing test first.

- PO1 (I1) Existing suites pass unchanged except
  `CSIParserTests.uninterpretedDispatchIsNoOp`, which drops the `\e[31m`
  case; an explicit test pins that a stream free of SGR and
  trailing-separator CSI forms matches slice 4 state, and the changed
  trailing-separator dispatch is pinned separately.
- PO2 (table, extended color) Pen-level tests via the public current-style
  accessor: reset forms; independent set/clear of each attribute incl. 22;
  underline enum incl. 4:x and 21; 16-color and bright ranges; both
  extended-color wire forms at both colon arities; component truncation;
  58/59 consumed and discarded; empty parameters resetting where they
  appear (`\e[;31m`, `\e[31;;41m`, and the `\e[31;m` absorber pin).
- PO3 (I2) Stamp-at-print, cluster-continuation across pen changes,
  upgrade/downgrade style retention, pending-wrap survival across SGR.
- PO4 (I3) Style coherence swept by the extended `expectValidGrid` across
  print, erase, reflow, and fuzz suites.
- PO5 (I4) BCE tests: EL/ED/ECH color stamping with attrs cleared;
  wide-pair widening; scroll-in coloring on the LF, soft-wrap, and
  wide-wrap paths; default-pen erase bit-identity; resize filler default.
- PO6 (I5) Reflow/scrollback tests: styles survive width walks and height
  transfers; scrolled-off rows retain styles; the reflow-synthesized tail
  and spacer sites are pinned.
- PO7 (I6) Malformed-recovery tests (truncated/unknown forms followed by a
  live parameter); fuzz alphabet extended so SGR forms (reset, attributes,
  extended color) arise, swept with the style-aware grid validation.
- PO8 (fixtures) Two neutral fixtures adapted from `t/30state_pen.test`
  and `t/64screen_pen.test` replay under all chunking strategies with
  style expectations.

## Fixtures and manifest

Extend the fixture schema with optional style expectations (existing
fixtures decode unchanged): a current-pen assertion, per-cell style point
assertions, and an optional style on scrollback cells, expressed in a
semantic vocabulary covering default/indexed/rgb colors, the attribute
set, and underline styles.

Manifest gains the two upstream files with full case lists (the
`libvtermManifestCoverage` expected-case pin extends to match):

- `t/30state_pen.test`: Reset, Foreground, Background -- adapted (default
  colors asserted semantically, not libvterm's concrete palette rgb
  values); Bold, Underline, Italic, Reverse -- adopted; Blink, Font
  Selection, Super/Subscript -- out-of-scope (contract omissions,
  consumed-ignored); Bold+ANSI colour == highbright -- out-of-scope
  (renderer palette policy); DECSTR resets pen attributes -- out-of-scope
  (terminal resets deferred).
- `t/64screen_pen.test`: Plain, Bold, Italic, Underline, Reset,
  Foreground, Background, "EL sets only colours..." -- adapted (semantic
  colors; reduced dimensions; the EL case is the BCE pin); Font,
  Super/subscript, DECSCNM, Set default colours -- out-of-scope.

Record as deviations: DanTerm asserts semantic default/indexed colors where
libvterm asserts palette-resolved rgb; pinned libvterm lacks SGR 58/59 and
mishandles `38:2::r:g:b`, so DanTerm's correct consumption of both is a
deliberate deviation, not an adoption.

## Non-goals

- Blink, font selection, super/subscript state (consumed, ignored).
- Underline color storage (58/59 consumed, discarded).
- RIS / DECSTR terminal resets; DECSCNM; configurable default palette
  (SETDEFAULTCOL).
- Bold-highbright coupling and any palette resolution.
- Styles in `screenText` / `fullHistoryText` / `TerminalGeometry`.
- Alacritty recording adoption (no scaffolding exists yet).

## Accepted risks

- AR1 Slice 4 content rules stay style-blind: BCE-colored trailing padding
  is not "content", so it does not survive width reflow or height-shrink
  trimming, and text/conservation invariants ignore styles. Pinned by
  test; revisit via differential traces if real programs care.
- AR2 Overwriting half a styled wide pair leaves the vacated cell
  default-styled (structural clear, not BCE). Pinned by test.
- AR3 Parameter capacity (24) drops very long SGR chains wholesale at the
  absorber; a full fg+bg truecolor chain fits.

## Implementation discretion

- Style storage shape (bools vs OptionSet, file placement, public init
  surface), fixture file names, and fixture token encoding.
- Whether BCE routes through the existing erase funnel or a parallel path,
  provided I4 holds.

## Critical files

`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`,
`TerminalGeometry.swift` (or a new sibling for the style types),
`EscapeAbsorber.swift`, and the `TerminalCoreTests` target (suites,
grid-validation helper, fixture runner, `Fixtures/`).

## Verification

- `swift test --package-path lib/TerminalCore` after each green step;
  targeted `--filter` runs during development.
- Fixture replay exercises authored/bytewise/split chunking automatically.
- Roadmap: check the slice off in `plan-terminal-engine/14-roadmap.md` only
  after the gate passes.

## Commit progress

- [x] 1. Interpret semantic SGR pen state
- [x] 2. Stamp and preserve cell styles
- [x] 3. Apply background-color erase styles
- [x] 4. Adopt style fixtures and complete verification
