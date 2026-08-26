# The unweighed windows-terminal corpus

Research started: 2026-08-25.
Continues: [26-external-corpus-expansion/README.md](../26-external-corpus-expansion/README.md) (`26/F8`, `26/F9`, `26/D2`).

- [findings.md](findings.md) -- the append-only evidence chain: the per-file
  census and the novelty verdicts.
- [decisions.md](decisions.md) -- the auditable decision log for what to adopt,
  adapt, and decline.

## Purpose

Doc 26 pinned windows-terminal as a corpus and mined exactly three of its test
files: `Base64Test.cpp`, `MouseInputTest.cpp`, and `OutputEngineTest.cpp`. It
chose those three because they mapped onto gaps it had already found, and its
own caveat says so: "F5's and F8's full-suite counts remain size signals, not
novelty signals. Phase 3 read and classified the six scoped files; F9's measured
result applies only to those files, not to every Ghostty or windows-terminal
test."

This doc owns the rest of that corpus. Sixteen files in the tree carry
`TEST_METHOD`s; three are adjudicated and one is empty, leaving twelve files and
128 cases that no decision has ever weighed.

It also asks the question doc 26 could not: **does the value of a mined corpus
hold up outside the files chosen for their expected yield?** Doc 26 measured two
novel cases from 4,315 lines and generalized that into a corpus-level rate. The
three files it read were selected precisely because they looked promising, so
that rate is an upper bound, not an average. The twelve unread files test it.

It does not reopen doc 26's settled boundaries: the neutrality rule, the
licensing rules, the Ghostty declination (`26/D2`), or the wraptest declination
(doc 2).

## Investigation rules

- Inherited from `26`: never port another engine's private structures, callback
  topology, or storage model. Translate scenarios and public outcomes only.
- Inherited from `26`: `references/xterm/ctlseqs.txt` is the adjudication
  instrument. An imported expectation is justified against the specification or
  against the DanTerm contract, never against "windows-terminal does this."
- A `superseded` disposition must name the specific native test
  (`File.swift:function`) that covers the case. "Probably covered" is not a
  disposition.
- An `out-of-scope` disposition must name the missing capability concretely --
  the sequence, the mode number, the feature -- verified against
  `lib/TerminalCore/Sources/TerminalCore/`, never against a schedule. This is
  the D4 rule from `26/D4`, and this doc inherits it.
- windows-terminal is a console host as much as a terminal. A case asserting
  Win32 console API behavior, `INPUT_RECORD` translation, ConPTY plumbing, or
  its own class API is `implementation-coupled`, which is a fifth disposition
  this corpus needs and the libvterm ledger does not.
- Under the repository TDD rule, a case that discovers a bug becomes the
  smallest failing native test first, verified failing for the expected reason,
  before any fix.

## Trigger and current evidence

The user asked whether more third-party tests should be adapted for DanTerm now
that the engine has changed substantially. The answer surfaced three gaps; two
were closed in the same session (the esctest2 gate went from 14 to 93 cases, and
the manifest ledger was re-adjudicated against the shipped charset support).
The third gap is this doc: corpora that were censused but never adjudicated.

The census of `TEST_METHOD` counts, taken at `f016f5b6`:

