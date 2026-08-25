# Own the text-vs-color font decision

## Context

The same pane renders differently on macOS and iOS. Claude Code prints U+23FA
(`⏺`) at the head of every tool line; on the Mac it draws as a flat monochrome
circle, on the phone as a clipped color emoji.

Neither app chose that. The monospace face has no glyph for U+23FA on either
platform, so the cell drops to the `CTLine` fallback in
`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`
and CoreText substitutes a face by its own rules. Resolving U+23FA through
`CTLine` on the shipped monospace face:

| | resolved face |
|---|---|
| macOS 26 | STIXTwoMath-Regular (text) |
| iOS 26.2 | AppleColorEmoji (color) |

Both faces are installed on both platforms. What differs is the decision, and
DanTerm makes no part of it. That leaves the renderer's output a function of
something DanTerm does not control, cannot test, and Apple may change in any OS
update.

This plan owns a cross-platform presentation requirement of its own, stated at
the scope it delivers (I1): for a bare emoji variation base whose Unicode
default presentation is text, DanTerm states text presentation on every
platform, and the cell draws as text wherever the host has text coverage for
that scalar. Within that scope, the phone and the Mac showing different
presentations for the same cell is a correctness failure, not a cosmetic
difference. (The replica machinery in
`ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalSurfaceView.swift` is
about stream state, and promises nothing about platform font rendering.)

U+23FA is the first cell anyone noticed. The class this plan fixes is narrower
than the class of divergence: bare default-text emoji variation bases that the
base face cannot map and the sprite families do not claim. A default-text scalar
outside that Unicode set stays delegated to the host and can still diverge.

### DanTerm already models presentation, but only when it is stated

`TerminalUnicodeProperties`
(`lib/TerminalCore/Sources/TerminalCore/UnicodeProperties.generated.swift`, pinned
at Unicode 17.0.0 and generated from `emoji-data.txt` and
`emoji-variation-sequences.txt`) marks U+23FA an emoji variation base, and
`desiredClusterWidth` in `Terminal.swift` reads that flag to give U+23FA+U+FE0F
a wide cell and U+23FA+U+FE0E a narrow one.

That flag is consulted only when a selector follows. A bare scalar's width comes
from `properties.cellWidth`, which the generator derives from East_Asian_Width
W/F plus Regional_Indicator and nothing else. U+23FA is East Asian Neutral, so
it gets a narrow cell -- sized for a text glyph, but not because DanTerm reached
a conclusion about presentation.

The clipping follows from that gap: a 15.0pt color glyph is drawn into a 6.8pt
cell and clipped to the cell box. DanTerm has the vocabulary to say which
presentation it wants -- it already honours U+FE0E and U+FE0F when the stream
supplies them -- and simply never says it for a bare scalar. The fix is to say
it.

## Decision

**The fallback path states the presentation Unicode already defines.**

When the `CTLine` fallback draws a cell whose scalars are a single emoji
variation base with default *text* presentation, it appends U+FE0E -- the text
presentation selector -- to the string it hands CoreText. Nothing else changes.

Variation selectors are UTS #51 semantics, which is the one language both
platforms are specified to honour, rather than a private ranking DanTerm hopes
stays stable. Measured: bare U+23FA resolves to `AppleColorEmoji` on iOS 26.2
and to `STIXTwoMath-Regular` with U+FE0E appended, matching the Mac.

The rule is gated, not blanket:

- **Single scalar only.** A multi-scalar cell -- a ZWJ sequence, a keycap, a
  skin-tone pair -- is left alone. Appending a selector after a sequence would
  be changing a cluster the terminal already assembled.
- **Already carries a selector: left alone.** A cell ending in U+FE0F asked for
  emoji explicitly and got a wide cell for it.
- **Default-emoji scalars: left alone.** A scalar Unicode presents as emoji by
  default is drawn as one. These are exactly the scalars the grid gave a wide
  cell (I4), so leaving them alone is also what keeps a color glyph out of a
  cell too narrow for it.

