# Ghostty-compatible selection granularity

## Problem and desired outcome

DanTerm currently offers four pointer selection granularities: character
(1 click), word (2), cluster (3), line (4+). Word is a three-way character-class
split (whitespace / identifier / punctuation); cluster is a plain
whitespace-delimited run. Two consequences are wrong:

- Double-click, the gesture users actually reach for, returns a
  character-class word. Double-clicking `bar` in `/foo/bar.txt` selects `bar`.
- The whitespace-run granularity that would select a whole path is buried at
  three clicks, and it over-selects: on `(/foo/bar.txt)` it returns the parens
  too, because parentheses are not whitespace.

Desired outcome is Ghostty's **default boundary-set expansion and its
click-count model** -- not Ghostty's full double-click behavior. Ghostty has one
expansion rule (`.ghostty-src/src/terminal/Screen.zig#selectWord`) driven by a
set of boundary codepoints, defaulting to `` \t'"│`|:;,()[]{}<>$ ``
(`.ghostty-src/src/config/Config.zig#selection-word-chars`), and cycles its
click counter through three states
(`.ghostty-src/src/Surface.zig#mouseButtonCallback`). Under the boundary rule,
double-clicking `bar` in `(/foo/bar.txt)` selects `/foo/bar.txt`: `/` and `.`
are not boundaries, `(` and `)` are.

Explicitly not adopted: Ghostty's double-click tries link detection first and
only falls back to `selectWord`, so it can select a whole `https://example.com`
where the boundary rule stops at `:`. Semantic link selection is a non-goal
here.

## Decision

Replace the two expansion rules with one boundary-set rule and cycle clicks.

- **Two expansion granularities, cluster and line.** Cluster is defined by a
  fixed boundary set equal to Ghostty's default. Clicking a non-boundary cell
  expands to the maximal adjacent run of non-boundary cells; clicking a boundary
  cell expands to the maximal adjacent run of boundary cells, *regardless of
  which boundary characters those are*. No path, URL, or scheme recognition and
  no trailing-punctuation trimming: the boundary set is the whole rule.
- Character-class word selection is removed, not retained behind another click
  count. `wordRange` and its character-class predicate leave the public surface.
- Click behavior cycles with period three -- ordinary selection drag, cluster
  expansion, line expansion -- so the fourth click behaves as the first. This
  matches Ghostty, whose counter resets after three. Single click stays ordinary
  cell-to-cell selection dragging and is not an expansion granularity; cluster
  and line are the only two.
- Boundary membership is decided by the projected unit's **leading scalar**,
  matching Ghostty's primary-codepoint test, so combining marks on a base cell
  never change its side.

The boundary set is fixed in `TerminalCore`; no configuration knob.

**Selection extent changes wherever whitespace touches another boundary
character.** Today whitespace is its own class, so clicking the space in
`foo (bar)` selects just the space; under the boundary rule it selects the space
and the paren as one run. This is an intended behavior change, not a
compatibility break to be worked around.

## Invariants

- **I1** -- Double-click on a cell whose leading scalar is not in the boundary
  set selects the maximal adjacent run of such cells; double-click on a boundary
  cell selects the maximal adjacent run of boundary cells, without distinguishing
  between different boundary characters.
- **I2** -- Click behavior cycles with period three -- ordinary selection drag,
  cluster expansion, line expansion -- so click count N behaves as N+3.
- **I3** -- Expansion crosses a soft-wrap boundary and stops at a hard line
  ending, so it can span rows but never absorbs the next command's first token.
- **I4** -- Projection, nearest-unit fallback, out-of-range clamping, wide-cell
  atomicity, empty-line behavior, clicks past retained content, and whole-unit
  dragging behave as they do today. This governs the surrounding mechanics only;
  the ranges the expansion rule produces are governed by `I1`.
- **I5** -- Cluster and line are the only expansion granularities reachable from
  the pointer path; no click count yields character-class word expansion.

## Proof obligations

- **PO1** (I1) -- Double-click inside `(/foo/bar.txt)` selects `/foo/bar.txt`;
  double-click inside a bare identifier selects that identifier.
- **PO2** (I1) -- Each character of the boundary set terminates a non-boundary
  run, and characters adjacent to it (`/`, `.`, `-`, `_`, alphanumerics) do not.
- **PO3** (I1) -- Adjacent *heterogeneous* boundary characters form one run:
  clicking the comma in `a;,(b` selects `;,(` contiguously. Also covers a
  whitespace-plus-punctuation run, which is the case today's whitespace rule
  splits.
- **PO4** (I1) -- A boundary base character carrying combining marks is
  classified by its leading scalar, and a non-boundary base with combining marks
  likewise.
- **PO5** (I2) -- Click counts one through six behave as ordinary selection
  drag, cluster, line, ordinary selection drag, cluster, line.
- **PO6** (I3) -- Expansion spans a soft-wrapped logical line and stops at a
  hard line ending.
- **PO7** (I4) -- Existing selection-unit and interaction-policy coverage
  remains green under the remapped click counts, including wide cells,
  retained-content fallback, clamping, and dragging.
- **PO8** (I5) -- No pointer click count produces a character-class word range.

## Non-goals

- Configuring the boundary set. The set is fixed; reopen if users ask.
- Semantic selection -- URL, path, or scheme recognition and punctuation
  trimming -- including Ghostty's link-first double-click.
- Changing single-click selection dragging, drag extension mechanics, PTY mouse
  reporting, or copy/serialization behavior.

## Accepted risks

- **AR1** -- Users habituated to today's 3-click whitespace-run lose it as a
  distinct gesture, and clicking whitespace adjacent to punctuation now selects
  more than the whitespace. Accepted as the cost of one rule instead of two; no
  compensating gesture is added.

## Implementation discretion

- Whether the surviving expansion keeps the `clusterRange` name.
- Whether the boundary set is tested per-codepoint or by representative
  sampling, provided `PO2` is discharged.

## Relationship to the point-local projection research

[docs/research/21-selection-gesture-cost.md](../../docs/research/21-selection-gesture-cost.md)
prices this gesture path and may later make it point-local. That work is a
pure-performance change gated on measured cost and is independent of this one,
except that this plan removes one of the granularities it measures. Land this
first if both proceed: measuring a granularity that is about to be deleted
wastes the probe.
