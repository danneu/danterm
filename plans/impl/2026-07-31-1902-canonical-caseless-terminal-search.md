# Normalization- and case-insensitive terminal search

## Context

Terminal search compares raw `Unicode.Scalar` arrays with ASCII-only folding, so
text that is pixel-identical on screen can fail to match. With `"AbC ñ n\u{0303}"`
on the grid (precomposed U+00F1 at column 4, decomposed `n` + U+0303 at column 6):

| needle | today | wanted |
| --- | --- | --- |
| `aBc` | matches col 0-3 | unchanged |
| `ñ` | col 4 only | col 4 **and** col 6 |
| `n` + U+0303 | col 6 only | col 4 **and** col 6 |
| `Ñ` | no match | col 4 **and** col 6 |
| `n` | no match | still no match |

Two causes. First, `asciiFold` only maps A-Z, so non-ASCII case folding does not
exist. Second, `searchMatches(for:)` accumulates cell scalars until
`candidate.count == queryScalars.count` and requires that count to be exact, so a
1-scalar needle can never reach a 2-scalar decomposed cell no matter how folding
behaves. The structural fix is to compare *normalized, folded keys* per grapheme
instead of raw scalars per count.

The rationale for going fuzzier, not stricter: search is already deliberately
fuzzy for humans. A search that fails on visually identical text is worse than a
case-sensitive one, because the user cannot see why it failed.

`n` must keep failing against `ñ`: matching stays per-grapheme. A bare base letter
never matches an accented one.

## Contract

Search is insensitive to Unicode normalization form and to case, and matches
whole graphemes.

**I1 — canonical caseless grapheme key.** Every grapheme is reduced to its
Unicode 17.0.0 D145 canonical caseless key, `NFD(toCasefold(NFD(g)))`, with
`toCasefold` the **full** case folding (`CaseFolding.txt` statuses `C` + `F`).
The key computation is the standard D145 definition, not a bespoke variant. Two
texts match when their graphemes align one-to-one under I2 *and* every
corresponding pair has an equal key. Matching is therefore not whole-string
canonical caseless equivalence: D145 equivalence that crosses a grapheme
boundary (`ß` versus `ss`) does not produce a match.

**I2 — whole-grapheme alignment.** The needle is segmented into grapheme clusters
*before* folding, and each needle grapheme must match exactly one projection unit
(one cell). Folding is applied inside an already-fixed grapheme, so a one-to-many
fold never changes how many units are compared. This is what keeps `n` from
matching `ñ`, and it is also what makes the two-grapheme needle `ss` fail against
a single `ß` cell even though `ß` folds to `ss`.

**I3 — full repertoire.** The mapping data covers the entire Unicode 17.0.0
repertoire: canonical decomposition (recursive, so canonical singletons such as
U+212B ANGSTROM SIGN reduce with it), Hangul syllable decomposition, canonical
ordering by combining class, and full case folding. No Latin-only or
subset-of-scripts cutoff.

**I4 — import-free.** All mapping data is checked-in Swift generated from pinned
UCD files. `TerminalCore` acquires no imports; Foundation's
`precomposedStringWithCanonicalMapping` and `folding(options:)` stay unavailable.

**I5 — anchors and navigation unchanged.** A match still anchors
`start: units[i].start`, `end: units[i + count - 1].end`. Newest-first selection,
Next/Previous direction, wrap-at-both-ends, hard-boundary (`"\n"`) behavior,
damage recording, reveal, and `SearchMatchCache` semantics are untouched.

**I6 — bounded search cost.** A cold search over maximum-budget history must not
measurably regress latency or transient memory versus the current
implementation, for the common all-ASCII needle and content.

### Data scope

Measured against the pinned Unicode 17.0.0 files: 2081 canonical decompositions
(3127 pool scalars), 403 merged combining-class ranges, 1585 full case-fold
mappings (maximum expansion 3 scalars). `UnicodeData.txt` is already in the
generator's pinned `FILES` at the exact hash this data needs.

## Non-goals / Accepted risks

**AR1 — compatibility decomposition (NFKD) is excluded.** `①` does not match `1`;
fullwidth `Ａ` does not match `A`. NFKD discards formatting distinctions the
terminal renders as visibly different glyphs, so it fails the "looks the same on
screen" test that motivates this change.