Stating text presentation is a preference, not a restriction: U+FE0E asks for a
text glyph, and a scalar no text face covers falls through to a color face
rather than to nothing. PO5 checks that on a scalar the gate actually
transforms.

### The gate needs one new property bit

`isEmojiVariationBase` alone is not the gate. That flag says the scalar has both
forms defined, which is true for default-emoji bases as well as default-text
ones, so it would demote scalars the grid deliberately made wide.

The property that separates them is `Emoji_Presentation`, which
`scripts/generate-terminal-unicode-tables.py` already downloads in
`emoji-data.txt` but does not emit. It gains a bit beside the two emoji flags it
already writes.

Cell width is *not* an acceptable stand-in for that bit. Every default-emoji
scalar is wide, so the implication runs one way only: wide cells also hold
default-text bases such as U+3030, which a width-gated rule would refuse to fix.
Width is a different Unicode property that happens to agree in one direction,
and resting the gate on that agreement is the coupling this change exists to
remove. I4 states the direction that does hold, and PO3 checks it.

### Where it lives

The classifier is a pure function of one scalar, so it belongs in `TerminalCore`
beside the table it reads, exposed for the render module to call. The renderer's
change is confined to the fallback in `drawTextCell`; the sprite families and
the direct glyph batch never see it.

No render-plan type gains state and the render plan's shape does not change:
`RenderTextCell` already carries the exact scalar sequence, which is everything
the classifier needs. (`TerminalUnicodeProperties` does gain the new generated
bit; that is the table, not the render plan.)

## Invariants

- **I1.** For a fallback cell holding a single bare emoji variation base whose
  Unicode default presentation is text, DanTerm states text presentation to
  CoreText on every platform, and the cell draws a glyph that takes the
  requested foreground color and stays inside its cell box, whenever any face
  available to the host has a text glyph for that scalar. Presentation stops being a function of which host picked which face
  first; it is a function of the Unicode table DanTerm pins.
- **I2.** Every other fallback cell is handed to CoreText exactly as it is
  today: multi-scalar clusters, cells carrying an explicit variation selector,
  and single scalars whose Unicode default presentation is emoji.
- **I3.** Coverage is never reduced. A scalar that only a color face can draw
  still draws, because U+FE0E expresses a preference CoreText may fall through
  rather than a restriction on the faces it may use.
- **I4.** The rule never demotes a scalar the grid sized as an emoji. Every
  `Emoji_Presentation=Yes` scalar is East Asian Wide or Fullwidth, or a regional
  indicator the generator also makes wide, so the wide cells allocated on emoji
  grounds belong exactly to the scalars the gate excludes. The converse does not
  hold and is not needed: a default-text base may be wide (U+3030, U+303D,
  U+3297, U+3299, U+1F202 and U+1F237 are), and drawing a text glyph in the wide
  cell it was given is correct.

## Proof obligations

- **PO1 (I1).** The classifier answers text for U+23FA, for a default-text base
  that is East Asian Wide (any of the six named in I4, so the wide-and-text case
  is pinned rather than assumed away), and emoji for a
  default-emoji base -- read from the generated table rather than a literal
  list. Pure and executable on macOS, which is the whole point of moving the
  decision into the table: the old plan's equivalent obligation could only be
  discharged on iOS.
- **PO2 (I2).** The classifier declines every excluded shape -- a multi-scalar
  cluster, a cell already ending in U+FE0F, a cell already ending in U+FE0E, and
  a scalar that is not a variation base at all. This is the obligation that
  keeps a blanket rule from creeping back in.
- **PO3 (I4).** Exhaustive, not sampled: every scalar the generated table marks
  `Emoji_Presentation=Yes` has a wide cell width. Stated one way only -- a
  default-text base may be either width, so the converse must not be asserted.
  Width and presentation come from independent Unicode properties, so this is
  what turns I4 from an assumption about the data into a checked fact, and what
  fails loudly if a future pin breaks it.
