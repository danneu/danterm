# Cell representation

Research started: 2026-07-28. **Status: H5's erase leg settled and shipped (F5,
F6), worth -7.05% on `terminal-feed`. Its move/copy leg was implemented as a POD
cell, measured, and then reverted: the feed win held at -8.83% but
`scrollback-stream` decided slower at +6.74% (F8). Cell triviality is therefore
demonstrated-and-rejected, not open -- reopening it needs a materially different
cost model, not another attempt. The memory question -- H1, H2, H4, and what
remains of H3 -- is evidenced but unproposed.**

## Purpose

This file owns the question of **how much a single terminal cell and row costs
DanTerm** -- in bytes of memory, in bytes moved per grid operation, and in
reference-counting traffic -- and which of libghostty's representation techniques
transfer to a Swift value-type engine.

It sits upstream of the two adjacent files rather than beside them:

| Question | Owned by |
| --- | --- |
| `Terminal.feed` CPU cost | doc 10 (**closed**) |
| Plan and draw allocation hotspots | doc 9 |
| Does the draw path fit the frame budget | doc 11 |
| **What a cell costs, and what it should cost** | **this file** |

The reason this is not a memory-usage footnote: DanTerm's cell is a 72-byte
non-POD value containing a reference-counted payload. That single fact is
plausibly the common cause behind several results doc 10 recorded without
explaining, including the one large node it closed **unattributed**. Memory is
the visible symptom; grid-shift and erase CPU is the expensive one.

**Evidence boundary.** The trigger for this file is a social-media post by
libghostty's author about his own project. That is a claim, not evidence. Every
libghostty number quoted here is verified against the local checkout in
`.ghostty-src/` (which [AGENTS.md](../../AGENTS.md) designates as the reference
for exactly this), with file and line cited. Nothing in this file may rest on the
post alone.

## Investigation rules

- **Verify every external claim against `.ghostty-src/` or
  `references/alacritty/` before using it.** Cite the file and line. The post
  below is a trigger and a source of *techniques*, never of numbers.
- **Report layout as `MemoryLayout` size *and* stride, and say which one
  matters.** Array storage costs stride, not size; DanTerm's cell differs by 7
  bytes between them.
- **A representation change is a CPU claim as much as a memory claim.** Any
  proposal here must state what it does to `moveAndFillCells`, `eraseCells`, and
  copy-on-write traffic, and must be verified on `terminal-feed` /
  `scrollback-stream` per `10/F9`'s rule about workloads that can see the change.
- **Import libghostty's techniques as evidence, not as a design to copy.** The
  goal is the representation that minimizes memory *and* improves performance
  *while staying simple* in a Swift value-type engine -- not the closest
  achievable imitation of a Zig arena design. Where DanTerm can find a smarter or
  simpler answer than the one `.ghostty-src/` uses, take DanTerm's. F4 is the
  first example: it shows the CPU win comes from cell *triviality* alone, which
  DanTerm can have without any of the packing, offsets, or page allocation that
  libghostty pairs it with.
- **Scrollback depth is a user-visible feature, and it is denominated in cells.**
  A change to cell size changes how much history a fixed budget buys. Say so
  explicitly in any proposal.

## Trigger and current evidence

### The post

From the author of Ghostty, comparing libghostty's terminal state against
Alacritty's `alacritty_terminal` crate, both embedded in the same Rust binary so
that binary overhead is not measured differently:

> libghostty vs. Alacritty (alacritty_terminal crate) memory usage. This tests
> pure terminal state with various payloads: empty screen, full screen, 10K row
> scrollback with plain text, unicode, heavy styling, and mixed. This is the most
> accurate read to what an embedder sees.
>
> So, when you see meme posts about Ghostty (or any of its embedders) memory
> usage, that is the fault of the application. Ghostty GUI itself certainly has
> some memory bloat! But its the GUI apps causing this, not libghostty.
>
> Note that Ghostty's results include our active scrollback compression, which
> Alacritty doesn't support. This is fair because it is on by default and happens
> automatically (while we still have higher IO throughput than Alacritty). It is
> the proper like-for-like comparison because it's what you'd experience.
>
> I included uncompressed numbers too though even though you'd have to actively
> try to get these, just to show even uncompressed is significantly better.
>
> Also, these were all run within the same Rust-written binary that embeds both,
> so it also avoids measuring the binary overhead differently since they run from
> an identical binary.
>
> I'm working on also measuring libvte and writing a longer form blog post to
> share the whole testing setup. I needed something to link to whenever I see the
> memes.
>
> libghostty is small, nimble, and excellent software.
>
> If you're interested in "how" or "why": the major culprit is that each row in
> Alacritty has 32 bytes of metadata and each cell is 24 bytes. In Ghostty, every
> row and cell is represented by exactly 8 byte each. How do we do this?
>
> The first major culprit is styles. Alacritty stores the full cell style
> alongside each cell (foreground, background, underline, etc.). Ghostty stores a
> 16-bit style ID and de-dupes all styles into a look-aside custom
> reference-counted hash table.
>
> MOST cells are unstyled, and when there are styles MOST styles are shared, and
> when styles are shared MOST are repeated in a run (multiple cells with the same
> style in a row). Put this all together, and the tradeoff on compute to access it
> doesn't even end up being slower.
>
> Next, codepoints. Alacritty stores multi-codepoint graphemes (like, Emoji) by
> having an 8-byte nullable pointer to a `Vec<char>`. This hurts doubly: (1) its
> almost always null (because multi-codepoint is rare) yet you pay an 8 byte cost
> on every cell and (2) every multi-codepoint grapheme triggers a heap allocation
> to make that Vec.
>
> Ghostty stores single codepoints inline, but multiple codepoints in a look-aside
> table. The memory for this table uses a custom bitmap-tracked chunk-allocator
> (since grapheme frequency follows a measurable curve we calculated by scanning
> various online texts). The presence of graphemes is marked by a 2-bit content
> tag in our packed 64-bit cell. To keep the key small in the hash table, its
> limited to a 16-bit unsigned int that is an offset from a base pointer.
>
> Okay, the astute systems programmer will quickly notice there are a lot of
> 16-bit integers and ask: so this is all limited to a max of ~65K values?
>
> Nay. We maintain our grid using a linked list of contiguous ~400KB memory chunks
> (which themselves are in a memory pool using a custom allocator to speed up
> alloc/free). Each memory chunk is limited to 2^16. If/when we reach a limit, we
> move to the next page. In practice, this really doesn't happen except under
> pathological cases... the important point is we handle it.
>
> Lots, lots, lots more details, but thats a 10,000 foot view.
>
> These things alone account for ~95% of the difference of our uncompressed vs.
> Alacritty's uncompressed memory usage. (Theres also a reason why Alacritty's
> data structures aren't trivially compressable but thats a whole other topic)