**AR2 — locale-specific casing is excluded.** Turkish dotless `ı` / dotted `İ`
use default root-locale rules. Already a stated non-goal in
`plan-terminal-engine/06-inspection-recovery.md` ("locale-sensitive search").

**AR3 — the `ß`/`ss` and `ﬁ`/`fi` asymmetry is intentional.** A `ß` cell matches a
`ß` needle but not an `ss` needle, because I2 compares grapheme counts. This is a
consequence of whole-grapheme matching, not a gap in the folding data.

## Approach

### Canonical caseless key

The key is compared in **decomposed** form, so no composition (NFC) table is
needed at all: `ñ` and `n`+U+0303 both reduce to `[n, U+0303]`, and `Ñ` reduces to
the same after folding. That halves the table work versus normalizing to NFC.

Per D145, in order:

1. Recursively canonically decompose (table + Hangul algorithm).
2. Full-case-fold each resulting scalar (one-to-many permitted).
3. Decompose again — folding can yield a decomposable scalar, which is why D145
   specifies the second NFD rather than this being defensive coding. Worth a code
   comment citing D145.
4. Canonical-order: stable-sort each run of nonzero-combining-class scalars by
   class. Stability is required, not incidental: equal-class marks must keep
   input order or canonically equivalent inputs produce unequal keys.

### Match loop

Replace the count-accumulating loop in `searchMatches(for:)`:

- Segment the **needle** into grapheme clusters using the module's existing
  streaming breaker, `graphemeBreak(between:and:state:)` in
  `GraphemeBreak.swift`. Reusing the same breaker the grid uses to form clusters
  (`appendToOpenClusterIfJoined`) makes needle segmentation agree with cell
  segmentation by construction, rather than by a parallel implementation that can
  drift.
- Key each needle grapheme once per scan; key each `ProjectionUnit`'s `scalars`
  once per scan (not once per start index, as today's inner loop effectively
  does).
- Slide a window of `needle.count` units, comparing keys element-wise, and anchor
  matches per I5.

`asciiFoldedEqual` and `asciiFold` are deleted; they have no callers outside this
function pair.

## Files

- **`scripts/generate-terminal-unicode-tables.py`** — extend, following its
  existing pattern. Add `CaseFolding.txt`
  (sha256 `ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183`) and
  `NormalizationTest.txt`
  (sha256 `5019ffd530751a741900c849c0e010332f142a3612234639bd200b82138a87db`) to
  the pinned `FILES` dict; both hashes verified against the live 17.0.0 files.
  Emit the production mapping data and the conformance corpus.
- **`lib/TerminalCore/Sources/TerminalCore/`** — the generated mapping data plus
  the hand-written key algorithm. The covered/excluded list (I3, AR1, AR2) lives
  in a header comment next to the code that imposes the limit, so the boundary is
  a documented decision rather than a silent gap.
- **`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`** — rewrite
  `searchMatches(for:)`; delete `asciiFoldedEqual` and `asciiFold`.

## Implementation discretion

File boundaries between generated data and hand-written algorithm, accessor
naming, lookup representation (packed two-stage table vs sorted-array binary
search vs anything else), and whether an ASCII short-circuit exists at all are
representation choices. I6 constrains the outcome; nothing here constrains the
shape.

## Tests

TDD: write each test first, run it, confirm it fails for the expected reason (not
a compile error standing in for a behavior failure), then implement. Preambles use
the Intent / Why it exists / Scenario sections from `AGENTS.md`. All tests are
behavioral or conformance-level; none assert internal representation.

### Behavioral — `TerminalSearchTests.swift`

Rewrite `foldingAndUnicodeExactness`. Its `beginSearch("Ñ") == false` assertion
encodes the old behavior and inverts. Critically, assert `activeSearchMatchRange`
**columns**, not just the `Bool` — the current test passes under either old or new
behavior precisely because it only checks booleans, which is why this gap went
unnoticed. Against `"AbC ñ n\u{0303}"` (`ñ` at column 4, `n`+U+0303 at column 6):

- `aBc` -> columns 0-3, unchanged.
- `ñ`, `Ñ`, `N`+U+0303, `n`+U+0303 -> each reaches **both** columns. Navigation is
  newest-first (rightmost first) and wraps at both ends, so the first hit is
  column 6-7; `searchNext()` reaches column 4-5.