- **PO4 (I1, end to end).** A rendered cell holding U+23FA has ink in it -- some
  pixel differs from the background -- and no inked pixel is chromatic. Both
  halves are needed: "no chromatic pixel" alone passes on an empty cell and on a
  missing-glyph box, so on its own it cannot tell a text glyph from no glyph.
  The terminal's baked defaults are both achromatic, so any pixel whose channels
  disagree is color-glyph ink. The chromatic half is vacuous on macOS today; it
  is written against the draw path so that it binds wherever the suite is
  executed, and it is the check the phone run reproduces by eye.
- **PO5 (I3).** Exhaustive, not sampled, and on each supported platform: for
  every scalar the gate transforms, the sequence with U+FE0E appended resolves
  to usable glyph output -- never the missing-glyph box. The probe must observe
  the resolved output, not the host's font inventory: a face that carries the
  scalar proves nothing about whether CoreText selects it for the appended
  sequence. Probing must use gated scalars, since an inapplicable selector
  CoreText may simply ignore says nothing about an applicable one. This is the
  obligation that turns I3 from a claim about what U+FE0E means into a checked
  fact, and it is where an AR4 counterexample would surface. Two halves, two
  routes: the macOS half is an executed test in the suite; the iOS half is the
  simulator probe run in Verification. Both read the gated set from the
  generated table rather than a literal list, so both stay exhaustive when the
  Unicode pin moves.
- **PO8 (I1, at the boundary).** An executed test observes the exact scalar
  sequence the executor submits to CoreText for a drawn cell, and shows that an
  included cell gains U+FE0E while an excluded cell is submitted unchanged.
  PO1-PO3 can all pass against a classifier the draw path never calls, and PO4
  is vacuous on macOS, so without this obligation the append could be deleted
  from `drawTextCell` and the whole automated suite would stay green. The shape
  of the seam is discretion; the requirement is that the submitted sequence is
  observable and asserted.
- **PO6 (existing behavior).** The existing render suite stays green, with
  attention to the packaged-symbols, metrics-equality, and direct-glyph-draw
  suites in `lib/TerminalCore/Tests/TerminalRenderExecutionTests/`. Nothing in
  this change touches font construction, so movement there is a stop-the-line
  signal.
- **PO7 (generated table).** The regenerated table carries the new bit with its
  source checksums updated, and `scripts/generated-unicode-tables-lint.py` stays
  green.

Assert on drawn output -- the glyph takes the requested foreground color and
fits its cell -- never on a face name or a face-wide trait. A name pins Apple's
font inventory back into the tests, which is the thing this plan removes; the
color-glyph trait describes a face rather than the cell, so it can reject a
color-capable face that draws the correct monochrome text glyph, and it
contradicts AR3, which accepts that hosts may pick different text faces.

## Non-goals

- Improving emoji rendering. Real emoji still resolve to the color face and are
  still clipped to their cell on both platforms. This change stops U+23FA being
  *drawn* as one; it does not change how emoji draw.
- Drawing the media-control symbols as sprites. It would fix these seven
  scalars with pixel-identical output and is a legitimate smaller change, but it
  leaves the delegation in place, so the next divergent symbol returns as a new
  bug.
- A font-collection presentation lookup in the style of Ghostty's
  (`references/ghostty/src/font/Collection.zig`), which resolves presentation by
  querying a second font-selection path per codepoint. What this plan takes from
  Ghostty is only its classification rule -- absent an explicit selector, use the
  Unicode default (`Collection.zig:867`) -- which DanTerm's width logic already
  implements. No second lookup path is added.

## Accepted risks

- **AR1.** DanTerm's pinned Unicode 17.0.0 tables now decide presentation for
  the fallback. If a future OS emoji font claims a scalar Unicode 17 calls
  default-text, DanTerm forces text anyway. That is the intended ownership --
  the alternative is the delegation this plan removes -- and the table is
  regenerated by an existing script when the pin moves. PO3 is what makes a pin
  that breaks I4's premise fail the suite rather than pass quietly.