| File | Cases | Lines | Status |
| --- | --- | --- | --- |
| `parser/ut_parser/OutputEngineTest.cpp` | 64 | 3574 | adjudicated by `26/D2` |
| `adapter/ut_adapter/adapterTest.cpp` | 53 | 4034 | **unweighed** |
| `parser/ut_parser/InputEngineTest.cpp` | 25 | 1563 | **unweighed** |
| `types/ut_types/UtilsTests.cpp` | 10 | 620 | **unweighed** |
| `adapter/ut_adapter/inputTest.cpp` | 9 | 810 | **unweighed** |
| `parser/ut_parser/StateMachineTest.cpp` | 7 | 379 | **unweighed** |
| `buffer/out/ut_textbuffer/TextAttributeTests.cpp` | 7 | 327 | **unweighed** |
| `adapter/ut_adapter/MouseInputTest.cpp` | 5 | 621 | adjudicated by `26/D2` |
| `buffer/out/ut_textbuffer/TextColorTests.cpp` | 5 | 201 | **unweighed** |
| `adapter/ut_adapter/kittyKeyboardProtocol.cpp` | 4 | 302 | **unweighed** |
| `types/ut_types/CodepointWidthDetectorTests.cpp` | 4 | 1358 | **unweighed** |
| `types/ut_types/UuidTests.cpp` | 2 | 43 | **unweighed** |
| `parser/ut_parser/Base64Test.cpp` | 2 | 120 | adjudicated by `26/D2` |
| `buffer/out/ut_textbuffer/ReflowTests.cpp` | 1 | 726 | **unweighed** (data-driven) |
| `buffer/out/ut_textbuffer/UTextAdapterTests.cpp` | 1 | 64 | **unweighed** |

Totals: 199 cases across 16 files; 71 adjudicated, 128 unweighed.
`ReflowTests.cpp`'s single `TEST_METHOD` is a scenario table, so its case count
understates its content by a wide margin.

The corpus is pinned at `1cea42d433253d95c4487a3037db48197b5e72f4` and is MIT
licensed, so adoption is unblocked; the license notice pattern already exists at
`lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/LICENSE.windows-terminal.txt`.

## Current hypotheses

### H1 -- the unread files are richer than the read ones, because the engine moved

Doc 26's three files were chosen in July against a July engine. Since then the
engine landed 7-bit ISO 2022 charsets, DECSCA and selective erase, logical-line
scrollback with reflow, and input-encoding work. Four of the unweighed files sit
directly on that new surface: `InputEngineTest.cpp` and
`kittyKeyboardProtocol.cpp` on input encoding, `TextAttributeTests.cpp` and
`TextColorTests.cpp` on style resolution, `ReflowTests.cpp` on reflow.

If H1 holds, novelty per line read is higher here than doc 26's measured rate,
and the corpus-level generalization in `26/F9` is wrong in the optimistic
direction for DanTerm.

Rejected if the unweighed files yield at or below doc 26's rate.

### H2 -- most of the yield is `implementation-coupled`, not `out-of-scope`

windows-terminal's tests reach directly into `TextAttribute`, `TextColor`,
`StateMachine`, and `TextBuffer` C++ classes. The libvterm and Alacritty ledgers
never needed a disposition for that, because those corpora drive their engines
through a byte stream. If H2 holds, the honest census needs the fifth
disposition, and a large fraction of 128 resolves to it without any statement
about DanTerm's capabilities at all.

The sharp form of H2 is that `implementation-coupled` and `out-of-scope` are
routinely conflated in corpus work, and conflating them is a real cost: an
`out-of-scope` row is a standing claim about DanTerm that can go stale, while an
`implementation-coupled` row is a claim about the *upstream* test that never
can. Mislabeling the second as the first manufactures maintenance.

### H3 -- a class-level test can still encode a policy question worth adopting

`TextAttributeTests.cpp` and `TextColorTests.cpp` test C++ classes, so H2 says
they are coupled. But the *questions* they encode -- does bold brighten an
indexed color, does reverse video swap resolved or stored colors, what does a
default color resolve to under reverse video -- are real, spec-adjacent policy
questions DanTerm must also answer, and are reachable from a byte stream through
DanTerm's public cell-style projection.

If H3 holds, the disposition must be judged on the policy a case encodes, not on
the API it uses to encode it, and H2's coupled bucket shrinks.

## Task ledger

### Phase 1 -- census the twelve unweighed files

- [x] Inventory every `TEST_METHOD` in the tree and separate adjudicated from
  unweighed. Result in the table above.
- [x] Classify `adapterTest.cpp` (53 cases), split across two readers. Result in
  F1.
- [x] Classify `InputEngineTest.cpp` and `kittyKeyboardProtocol.cpp` (29 cases)
  against DanTerm's input encoding. Record any byte-level disagreement with the
  spec citation that adjudicates it. Result in F2, and the kitty keypad
  disagreement is adjudicated in DanTerm's favor there.