**How to read it here.** The Alacritty comparison and the memory results are not
our concern and are not reproduced as evidence. What is useful is the list of
*techniques*, each of which is verifiable in `.ghostty-src/` and each of which
DanTerm can be measured against. That verification is F2; DanTerm's own numbers
are F1. The claim "every row and cell is exactly 8 bytes" is the one assertion
that matters for us, and it checks out.

### Summary of what F1 and F2 found

| | DanTerm | libghostty |
| --- | ---: | ---: |
| Cell, array stride | **72 bytes** | **8 bytes** |
| Row header | 16 bytes **+ a separate heap array per row** | 8 bytes, cells reached by 32-bit offset in the same page |
| Style storage | full 19-byte `TerminalStyle` **inline in every cell** | 16-bit `style_id` into a refcounted look-aside table |
| Cell triviality | non-POD; contains refcounted `TerminalScalars.Storage` | POD `packed struct(u64)` |

DanTerm's cell is **9x** libghostty's, and on the axis the post singles out --
storing the full style per cell -- DanTerm carries more inline than Alacritty
does.

## Current hypotheses

Ordered by (bytes removed) x (portability to Swift), cheapest and most portable
first. Every one of them is also a CPU hypothesis; see H5.

### H1 -- the style should be a 16-bit ID into a deduplicated table

`TerminalStyle` is 19 bytes and is stored inline in every `GridCell` (F1). It is
the single largest field. libghostty stores a 16-bit `style_id` and de-dupes into
a refcounted set (`page.zig:138`, `style.zig:20`); `style_id == 0` is the default
style and needs no lookup at all.

The post's argument for why the indirection does not cost time -- most cells are
unstyled, most styles are shared, and shared styles repeat in runs -- applies to
DanTerm unchanged, and DanTerm already has the run structure to exploit it.

Removes ~19 of 65 bytes. **Most portable of all the ideas**: a Swift dictionary
plus a refcount is an ordinary data structure, with no unsafe memory work.

Confirmed if cell stride falls and `terminal-feed` / `scrollback-stream` do not
regress.

### H2 -- the two `Int?` side-table keys should not be 8-byte optionals

`GridCell` carries `hyperlinkId: Int?` and `contentIdentity: Int?` (F1). Both are
already *keys into side tables* rather than payloads, so the only question is
their width. `Int?` in Swift is 8 bytes plus a discriminator; two of them are
roughly a quarter of the cell.

libghostty spends **one bit**: the cell has `hyperlink: bool` and the id lives in
a page-level map (`page.zig:1994`, `hyperlink_set` at `page.zig:145`).

`contentIdentity` is DanTerm-specific -- it gives a printed run a stable identity
so link activation can verify the run still exists -- and nothing about it
requires 64 bits.

Removes up to ~18 of 65 bytes. Portable; needs a decision on ID width and
overflow behavior.

**Revised by F3.** The two halves are not alike. `hyperlinkId` is nil in 100% of
census cells and should follow libghostty exactly: one bit, data in a page map.
`contentIdentity` is a monotonic per-printed-cell counter with 132K distinct
values in one workload, so "nothing about it requires 64 bits" is too casual --
16 bits overflows, and narrowing needs a wrap or reuse policy. Decide them
separately.

### H3 -- the remaining cell should be a packed POD word

After H1 and H2, what is left is `kind` (a 5-case enum), the inline scalar, and
flags. libghostty packs the equivalent into `packed struct(u64)`
(`page.zig:1962`): a 2-bit content tag, a 21-bit codepoint, the style id, a 2-bit
`wide`, and per-cell booleans. DanTerm's `TerminalCellKind` (`padding`, `narrow`,
`wideHead`, `wideTail`, `spacerHead`) is 3 bits of information.

`07c0cd3` already moved scalars inline rather than one array per cell, which is
DanTerm's version of the post's grapheme argument -- so the direction is
established and the remaining question is multi-scalar clusters, which need the
same look-aside treatment libghostty gives them.

Confirmed if the cell becomes trivially copyable. **That triviality, not the byte
count, is the point** -- see H5.

### H4 -- rows should carry skip flags

libghostty's `Row` is also `packed struct(u64)` (`page.zig:1866`) and spends bits
on `styled`, `grapheme`, `hyperlink`, and `wrap`, so whole rows can be skipped
without touching cells. DanTerm's `GridRow` has `isSoftWrapped` and
`semanticPrompt` but no content-class hints.

Cheap, independent of H1-H3, and directly useful to the draw path doc 11 is
sizing.

### H5 -- cell triviality, not cell size, is where the CPU is

This is the hypothesis that makes the file worth opening, and it is the one doc
10 was circling without naming.

- `moveAndFillCells` is **~29% of the incremental harness root** (`10/F7`) -- the
  largest node on that shape. It shifts 72-byte non-POD cells one at a time
  through a closure, retaining and releasing `TerminalScalars.Storage` per cell.
  With a POD cell it is a single `memmove`.