- **AR2.** The iOS gate cross-compiles but never executes a test, so no test in
  this repo runs on iOS. Unlike the cascade approach, almost nothing here is
  iOS-only: the classifier, its gate, and the cross-table agreement are pure and
  run on macOS, and PO8 pins the submit side there. The iOS facts -- that
  CoreText honours the appended U+FE0E, and PO5's half of the gated-set sweep --
  are discharged by the Verification probe run on an iOS 26.2 simulator, which
  is a binary run by hand rather than a suite the gate executes. Closing the
  execution gap is separate work.
- **AR4.** If a gated scalar has no text-face coverage at all on some host,
  U+FE0E falls through and that cell draws from a color face, so I1's
  draws-as-text half does not hold there. Accepted rather than fenced: the
  alternative is refusing the only face that can draw the scalar, which breaks
  I3 outright, and the gated set is the pre-emoji symbol blocks that text faces
  broadly cover. PO5 is where a counterexample would surface.
- **AR3.** The relative order of the remaining faces still comes from the
  platform, so two hosts could in principle pick different *text* faces for the
  same scalar. Sampling across symbol, CJK, and box-drawing scalars found no
  such divergence, and the text-versus-color split is the one that produced a
  visible failure.

## Rejected ideas

- **RI1. Give every face a DanTerm-supplied cascade list, stably partitioned so
  color faces sit last.** This was the previous plan; it was implemented and
  measured before being withdrawn. Three measurements killed it. (a) The cascade
  is not a control surface: macOS resolves U+23FA to STIXTwoMath under every
  order tried, including a cascade list containing nothing but the color face,
  and reaches STIXTwoMath even though the list does not name it -- so the rule
  worked only on the platform that happens to honour order today, which is the
  delegation it claimed to remove. (b) It cannot be made cheap: cascade
  descriptors carry only a name, and reading the color-glyph trait forces
  CoreText to materialize each fallback font over synchronous XPC to `fontd`
  (7.9ms cold per 41-descriptor pass, ~205 blocking round-trips per font set).
  (c) That blocking XPC runs on the Swift Concurrency cooperative pool and
  starves it: `ios/DanTermMobileKit` hung indefinitely under parallel execution
  and passed in 14.2s with `--no-parallel`, against 9.6s unmodified.
- **RI3. Bundle a monochrome fallback font covering the gated scalar set and
  select it directly when the primary face lacks the glyph.** It would make I1
  absolute rather than conditional on CoreText honouring U+FE0E. Rejected: it
  buys that by taking on an owned font asset and pinning the fallback face for
  the whole gated set, against a failure that is so far hypothetical -- no
  scalar the gate transforms has been shown to lack text coverage on either
  platform. AR4 records the residual, and PO5 is where a real counterexample
  would appear; a named scalar with color-only coverage on a supported platform
  is grounds to re-open this.
- **RI2. Gate on cell width instead of adding an `Emoji_Presentation` bit.**
  Rejected in `The gate needs one new property bit`: it is a proxy for the
  property rather than the property.

## Verification

- The existing render suite and `just test` stay green. `just test` is
  mandatory here rather than a targeted run: the withdrawn approach passed every
  targeted suite and deadlocked only under the gate's parallel execution.
- A scalar-resolution probe built for both a macOS binary and an iOS simulator
  binary reports the same presentation for U+23FA -- a text glyph, not a color
  one -- rather than the same face; AR3 accepts that the two hosts may reach
  different text faces. The simulator half iterates the whole gated
  set, read from the generated table, and reports any missing-glyph result; that
  run is how PO5's iOS half is discharged.
- End to end on the phone: build and run the iOS app (`scripts/ios-app.sh`),
  attach to a pane running Claude Code, and confirm the tool-line marker draws
  as a monochrome circle inside its cell, matching the Mac.