- [x] Classify `inputTest.cpp` and `StateMachineTest.cpp` (16 cases). Result in
  F3.
- [x] Classify `TextAttributeTests.cpp` and `TextColorTests.cpp` (12 cases) by
  the policy each encodes, per H3. Result in F5.
- [x] Classify `ReflowTests.cpp`'s scenario table, plus the three `ut_types` and
  ICU-adapter files. Result in F6.
- [x] Measure novel cases per line read and compare against `26/F9`'s rate.
  Decides H1, which is **rejected**. Result in F11 -- and the comparison itself
  is recorded as not honestly makeable, since `26/F9`'s baseline is biased.
- [x] Count the `implementation-coupled` share of the 128. Decides H2 and H3.
  Result in F11: 36%, the largest bucket.

### Phase 2 -- adjudicate and land

- [x] Decide adopt/adapt/decline per novel candidate. Destination: D1. Five
  adopted, 123 declined.
- [x] Mutation-test every adoption candidate before landing it. Eleven
  candidates reached the bar and six were falsified there (F7), three of them by
  replayed fixtures. F10 adds the probe-verify rule after two mutations turned
  out inert.
- [x] Land the selected cases and extend `windows-terminal-manifest.json` to a
  complete ledger of all fifteen case-bearing files, so the corpus stops being
  partially classified. 213 entries.
- [x] Reduce any discovered failure to the smallest failing native test first.
  No adopted case discovered a failure. Two defects were found by reading and
  are recorded in F4 and F9, unfixed and outside this doc's scope.

### Phase 3 -- the corpus-completeness question

- [x] Decide whether a partially-classified corpus is acceptable at all, or
  whether pinning a corpus should oblige a complete ledger. Destination: D2.
  Selected: machine-check it. `scripts/external-corpus-ledger-lint.py` fails on
  any unclassified case or file.

### Phase 4 -- what this doc found but does not own

- [x] Fix Ctrl+`/` and Ctrl+digit sending the literal character (F4). Nine
  scalars missing from one switch, contradicted by kitty, ghostty, and
  windows-terminal alike. TDD: the failing test first. Landed in `bcb7847e`.
- [x] Delete the dead store pair at `Terminal.swift:5723-5724` (F9).
- [x] Decide whether DCS dispatch is worth implementing. Decided 2026-08-25:
  build the dispatch seam with XTGETTCAP and DECRQSS handlers, which is the pair
  ghostty and kitty both ship and neither exceeds. The seven upstream cases stay
  declined -- neither peer implements any of them -- so the Rejected entry below
  stands unchanged. Correction to this item as written: DECRQCRA's request is
  CSI, not DCS (`references/xterm/ctlseqs.txt:1830`), and only its reply is
  DCS-framed, so those 215 esctest2 cases were never blocked by the missing DCS
  seam. They are a separate decision, and it was declined the same day.
- [x] Graduate D3's three census rules out of research into whichever guide owns
  external corpus work. They now sit under "The mutation bar" in
  [agent-docs/reference-sources.md](../../../agent-docs/reference-sources.md),
  the guide that already owns adapting an upstream test.

## Rejected

### H1 -- that the unweighed files would out-yield doc 26's chosen three

Rejected by F11. Reflow, style, and color -- the three areas the engine changed
most this summer, and where H1 expected the most -- produced zero adoptions
between them. All five survivors came from input encoding.

The replacement explanation is worth more than the hypothesis was: novelty does
not track how recently the engine changed. It tracks whether DanTerm's coverage
in that area is **property-based or example-based**. Reflow is covered by a fuzz
walk and grapheme handling by a chunk-split invariance test; both generate cases
nobody wrote down, so an external example lands inside coverage that already
exists. Key encoding is covered by hand-written matrices, and a matrix has
exactly the rows someone thought of.

### Adopting the DCS-carried report cases