- `outlined init with copy of Terminal.GridCell` was the **one node that rose**
  in `10/F7` (to 1.22x). It was recorded honestly as the expected trade. It only
  exists because copying a cell is non-trivial.
- **`eraseLine` / `eraseCells` / `clearCellAndPair` is 11-19% of root on *both*
  workload shapes** -- the only large shape-independent node in doc 10, and the
  one it closed as `RESEARCH`, **unattributed to any mechanism**. Blanking a cell
  today writes ~65 bytes and releases a refcounted payload. Against a packed POD
  cell it is a word store, and a whole run of them is a `memset`-shaped loop.
  **H5 proposes that this is the missing mechanism.**

Confirmed if making the cell trivially copyable collapses those three node
families together. This is a single prediction covering three separate
measurements, which makes it unusually falsifiable.

**Sharpened by F3.** The mechanism is *non-POD copy overhead*, not refcount
traffic: the workload behind `10/F7` has zero `.spill` cells, so nothing is being
retained or released there at all. The prediction survives -- it just now rests
entirely on H3, since H1 and H2 both leave `TerminalScalars` in the cell and the
cell non-trivial.

**Split by F4.** Measured directly: making the cell POD is worth **-21.5%** on
`incremental-screen-updates` and **-9.7%** on `scrollback-stream`, and it deletes
the outlined-copy family outright. But only two of the three predicted node
families collapsed. The erase family did not, so **H5 should now be read as two
claims**: the move/copy leg is confirmed and owned by triviality; the erase leg
is still unattributed, exactly as doc 10 left it, and needs its own
investigation. Note also that triviality does **not** require the 8-byte packing
of H3 -- only getting `.spill` out of the cell.

## Candidate direction, pending evidence

**Provisional. Incremental, in this order, because each step is independently
shippable and independently measurable.**

1. **H1, style dedup.** Biggest single field, most portable technique, no unsafe
   code. Do it first and alone.
2. **H2, narrow the two side-table keys.** Independent of H1.
3. **H4, row skip flags.** Independent of both; helps doc 11's path.
4. **H3, pack the remainder.** Only after 1 and 2, because they determine what is
   left to pack.

Explicitly **not** proposed: libghostty's linked list of ~400KB chunks with a
bitmap chunk-allocator and 16-bit base-relative offsets. That design depends on
Zig's manual memory control and is not a natural fit for a Swift value-type
engine with COW arrays. The *portable* neighbour of it -- one contiguous cell
buffer for the whole grid instead of a heap array per row, removing a per-row
allocation -- is worth considering on its own merits and is recorded as a task,
not a hypothesis, because nothing has measured the per-row allocation yet.

## Task ledger

### Phase 1 -- establish the layout facts

- [x] Measure DanTerm's cell, row, style, and scalar layout. Result: F1.
- [x] Verify libghostty's cell and row layout against `.ghostty-src/` rather than
  against the post. Result: F2.
- [x] RESEARCH: measure how much of a real session's cells are actually styled,
  and how many distinct styles exist. H1's entire argument is that the answer is
  "few", and DanTerm has never checked it. This is the cheapest possible test of
  the file's leading hypothesis. Result: F3.
- [ ] RESEARCH: count per-row array allocations in a scrollback-heavy run, to
  size the contiguous-buffer idea.

### Phase 2 -- direction gate

- [x] **Gate: confirm the ordering above before implementing.** Answered by F3
  and F4 rather than by deliberation: H1 is a memory and scrollback-depth change
  with no CPU payoff, and the CPU lives entirely in cell triviality -- which is
  separable from H3's packing and was taken first. The ordering in "Candidate
  direction" still stands for the memory half. For the CPU half the answer has
  since been overtaken by F8: triviality was taken first, measured across all
  five workloads, and reverted, so there is no CPU half left to order.

### Phase 3 -- implement and verify, one change at a time

- [ ] ~~Cell triviality: multi-scalar clusters moved into row-owned storage,
  making `GridCell` POD without packing it.~~ **Attempted and reverted.** Not one
  of H1-H4 as originally written -- it is the separable half of H3 that F4
  identified. Results: F7 (the `quick` win) and F8 (the `confirm` regression and
  the revert). Do not retry as specified; F8 records what would have to change
  first.
- [ ] H1: style dedup behind a 16-bit ID.
- [ ] H2: narrow `hyperlinkId`, and decide `contentIdentity` separately (F3).
- [ ] H4: row skip flags.
- [ ] H3: pack the remaining cell into a word, now that it is already POD.
- [x] Settle H5. Erase leg closed by F5/F6 (not representation at all). Move/copy
  leg settled the other way: F4 confirmed the cost is real, F7 confirmed removing
  it speeds up feed, and F8 showed that paying for the removal costs more on
  `scrollback-stream` than it buys. H5's move/copy remedy is closed as rejected,
  which is a stronger outcome than leaving it open.

## Findings log

### F1 -- a DanTerm cell costs 72 bytes of array storage and is not trivially copyable

- Status: recorded. Structural measurement.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: `9655657`, tracked tree clean.
- Method: a temporary `MemoryLayout` probe test. `GridCell`, `GridRow`, and
  `SemanticPromptRow` are `private` inside `Terminal`, so their visibility was
  briefly widened to measure them and reverted immediately; the tracked tree is
  unchanged.
- Measurements:

  | Type | size | stride |
  | --- | ---: | ---: |
  | `Terminal.GridCell` | 65 | **72** |
  | `Terminal.GridRow` | 10 | 16 |
  | `TerminalCell` (public projection) | 72 | -- |
  | `TerminalStyle` | 19 | -- |
  | `TerminalScalars` | 9 | -- |
  | `TerminalColor` | 4 | -- |
  | `Terminal` | 940 | -- |