All three passed. `just test` ran 107 steps green; the probe reported a text
glyph with no chromatic ink for U+23FA and 0 of 219 gated scalars losing their
glyph on both macOS 26.5 and iOS 26.2; and the app installed on a paired
iPhone 13 mini drew the tool-line marker as a monochrome circle, confirmed by
the user.

## Implementation discretion

- The classifier's name, and whether it returns an enum or a Bool.
- Whether the render module calls it per fallback cell or once per run.

## Commit progress
- [x] 1. feat(unicode): emit the Emoji_Presentation bit
- [x] 2. feat(core): decide a fallback cell's presentation from the table
- [x] 3. fix(renderer): state text presentation for default-text symbols

## Implementation notes

- **The PO8 seam is a task-local observer**
  (`lib/TerminalCore/Sources/TerminalRenderExecution/FallbackSubmission.swift`).
  The plan left the shape to discretion. Two alternatives were rejected: a
  module-scope box would be shared mutable state across the gate's parallel
  tests, and an observer parameter on `drawRenderFrame` would widen a public
  signature for every caller to serve one test. A task-local reaches
  `drawTextCell` through the free-function draw path with neither cost, and lets
  the proof drive the whole public path rather than the private helper -- so
  deleting the append *and* deleting the fallback's call to it are both red.
- **PO5's macOS half reuses the metrics' own base face** rather than naming a
  font, and reads the resolved glyph by string index. A variation selector can
  occupy a glyph slot of its own, so "does any glyph equal 0" would have
  reported a missing base glyph for every gated scalar.
- **Verification results.** The probe was built from a scratch package against
  `lib/TerminalCore` and run on both hosts. macOS 26.5.2: U+23FA draws a text
  glyph (206 ink px, 0 chromatic). iOS 26.2 simulator (iPhone 17 Pro): text
  glyph (181 ink px, 0 chromatic). Both report 219 gated scalars and 0 that lose
  their glyph with U+FE0E appended, which discharges PO5's iOS half. A control
  run with the append removed draws U+23FA on iOS as a color glyph (503 ink px,
  428 chromatic), so the fix is what changes the phone's result.

## Follow Up

- ~~Measure the fallback draw path with and without
  `FallbackSubmission.observer?(submitted)` and decide whether the observer call
  earns an `#if DEBUG` guard.~~ **Done; no guard.** Measured per fallback cell in
  a release build, medians over 5 blocks with ranges inside 0.5%: the observer
  read is 9.63 ns, the gate lookup
  (`terminalPresentationSelectorToAppend`) is 60.67 ns, and the
  `CTLineCreateWithAttributedString` + `CTLineDraw` they sit beside is 11,900 ns.
  The read is 0.081% of the work in its own cell.

  The whole-frame arms could not resolve that, and the control is what says so.
  On a 179x66 frame of U+23FA (11,814 fallback cells, far denser than any real
  screen) an ABBA schedule read 169.96/171.19 ms with the read and
  168.72/168.60 ms without -- a 1.13% gap. But the all-ASCII control frame, which
  the observer line cannot reach, moved 1.828 to 1.959 ms (+7.2%) between the two
  without-runs. The machine drifted six times more than the effect, so the 1.13%
  is drift. The read's own arithmetic predicts 0.114 ms of that frame's 169 ms.

  A guard would buy a saving no instrument here resolves, in exchange for a
  release draw path that differs from the tested one. Note also that the repo's
  benchmark ladder cannot measure this at all: every draw workload's frames are
  ASCII (`scripts/terminal-benchmark-producer.py:145`), so `drawTextCell` never
  runs and `benchmark-quick` would answer `equivalent` whatever the cost.
- Close the iOS execution gap AR2 records: an iOS-simulator test target running
  the render suite would retire both the hand-run probe and this commit's
  submission seam, because the phone's own pixels would then be the proof and
  PO4's chromatic half would stop being vacuous.