DECTABSR, DECCIR, DECRQSS, DECDLD, DECAUPSS, DECRQUPSS, and DECDMAC all stay
out-of-scope on one fact: `Terminal.swift` has no DCS dispatch. Implementing it
is a support-matrix decision that must precede the test change, per `26`'s
standing rule. Reopen this entry if that decision is taken.

That decision was taken on 2026-08-25 and this entry stands: the seam is being
built for XTGETTCAP and DECRQSS only, which is what ghostty and kitty both ship,
and neither peer implements any of these seven. Reclassifying them still needs a
new doc.

### Adopting the page-model cases

DECRQDE, PPA/PPR/PPB/NP/PP, DECPCCM, and DECXCPR's page field stay out-of-scope
because DanTerm has a single page with no page memory. Same rule: the capability
decision comes first.

### Adopting upstream's reflow compensation scenarios

Seven `ReflowTests.cpp` scenarios assert behavior that exists only because
windows-terminal builds its reflow buffer with zero scrollback -- destroyed rows
and `REFLOW_JANK_CURSOR_WRAP` padding synthesized to preserve a cursor column.
DanTerm's logical-line scrollback (doc 31) makes the compensation unnecessary.
These are `implementation-coupled`, not `out-of-scope`: nothing about DanTerm
makes them true or false.

## Open questions and caveats

- The census is a point-in-time read at `f016f5b6` against pin
  `1cea42d4`. Re-pinning windows-terminal invalidates it.
- `26/F9`'s novelty rate was measured on three files chosen for expected yield.
  Comparing this doc's rate against it is a comparison against a biased
  baseline, and F6 must say so rather than treating `26/F9` as an average.
- `ReflowTests.cpp` asserts reflow against windows-terminal's own buffer model.
  DanTerm's history is logical-line scrollback (doc 31), so a scenario may
  translate to a different but equally correct outcome. The specification does
  not settle reflow; where the two disagree, the disagreement is a policy
  finding, not a bug in either.
- tmux's 46 ISC `regress/` scripts remain unweighed and are explicitly *not* in
  this doc's scope. `26`'s Rejected section declines them as
  application-workflow evidence rather than fixture material; that declination
  stands until something reopens it.

## Outcome

Investigation complete. The 128 unweighed cases are classified, the ledger
covers all 213 cases in the corpus's fifteen case-bearing files, and five cases
are adopted as native tests: kitty flag 1 moving F1/F2/F4 off the SS3 form,
kitty flag 1 keeping a Shift-only text key as plain text, Ctrl+`@` emitting NUL,
Ctrl+`?` emitting DEL, and CAN/SUB aborting a DCS data string. Each was
mutation-verified before landing and re-verified independently afterward.

The one-line answer, for a reader who goes no further: a conformance corpus is
worth mining once, and the second pass over the same corpus yields little --
4% here, and every survivor from the one area whose coverage is hand-written
rather than generated.

Three results outlast the corpus work:

1. **Reading cannot settle a census** (`F8`, `D3`). Three reading-based verdicts
   were overturned by replayed fixtures, which assert a whole projection and
   name nothing. The charset work made the same error in the opposite direction.
   The mutation bar is the instrument; reading only decides what to mutate.
2. **An inert mutation looks exactly like an uncaught one** (`F10`). One
   candidate needed a two-site mutation before its regression reproduced at all.
   Probe-verify before trusting a survived result.
3. **A ledger's failure mode is silence, not error** (`D2`). An unread file and
   a file with nothing worth taking are indistinguishable in a manifest, which
   is how thirteen files stayed unjudged for a month.
   `scripts/external-corpus-ledger-lint.py` now makes that impossible.

Two engine defects were found and deliberately not fixed here: Ctrl+`/` and
Ctrl+digits `2`-`8` send the literal character instead of their C0 byte (`F4`),
and a dead store pair sits in the widening history pull-back (`F9`). Both are in
Phase 4.

**Reopening condition** (a new doc, per the one-way closure rule): re-pinning
windows-terminal to a newer revision, which the ledger lint will announce as an
I1 failure; or a support-matrix decision landing DCS dispatch or a page model,
either of which reclassifies a named family this doc declined.
