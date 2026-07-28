# Cell representation

Research started: 2026-07-28. **Status: scoped, Phase 1 evidenced. No change
proposed yet.**

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
- [ ] RESEARCH: measure how much of a real session's cells are actually styled,
  and how many distinct styles exist. H1's entire argument is that the answer is
  "few", and DanTerm has never checked it. This is the cheapest possible test of
  the file's leading hypothesis.
- [ ] RESEARCH: count per-row array allocations in a scrollback-heavy run, to
  size the contiguous-buffer idea.

### Phase 2 -- direction gate

- [ ] **Gate: confirm the ordering above before implementing.** In particular
  decide whether H1 alone is worth shipping if H3 is never done -- it is, on
  memory and scrollback depth, but the CPU argument in H5 needs H3.

### Phase 3 -- implement and verify, one change at a time

- [ ] H1: style dedup behind a 16-bit ID.
- [ ] H2: narrow `hyperlinkId` and `contentIdentity`.
- [ ] H4: row skip flags.
- [ ] H3: pack the remaining cell into a POD word.
- [ ] Re-measure `10`'s erase-path node after H3 and settle H5 either way.

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