- `n` -> no match. This is the assertion that pins I2.
- `""` -> no search, `activeSearchMatchRange == nil`, unchanged.

Add a limits test feeding `"ß ﬁ ① Ａ"`: `ß` matches `ß` but `ss` does not (I2/AR3);
`ﬁ` matches `ﬁ` but `fi` does not (I2/AR3); `1` does not match `①` and `A` does not
match `Ａ` (AR1). This turns the documented limits into a behavioral contract
rather than a comment.

`wrapAndBoundaryMatching` and `navigationUsesLiveContent` already exercise the
`"\n"` hard-boundary unit and must pass unchanged, covering I5.

### Conformance — generated

Representative examples cannot prove I3: a missing decomposition, a bad recursive
expansion, unstable equal-class ordering, a Hangul edge, or an omitted fold could
leave an arbitrary script silently broken while every hand-picked case passes.
The repo already holds this bar for its other generated Unicode tables
(`GraphemeBreakCorpus.generated.swift` from the official `GraphemeBreakTest.txt`,
plus independently generated reference tables), so conformance coverage is the
established invariant here, not a new one.

- **Normalization**: generate a corpus from the pinned `NormalizationTest.txt`
  (20034 data lines), encoding the two NFD invariants the file's own header
  states — `NFD(c1) == NFD(c2) == NFD(c3) == c3` and `NFD(c4) == NFD(c5) == c5`.
  The `c4`/`c5` pair is the *compatibility* group and must be checked against
  `c5`, not `c3`: a conformant NFD implementation leaves e.g. U+00A0 unchanged
  (`c3 == U+00A0`) while that line's `c5` is U+0020, so folding all five columns
  onto `c3` would fail correct code. Between them the two invariants exercise
  recursive decomposition, canonical ordering stability, and the Hangul
  algorithm across the full repertoire.
- **Folding**: assert every one of the 1585 `C`+`F` mappings, generated from
  `CaseFolding.txt` rather than sampled, so no mapping can be dropped silently.

## Docs

**`plan-terminal-engine/05-unicode-grid-scrollback.md`**, proof obligations
(~line 73). Replace "Precomposed and decomposed Spanish examples render, select,
erase, and search correctly" — which never defines *correct* — with the rule from
I1-I3 and the AR1/AR2 exclusions.

**`plan-terminal-engine/06-inspection-recovery.md`** (~line 39) currently reads
"It is ASCII case-insensitive and otherwise Unicode-exact initially." That
sentence becomes false with this change and must be updated to the same rule. The
adjacent non-goal "Regex, whole-word, or locale-sensitive search" stays accurate
and now also documents AR2.

## Verification

1. `python3 scripts/generate-terminal-unicode-tables.py` — pinned sha256 checks
   hard-fail if any UCD file drifted. Confirm the pre-existing outputs are
   byte-identical, proving the generator change is additive.
2. `grep -rn "^import" lib/TerminalCore/Sources/TerminalCore/` — must print
   nothing (I4).
3. `swift test --package-path lib/TerminalCore` — behavioral suites plus the
   normalization and folding conformance corpora (I1-I3, I5).
4. **I6 measurement**: cold search (empty `SearchMatchCache`) for an ASCII needle
   over history filled to the maximum scrollback budget, comparing latency and
   allocation behavior against the current implementation. Follow
   `agent-docs/terminal-performance.md` for method and artifact handling. Run
   this before locking in the key representation, since it is the input that
   decides whether a short-circuit is needed.
5. `just test` — the gate, including
   `core-purity-lint.sh --forbid-imports lib/TerminalCore/Sources/TerminalCore`.
6. `just build-run`, then search a pane containing `ñ` typed both ways (e.g.
   `printf 'ni\\xc3\\xb1o n\\xcc\\x83i\\xc3\\xb1o\\n'`) and confirm `Ñ` highlights
   both, and `n` highlights neither.

## Commit progress

- [x] 1. feat(terminal): add canonical caseless grapheme keys
- [ ] 2. feat(terminal): search by canonical caseless grapheme

## Implementation notes

- Production mapping tables are fixed-width hexadecimal strings decoded once
  by import-free Swift, and the official conformance files remain text test
  resources. Large generated Swift initializer arrays drove `swift-frontend`
  into multi-gigabyte constraint solving; this representation keeps generated
  data checked in without making compilation memory scale pathologically.