- `GridCell`'s fields: `kind: TerminalCellKind` (5 cases), `scalars:
  TerminalScalars`, `style: TerminalStyle` **stored inline**, `hyperlinkId: Int?`,
  `contentIdentity: Int?`.
- `GridRow`'s fields: `cells: [GridCell]` -- an 8-byte reference to a **separate
  heap allocation per row** -- plus `isSoftWrapped` and `semanticPrompt`.
- Observation 1: array storage costs **stride**, so a row of 179 cells occupies
  179 x 72 = 12,888 bytes plus the array's own allocation. A full 179x66 screen is
  roughly **850 KB** of cell storage in 66 separate allocations.
- Observation 2: the cell is **not POD**. `TerminalScalars` carries a
  reference-counted `Storage` for multi-scalar clusters, which is why
  `outlined init with copy of Terminal.GridCell`, `outlined consume of
  TerminalScalars.Storage`, and refcount traffic all appear under
  `moveAndFillCells` in `10/F6` and `10/F7`.
- Observation 3, which is a separate issue worth its own decision: the scrollback
  budget's cost model does not match reality. `scrollbackByteCost`
  (`Terminal.swift:2763`) charges `16 + cells * (32 + 8 * scalars)`, i.e. **40
  bytes for an ordinary single-scalar cell against a true stride of 72**. At the
  production budget of 10,485,760 bytes (`Terminal.swift:444`) and 179 columns,
  the model admits roughly **1,460 rows**, whose actual cell storage is about
  **18.8 MB** -- close to 1.9x the budget's nominal figure, before per-row
  allocation overhead. The budget is an estimate rather than an accounting of real
  bytes; that is defensible as a design choice but it is currently undocumented
  and the divergence grows with any change to cell layout.
- Inference: supports H1 (style is the largest field), H2 (the two optionals are
  a quarter of the cell), and H5 (triviality, not size, is the CPU story).
- Competing interpretations: none for the measurement. The *consequences* depend
  on how often cells are copied and moved, which doc 10 already measured as
  frequently.
- Uncertainty: none on the numbers; the scrollback arithmetic assumes 179 columns
  and single-scalar cells and is illustrative rather than exact.
- Next action: the two Phase 1 RESEARCH items.

### F2 -- libghostty's 8-byte cell and row claims verify against the local checkout

- Status: recorded. Source verification of an external claim.
- Date and investigator: 2026-07-28, Claude (agent).
- Source: `.ghostty-src/`, the pinned libghostty reference checkout.
- Verified:
  - `page.zig:1962` -- `pub const Cell = packed struct(u64)`. **8 bytes, exactly
    as claimed.** Its fields are a 2-bit `content_tag`, a packed union holding
    either a 21-bit `codepoint` or a background colour, a `style_id`, a 2-bit
    `wide`, and single-bit `protected` / `hyperlink` flags, a 2-bit
    `semantic_content`, and 16 bits of padding.
  - `page.zig:1866` -- `pub const Row = packed struct(u64)`. **8 bytes.** Its
    `cells` field is an `Offset(Cell)`, not a pointer, and it carries `wrap`,
    `wrap_continuation`, `grapheme`, `styled`, `hyperlink`, and `semantic_prompt`
    bits.
  - `style.zig:20` -- `Style` holds three colours plus a `packed struct(u16)` of
    flags, and lives in a `StyleSet` (`page.zig:138`) rather than in the cell.
  - `page.zig:128,135` -- `grapheme_alloc: GraphemeAlloc` and `grapheme_map:
    GraphemeMap`, the look-aside grapheme storage the post describes.
  - `page.zig:145` -- `hyperlink_set`, confirming the cell spends a bit and the
    page holds the data.
- Observation: the two structural claims that matter for DanTerm -- 8-byte cell,
  8-byte row, style behind an ID, graphemes and hyperlinks in look-aside tables --
  are all directly readable in the source. The post's Alacritty figures were not
  checked and are not used here.
- Inference: the techniques are real and specific enough to evaluate one at a
  time, which is what the hypotheses do.
- Uncertainty: none on what the source says. What does **not** transfer is the
  memory management underneath it -- `Offset`, the page chunking, and the
  bitmap allocator all assume manual memory control.
- Next action: none; this finding exists to keep the file's claims sourced.

### F3 -- the corpus is unstyled, spill-free where it matters, and `contentIdentity` is near-unique per printed cell

- Status: recorded. Structural census of resident grid state.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: `e58a19b`, tracked tree clean.
- Method: a temporary census test, same disposable shape as F1. `GridCell`,
  `GridRow`, `SemanticPromptRow`, `ScrollbackBuffer`, `Terminal.rows`,
  `Terminal.scrollbackRows`, and `TerminalScalars.storage` were briefly widened
  from `private` to internal so a `@testable` test could walk them; all edits and
  the test file were reverted immediately and the tracked tree is unchanged. Each
  of the four `benchmarks/fixtures/terminal-app.json` workloads was framed with
  the same length-prefixing `terminal-feed-profile.py` uses and fed to a fresh
  `Terminal(columns: 179, rows: 66)`. The census then walked every cell of
  `scrollbackRows + rows`. Styles were counted through a `Hashable` key encoding
  all ten `TerminalStyle` fields, since `TerminalStyle` is `Equatable` only.
- Measurements (resident state after the full workload):

  | Workload | rows | cells | styled cells | distinct styles | `.spill` | rows w/ `.spill` | hyperlink cells | `contentIdentity` cells / distinct |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | `scrollback-stream` | 1,783 | 319,157 | **0** | 1 | **0** | 0 | 0 | 80,219 / **80,219** |
  | `styled-screen-redraw` | 66 | 11,814 | **88** (0.74%) | **9** | 0 | 0 | 0 | 1,197 / 1,197 |
  | `unicode-wrapping` | 1,709 | 305,911 | 0 | 1 | **1,876** (0.61%) | **1,005** (58.8%) | 0 | 137,919 / **132,258** |
  | `incremental-screen-updates` | 66 | 11,814 | 0 | 1 | 0 | 0 | 0 | 289 / 289 |

- Scalar case split: cells are overwhelmingly `.empty` -- 74.9% on
  `scrollback-stream`, **97.6%** on `incremental-screen-updates`, 56.8% on
  `unicode-wrapping`. Every remaining cell is `.single` except the 1,876
  `unicode-wrapping` spills.
- Inference 1, H1's premise holds but its payoff is memory only. At most **9
  distinct styles** exist in any workload, so a dedup table stays trivially
  small and the look-aside indirection is safe. But the 19 bytes come out of
  every cell whether or not it is styled, so the memory win never depended on
  this census; what the census establishes is that the table will not grow
  pathologically.
- Inference 2, and the one that changes the plan: **H5's mechanism is not
  reference counting.** `incremental-screen-updates` -- the workload behind the
  incremental harness whose `moveAndFillCells` node is ~29% of root in `10/F7` --
  contains **zero** `.spill` cells, as does `scrollback-stream`. With no spill
  there is no `TerminalScalars.Storage` to retain or release, so the
  `outlined init with copy` / `outlined consume` cost measured there is the
  per-cell **call and switch overhead of a non-POD enum**, paid on every cell
  regardless of case. This corrects F1's observation 2, which attributed it to
  refcount traffic. It also settles the Phase 2 gate question: H1 removes bytes
  but **cannot** remove those nodes, because it leaves `TerminalScalars` in the
  cell and the cell non-trivial. Only H3 can.
- Inference 3, H2 splits into two unequal halves. `hyperlinkId` is nil in
  **100%** of cells across all four workloads -- 8 bytes plus discriminator per
  cell for a feature the corpus never exercises, and the strongest candidate in
  the file for libghostty's one-bit-plus-page-map treatment. `contentIdentity` is
  the opposite of what H2 assumed: it is a monotonic counter
  (`Terminal.swift:436,4610`) issued per printed cell, so distinct values track
  printed-cell count almost exactly (80,219 of 80,219; 132,258 of 137,919).
  Narrowing it to 16 bits is **not** a free width change -- 132K distinct values
  in a single workload overflow it by 2x -- and requires an explicit wrap or
  reuse policy. H2's two halves should be decided separately.
- Inference 4, H4's row flags are strong for style and weak for graphemes. A
  `styled` row bit would let the draw path skip essentially every row on three of
  four workloads. A `grapheme` row bit is much blunter: on `unicode-wrapping`
  **58.8% of rows contain at least one spill cell** despite spills being 0.61% of
  cells, so the flag skips only ~41% of rows on exactly the content it targets.
- Competing interpretations: the corpus may simply be less styled than real
  sessions. That weakens inference 1 (which is why it is stated as "the table
  stays small", not "styling is rare in practice") but does **not** weaken
  inference 2, which turns on spill being absent from two specific workloads
  whose profiles doc 10 already took.
- Uncertainty: this is a census of **resident state**, not of write traffic.
  `styled-screen-redraw` writes far more styled cells than the 88 that survive to
  the end, and per-cell style *writes* are what a dedup table's refcount churn
  would cost. Sizing that needs write-path instrumentation, not a grid walk.
- Next action: take the H1-alone question to the Phase 2 gate with inference 2 in
  hand, and measure style-write traffic before committing to a refcounted table.

### F4 -- a POD cell is 21.5% faster on the incremental workload, but the erase leg of H5 does not collapse

- Status: recorded. Deliberately-incorrect spike, reverted. Diagnostic, not a
  paired verdict.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: `e58a19b`, tracked tree clean before and after.
- Method: `TerminalScalars`' three-case enum was temporarily replaced with a POD
  struct (`first: Unicode.Scalar`, `count: UInt8`) that truncates multi-scalar
  clusters to their first scalar, making `GridCell` trivially copyable --
  `TerminalScalars` is its **only** non-POD member (`TerminalCellKind` is
  payload-free, `TerminalStyle` is colors/bools/enums, `Int?` is trivial). The
  build is wrong for grapheme clusters by construction and is exactly correct for
  `incremental-screen-updates` and `scrollback-stream`, which F3 measured at zero
  `.spill` cells. Both arms were built release from the same tree and machine
  session; timing ran interleaved (baseline, candidate, candidate, baseline) x 3
  per corpus.
- Profile, `just benchmark-feed-sample incremental-screen-updates 20`
  (`.build/terminal-feed-profiles/2026-07-28-120745` baseline,
  `2026-07-28-120910` candidate):

  | Node | baseline (16,574 samples) | candidate (15,954 samples) |
  | --- | ---: | ---: |
  | `Terminal.feed` subtree | 47.1% | **37.6%** |
  | `moveAndFillCells` subtree | 14.4% | **8.1%** |
  | `eraseLine` subtree | 13.9% | **15.9%** |
  | `outlined init with copy of GridCell` (own) | 913 | **absent** |
  | `outlined consume of TerminalScalars.Storage` (own) | 584 | **absent** |
  | `outlined destroy of GridCell` (own) | 566 | **absent** |
  | `outlined copy of TerminalScalars.Storage` (own) | 294 | **absent** |
  | `_platform_memmove` (own) | 617 | 725 |

  The four outlined-copy symbols do not merely shrink; they occur **zero** times
  anywhere in the candidate profile, and `memmove` rises. That is the predicted
  substitution, observed directly.
- Timing, median of 6 interleaved executions per arm:

  | Corpus | baseline | POD spike | change |
  | --- | ---: | ---: | ---: |
  | `incremental-screen-updates` | 1,111.3 ms | 872.7 ms | **-21.5%** |
  | `scrollback-stream` (4 per batch) | 235.5 ms | 212.7 ms | **-9.7%** |

  Spread within each arm was under 1% on both corpora, and no candidate sample
  overlapped any baseline sample.
- Inference 1: **H5's central claim is confirmed, and it is large.** Cell
  triviality alone -- no style dedup, no narrowed keys, no bit-packing -- removes
  the entire outlined-copy family and a fifth of feed time on the workload where
  `10/F7` found `moveAndFillCells` dominant. The mechanism is what F3 predicted:
  non-POD copy overhead, not refcounting.
- Inference 2, and it revises H5: **the erase leg does not collapse.** `eraseLine`
  holds 15.9% of root after the spike, and `clearCellAndPair`'s own time *rises*
  (1,385 -> 1,658 samples), as does `clearPreviousSpacer` (455 -> 642). H5
  predicted three node families would collapse together; two did. Doc 10 closed
  the erase node unattributed, and this spike **fails to attribute it to
  triviality** -- the remaining cost looks like per-cell control flow (spacer
  repair, pair clearing), not per-cell copying. That is now a separate open
  question, and it is the more interesting one because it is shape-independent.
- Inference 3, on direction: the win requires only that the cell be **POD**, not
  that it be **8 bytes**. A 72-byte trivially-copyable cell captures all of the
  measured 21.5%. That decouples the CPU work (get `.spill` out of the cell) from
  the memory work (H1, H2, H3's packing) entirely, and it means DanTerm does not
  need libghostty's offsets, page chunking, or bitmap allocator to collect the
  performance half of this file's thesis.
- Competing interpretations: the spike also removes the array allocation that a
  real cluster payload costs -- but neither measured corpus contains one, so on
  these two corpora that difference cannot be doing any work. The
  `scrollback-stream` gain being half the incremental gain is consistent with the
  mechanism: it shifts fewer cells per byte fed.
- Uncertainty: this is a headless microbenchmark and per
  [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md)
  it is diagnostic, not a directional verdict. A real implementation must be
  decided with `just benchmark-quick baseline=<rev> workload=terminal-feed`, and
  that number will be **smaller** than 21.5%, because the combined `terminal-feed`
  stream includes `unicode-wrapping`, where a correct cluster side-table costs
  something the spike simply skipped. The spike measures the ceiling.
- Next action: settle the erase question separately (inference 2), and design the
  cluster side-table's lifetime -- per-row storage dies with row eviction but is
  only meaningful against its own row, so every path that builds a cell under a
  different row owner has to carry the content across; per-terminal storage
  avoids that but needs reclamation on overwrite. Corrected after drafting: those
  paths are not reflow alone, and one of them (`resizedRectangle`) rebuilds rows
  without moving any cell between row *indices* at all. Enumerating them is the
  wrong instrument; the design constraint is the row-owner rule. Carried into
  `plans/wip/despill-cell-clusters.md`.

### F5 -- the erase cost is per-cell call and nested-COW overhead, and it is not shape-independent at the feed boundary

- Status: recorded. Diagnostic profiling, no code changed.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: `e58a19b`, tracked tree clean.
- Method: three `just benchmark-feed-sample` profiles -- two on
  `incremental-screen-updates` (`2026-07-28-120745`, `2026-07-28-121505`) for the
  stability rule in
  [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md),
  one on `scrollback-stream` (`2026-07-28-121623`). Attribution of
  `swift_isUniquelyReferenced_nonNull_native` to its nearest enclosing frame was
  computed from the call graph.
- Measurements on `incremental-screen-updates` (own time, two profiles):

  | Node | profile 1 (16,574) | profile 2 (16,720) |
  | --- | ---: | ---: |
  | `eraseLine` subtree | 13.9% | 14.8% |
  | `clearCellAndPair` (own) | 1,385 (8.4%) | 1,480 (8.9%) |
  | `clearPreviousSpacer` (own) | 455 (2.7%) | 434 (2.6%) |
  | `isUniquelyReferenced` attributed to `clearCellAndPair` | -- | 567 (3.4%) |

- Mechanism 1, **nested COW checks per cell.** `clearCellAndPair` writes
  `rows[row].cells[column] = GridCell(style:)` (`Terminal.swift:5066`), which
  goes through two nested array modify accessors, so every single cell write
  re-checks uniqueness of the outer `[GridRow]` buffer *and* the inner
  `[GridCell]` buffer. 3.4% of root is spent there. Line attribution inside the
  function concentrates on 5066 (the assignment), 5055 (the kind switch), and
  5070 (the spacer call).
- Mechanism 2, **a loop-invariant call made per cell.** `eraseCells` calls
  `clearCellAndPair` per column (`Terminal.swift:2863`), and each of those calls
  `clearPreviousSpacer`, which can only do work when `column <= 1`
  (`Terminal.swift:5083`). Erasing a full 179-column line therefore makes 177
  calls that guard out immediately, each passing a 19-byte `TerminalStyle` by
  value. That is 2.6-2.7% of root spent almost entirely on no-ops.
- Mechanism 3, **it is per-cell function-call shape, not payload work.** Neither
  mechanism touches the cell's contents, which is why F4's POD spike did not move
  it and why doc 10 could not attribute it to a data-layout cause.
- Correction to a doc-10 reading: **the erase family is not shape-independent at
  this boundary.** On `scrollback-stream`, `clearCellAndPair` is only 3.1% of
  root (509 own samples) and is reached from `printNarrow` -- the per-print
  clear -- not from `eraseLine` at all. It is the same function on both shapes
  with a different caller and a much smaller share. `10`'s 11-19% figure spans
  both callers; this file should not treat "erase" as one node.
- Incidental finding, recorded because it is large and adjacent:
  `specialized static Terminal.scrollbackByteCost(of:)` is **8.6% of root** on
  `scrollback-stream` (1,411 own samples: 883 via `enforceScrollbackBudget`, 398
  via `appendToScrollback`). F1 observation 3 already flagged this cost model as
  a ~1.9x underestimate of real bytes; it is also expensive to evaluate. That is
  a separate question from cell representation and should not be absorbed into
  one of this file's hypotheses.
- Uncertainty: sample shares are attribution, not timing, so the sizes above rank
  the work but cannot license a directional claim. Any fix must be decided with
  `just benchmark-quick`.
- Next action: brainstormed candidates are hoisting the row binding out of the
  per-cell loop, hoisting `clearPreviousSpacer` out of it, and filling the
  expanded interior as a run rather than cell by cell. None implemented; awaiting
  direction.

### F6 -- removing the per-cell erase overhead is worth -6.36% on `terminal-feed`

- Status: recorded. Paired comparison at `quick` thresholds. Implemented.
- Date and investigator: 2026-07-28, Claude (agent).
- Baseline revision: `e58a19b`, compared against the working tree.
- Change: `eraseCells` (`Terminal.swift:2847`) no longer calls
  `clearCellAndPair` per column. The wide-pair expansion already pulls every
  intersected pair wholly inside the range, so no cell in the range has a partner
  outside it -- which lets the interior be filled in one
  `withUnsafeMutableBufferPointer` pass instead of paying two nested-array COW
  uniqueness checks per cell (F5 mechanism 1), and lets `clearPreviousSpacer` run
  once for the range instead of once per erased cell (F5 mechanism 2). `lower` is
  now clamped to 0 after expansion; the old code could compute `-1` and relied on
  `clearCellAndPair`'s bounds guard to swallow it.
- Verdict: `just benchmark-quick baseline=e58a19b workload=terminal-feed` ->
  `faster (-6.36% symmetric median of 2 pairs)`, then
  `just benchmark-confirm baseline=e58a19b` at the tighter thresholds ->
  **`terminal-feed: faster (-7.05% symmetric median of 2 pairs)`**. The rest of
  the ladder: `scrollback-stream` equivalent (+0.40%), `incremental-mixed`
  equivalent (+0.62%, 5 flagged outlier pairs retained), `content-churn`
  inconclusive (-1.11%), `style-churn` inconclusive (+0.78%). An earlier
  invocation was invalid (`not-on-ac-power`) and is disregarded.
- Supporting per-corpus microbenchmark (diagnostic only, 6 interleaved executions
  per arm): `incremental-screen-updates` 1,107.6 ms -> 1,020.7 ms (**-7.8%**);
  `scrollback-stream` 235.0 ms -> 233.7 ms (-0.6%). The split is what F5
  predicts: `scrollback-stream`'s erase traffic arrives through `printNarrow`,
  which this change does not touch.
- Tests: existing coverage already pinned wide-pair expansion and the column-0
  spacer repair. Two characterization tests were added for the branches the
  refactor could silently narrow -- an erase starting at column 1, and an erase of
  the top viewport row repairing a spacer head that has scrolled into scrollback
  (the only branch of the repair that leaves the viewport). Both passed before and
  after. Core suite and `just test` green.
- Uncertainty: the two draw workloads returned `inconclusive`, which is the
  absence of an answer rather than a clean bill. This change does not touch the
  draw path, so that is expected, but it does mean the ladder licenses "faster on
  the feed boundary" and nothing about drawing.
- Inference: F5's two mechanisms were the erase cost, and neither was about cell
  representation. **The erase leg of H5 is now closed and answered outside this
  file's hypotheses** -- it was per-cell call and COW-check shape, not payload
  layout. What remains of H5 is the move/copy leg, which F4 already confirmed
  belongs to cell triviality.

### F7 -- the POD cell is worth -9.43% on `terminal-feed` at `quick`

> **Superseded in part by F8.** The measurement below stands and reproduced. Its
> inferences do not: the change was reverted in `94a1528` after `confirm`
> decided `scrollback-stream` slower. Read this finding as "what one workload
> said", and F8 as what the workload set said.

- Status: recorded, and its conclusions withdrawn by F8. Paired comparison at
  `quick` thresholds. Implemented in `31c2f8e`, reverted in `94a1528`.
- Date and investigator: 2026-07-28, Dan (implementation), Claude (this record).
- Baseline revision: `2a39e5b`, compared against the working tree that became
  `31c2f8e`. The run's `run.json` confirms the baseline resolved to the
  pre-change commit rather than to the change's own tree.
- Change: multi-scalar grapheme clusters moved out of the cell into scalar
  storage owned by the row, per
  `plans/impl/2026-07-28-1321-despill-cell-clusters.md`. `GridCell` is now
  trivially copyable. The cell also dropped `Equatable` in favour of a
  content-based row `==`.
- Verdict: **`terminal-feed: faster (-9.43% symmetric median)`**.
- Against F4's ceiling: F4 measured **-21.5%**, and the gap has two independent
  causes, both expected. F4's spike skipped cluster storage entirely rather than
  implementing it, and F4 measured `incremental-screen-updates` alone while this
  verdict is the combined four-corpus stream, which includes `scrollback-stream`
  (F4: -9.7%) and `unicode-wrapping` (where clusters are real work). The ceiling
  behaved as a ceiling. **F8 corrects this**: `scrollback-stream` was not a
  smaller win inside the blend, it was a decided regression, so the shortfall was
  never a matter of approaching a ceiling from below.
- Verification beyond the gate, from the implementation: each of the three
  cross-row-owner paths was mutated to copy the bare cell reference and confirmed
  to fail its test -- reflow and alternate-screen resize trap on the stale range,
  and the last-column wrap gives a scalar-exact mismatch. Disabling compaction
  took the I4 row from 64 stored scalars to 2,500, so PO4 is load-bearing rather
  than decorative.
- Inference, **withdrawn by F8**: this was read as settling H5's move/copy leg and
  as confirming F4's inference 3 in production code. The second half survives --
  the feed win did come from triviality alone, with no packing, offsets, or page
  allocator. The first half does not: settling a hypothesis requires the whole
  workload set, and this finding had one workload.
- Uncertainty, which turned out to be the whole story: `quick`, not `confirm`, so
  the direction was licensed at `quick`'s threshold and nothing tighter. Memory
  was not measured; the cell may have grown slightly (plan AR1), and no claim was
  made about scrollback depth. F8 ran `confirm` and the missing workloads is
  exactly where the change died.

### F8 -- `confirm` decides `scrollback-stream` slower, and the POD cell is reverted

- Status: recorded and acted on. Paired comparison at `confirm` thresholds.
- Date and investigator: 2026-07-28, Dan (decision), Claude (runs and this
  record).
- Baseline revision: `2a39e5b`, candidate `31c2f8e` -- the same two trees F7
  compared, so F7 and F8 differ only in which workloads were measured.
- Verdict, all five workloads:

  | Workload | Symmetric median | Decision |
  | --- | --- | --- |
  | `terminal-feed` | -8.83% (2 pairs) | faster |
  | `scrollback-stream` | +6.74% (4 pairs) | **slower** |
  | `content-churn` | +1.43% (4 pairs) | inconclusive |
  | `style-churn` | +0.96% (4 pairs) | inconclusive |
  | `incremental-mixed` | +1.09% (6 pairs) | inconclusive |

- The feed win reproduced: -8.83% here against F7's -9.43%, two independent runs
  of the same pair of trees.
- **`scrollback-stream` came back with the opposite sign to F4's prediction.** F4
  projected -9.7% there. The measured result is +6.74%, decided, with zero
  flagged outlier pairs. This is the finding that matters, because it falsifies
  the specific prediction the change was built on rather than merely failing to
  reach it.
- Why the spike and the implementation disagree: F4's spike deliberately
  truncated clusters, so it deleted cluster storage rather than relocating it. It
  measured the cell becoming trivial while paying none of the cost of putting the
  scalars somewhere. Any real implementation pays that cost somewhere, and row
  ownership put it on `GridRow`, which grew from 16 bytes with one refcounted
  field to 32 bytes with two. `scrollback-stream` moves rows constantly --
  scrolling, scrollback append, budget eviction.
- Attribution, diagnostic only: `just benchmark-sample scrollback-stream
  seconds=15` puts `moveAndFillRows` second among app frames (1,320 samples),
  behind only `damageActionSnapshot.getter` plus its `initializeWithCopy`
  (~2,060 combined), which is pre-existing and untouched by this change. `memcpy`
  at 944 and `swift_retain`/`swift_release` at ~1,050 sit behind it. Consistent
  with row-copy cost; not proof, since no baseline profile was taken.
- Incidental: `outlined consume of TerminalScalars.Storage` is still in the
  profile at 85 samples. F4 expected the outlined-copy symbols to disappear
  entirely. They do not, because the render plan still carries the public
  `TerminalScalars` -- which the change's own I5 required be left alone. Part of
  F4's projected win was never reachable by any change that keeps the public type.
- Decision: **reverted in `94a1528`**, not tuned. `GridRow` could have been shrunk
  to a 24-byte floor by dropping a stored `Int`, but its best case still buys an
  ambiguous aggregate -- one workload faster, three leaning mildly slower -- at
  the price of a permanent invariant: a cell's scalars resolve only against its
  owning row, so every future path that relocates a cell must re-intern or
  silently corrupt clusters. The ownership story is intrinsic to a POD cell, not
  to this design of one; the plan's RI1 and RI3 rejected the alternatives for the
  same reclamation reason.
- Inference: **a POD cell is demonstrated-and-rejected, not open.** Retrying it as
  specified would reproduce F8. What would have to change first is the cost model,
  not the implementation: either row-move traffic stops being hot on
  `scrollback-stream` -- note that the workload's true top frame is damage
  bookkeeping, which is unrelated and unoptimized -- or cluster scalars find an
  owner that does not enlarge the row.
- Methodological inference, the generalizable one: **a spike that removes a case
  measures an upper bound on removing the case, not on implementing it.** F4's
  -21.5% and -9.7% were read as a ceiling to approach. One of them was not a
  ceiling in the same direction at all. A spike that elides work should carry an
  explicit note of which costs it did not pay.
- Open follow-up, now moot in the code but retained as a design note: a fully
  erased row kept its cluster storage until the next intern compacted it. Bounded
  by the compaction threshold, so I4 held, but a range covering the whole row
  could have released it outright.

## Open questions and caveats

- **The post is a trigger, not evidence, and its subject is not our subject.** It
  compares libghostty against Alacritty on memory. DanTerm is neither, and this
  file's interest is CPU at least as much as memory. Do not import its
  conclusions; import its techniques and re-derive.
- **Nothing here is yet known to be worth doing.** H1's premise -- that most cells
  are unstyled and most styles are shared -- is stated by the post about
  *terminal content in general* and has never been measured on DanTerm. That
  measurement is the first Phase 1 item precisely because it could refute the
  leading hypothesis cheaply.
- **Swift is not Zig, and the gap is largest exactly where the post is most
  impressive.** `packed struct(u64)` with bit-level field control, 16-bit
  base-relative offsets, and a bitmap chunk allocator have no ergonomic Swift
  equivalent for a value-type engine using COW arrays. H1, H2, and H4 transfer
  cleanly; H3 transfers partially; the page allocator does not transfer and is
  not proposed.
- **A cell-size change is a scrollback-depth change.** The budget is denominated
  in an estimate of bytes (F1, observation 3), so shrinking the cell either buys
  proportionally more history at the same budget or should be accompanied by a
  deliberate decision not to. Either way it is a product decision, not only an
  engineering one.
- **This file must not restart doc 10.** Doc 10 is closed. Where a hypothesis here
  predicts a change to one of its measurements -- H5 predicts three -- the check is
  a fresh measurement against `10/F8`'s after-columns, not a reopening.
