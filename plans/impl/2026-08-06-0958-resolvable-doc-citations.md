# Make doc citations in code resolvable

## Context

Since `docs/research/` started, code comments cite research findings by naked
id -- `I5`, `F4`, `19/F11` -- with nothing saying what tree the id lives in. A
reader hitting `// Why it exists: I3` in `RenderMetricsTests.swift` cannot tell
whether that is a research finding, a plan invariant, or a function key, and in
that particular case it is a plan invariant while research doc 21 also defines
an unrelated `I3`.

Four spellings are in use today (`19/F11`, `doc 15's F4`,
`` `docs/research/18-*.md` `F13` ``, bare `F4`), across several hundred sites.
There is no rule anywhere stating which is right.

Outcome: one notation, written down in `AGENTS.md`, and the existing citations
in code, scripts, and non-plan docs swept into it.

## The convention

**Research: `research/N/ID`** -- `research/15/F4`, `research/31/DD11`,
`research/28/H1`. The `research/` prefix names the tree, so the citation is
self-describing and needs no legend; the number is stable and
`docs/research/README.md` is the index that maps it to a path. No path line, no
per-file legend, no bare-id exception: outside `docs/research/`, this is the
only legal form for a research id.

`R15/F4` was the first candidate and is **rejected**: `R#` is already a research
id prefix (rejected-idea headings, e.g.
`docs/research/8-benchmark-variance-regression.md#R1`), and `Terminal.swift`
already cites one.

Inside `docs/research/` the bare `9/F3` cross-doc form stays -- `FORMAT.md`
mandates it and is deliberately portable. The `research/` prefix is what carries
a citation *out* of the tree.

**Design docs: path + id**, then bare id in the same file. A design doc is
durable and is the current statement of its contract, so a pointer beats a
paraphrase.

**Plan ids: don't cite them.** Restate what the invariant says in the clause
that would have carried the id, and drop the id. A plan describes work at the
moment it was done, and `I3` in one plan is `I3` in forty others.

## Scope

**In:** `lib/`, `app/`, `app-tests/`, `tests-ui/`, `scripts/` (incl.
`scripts/tests/`), `justfile`, `integrations/`, `agent-docs/`, `docs/design/`,
`docs/scratch/`.

**Out:** `plans/` (dated historical artifacts, left alone), `docs/research/`
itself (except one README line).

Use `git grep`, never `grep -r`: `.claude/worktrees/` holds two full duplicate
checkouts that triple every count, and `git grep` excludes them and `.build*/`
for free. Exclude `*.ttf` too -- the tracked `SymbolsNerdFontMono-Regular.ttf`
matches every citation regex.

**An empty search result must be proven, not assumed.** A malformed pathspec
still exits 0 through a pipe, so an empty count reads as "clean" when the search
never ran. Every search in this plan is trusted only after the same invocation
has been shown to return hits on a case known to exist.

## Finding that reshapes the job

**Roughly a hundred qualified citations are plan ids wearing a research doc
number.** Doc 31 defines no `I*`/`PO*`/`AR*`;
`plans/impl/2026-08-04-1137-logical-line-scrollback-store.md` does, and the ids
leaked into `31/…` form via doc 31 citing the plan. Same for `29/I*`/`29/PO*`
(which resolve to the *btop* plan, while research doc 29 is sparse damage clip
topology -- already wrong today) and `28/I3`.

Rewriting these to `research/31/I2` would assert something false, so they cannot
ride the mechanical pass. The doc-31 block is handled under **Deferred** below;
the rest are restated per the plan-id rule.

## Execution

Phases are ordered so that each one's leftovers are the next one's input. The
work groups are the contract; the tooling used inside a phase is
implementation discretion.

### Phase 0 -- preflight, no edits

Build the **resolution table** in the scratchpad -- one line per distinct
`N/PREFIX#` token found in scope, plus every distinct bare id in the Phase 4
files, each resolved against `docs/research/` headings. This artifact is what
keeps the sweep from minting `research/31/I2`. Four buckets:

| Bucket | Disposition |
| --- | --- |
| Research heading exists under `docs/research/N*/` | Qualify to `research/N/ID`. |
| Plan-owned (defined in a `plans/` file) | Restate per the plan-id rule. |
| Deferred doc-31 contract (`I*`/`PO*`/`AR*`) | Leave as-is. |
| Not a citation (layout label, hex byte, scalar range, function key) | Leave as-is. |

Prefix alone never decides the bucket -- plan-owned ids appear under research
doc numbers, and a research-owned *prefix* does not mean a given id resolves
(there is no `C1` heading anywhere in `docs/research/`, so the `C1` cell-word
references in the probes are layout labels, not citations).

Prefixes seen on research headings: `F`, `D`, `DD`, `H`, `HR`, `C`, `R`. Seen on
plan headings: `I`, `PO`, `AR`, `RI`. Treat both lists as a search hint for
building the table, never as the answer.

### Phase 1 -- mechanical: qualified `N/ID` form

Rewrite `N/ID` -> `research/N/ID`, but only for `N/PREFIX` pairs the Phase 0
table resolved to a research heading. Any codemod is a throwaway in the
scratchpad, **never committed** -- `scripts/` holds only durable tools and the
tree has no codemod precedent.

Must not touch: anything on the manual list, anything where the `N/` is part of
a real path or date, anything bare, and the entries in the do-not-touch table
below.

**PO1 -- one-for-one rewrite.** `git diff --stat` cannot prove this: several
citations share a line, and one substitution produces both a deletion and an
insertion. The obligation is a mechanical comparison of the **occurrence
multiset** of allowlisted tokens before and after the rewrite: every token's
count matches, and none remains unqualified. The rewrite must also be
idempotent -- a second run produces no diff -- so it cannot re-qualify its own
output. `swift build --package-path lib/TerminalCore` passes.

### Phase 2 -- path and glob form

Per-site. Distinguish markdown *links* to a doc (leave them -- they are links,
not citations) from path+id *citations* (normalize to `research/N/ID`). Known
shapes: glob paths (`docs/research/18-*.md`), the comma form
(`(docs/research/15, F6)`) in the `justfile`, the shell-integration files' doc-24
`D0` citation (confirm `D0` exists before qualifying), and
`docs/scratch/wezterm-test-portage.md`'s `findings.md#F8`, which borrows the
`file#identifier` form from `## Local source references` -- the new AGENTS.md
section must say that rule governs `references/`, not DanTerm's own docs.

### Phase 3 -- prose form

Per-site, no script: the natural-language shapes (`doc 15's F4`, `doc 19,
finding F11`) are found by search but resolved by reading. Heaviest in
`TerminalMemoryCensus.swift`, `Terminal.swift`, and
`TerminalMemoryProbeSupport.swift`.

Do **not** delete bare "doc 31" mentions with no id attached -- those are prose
naming an investigation, not citations, and stay as they are.

### Phase 4 -- bare ids in the doc-focused files

A handful of files -- the `TerminalLogicalLine*Probe.swift` probes and
`scripts/terminal-retained-row-shape.py` -- grew up around one research doc and
use bare ids throughout their bodies. Under the convention the research ones get
qualified like any other citation; there is no per-file scope declaration.

**Their bare ids are not all doc 31's, and are not all citations.** These files
mix in plan-owned invariants (`I2` in
`TerminalLogicalLineBlankIndexProbe.swift#buildBlankStimulus` is the
packed-retained-row plan's), deferred doc-31 contract ids (`AR6` across
`TerminalLogicalLineEvictionProbe.swift` -- doc 31 *references* it, the plan
defines it), and pure layout labels (the `C1` cell word). Qualifying by file
subject would mint `research/31/I2` and `research/31/AR6`, which is the exact
failure Phase 0 exists to prevent. Resolve every distinct bare id in these files
through the Phase 0 table first, then act by bucket: qualify, restate, or leave.

This phase is per-file and manual. A bare-id regex is not usable: `E4-A29`,
`CA6-C133`, `E15-B2` in the sprite/unicode tables are Unicode scalar ranges, and
`F1`/`D4`/`C9` are hex bytes. The file list is the unit of work, not a pattern.

### Phase 5 -- plan-id restatement

Per-site judgment: read the plan's invariant, write the clause, drop the id.
Grouped by owning plan (see the commit list). Excludes the doc-31 block -- see
Deferred.

## Do not touch / decision rules

| Case | Rule |
| --- | --- |
| Ranges (`29/F3-F7`, `F21-F25`) | Prefix once: `research/29/F3-F7`. One citation of one doc. |
| Slash-lists (`doc 15's F3/F5`) | Split: `research/15/F3` and `research/15/F5`. `/` is already the doc separator. |
| `DD`, `HR`, `C` prefixes | Research-owned; normal form (`research/31/DD11`). |
| `31/F6 R16` in `Terminal.swift` | `R16` is a table-row id inside a finding, not a namespace. Cite `research/31/F6`, restate R16 in words. |
| Prose whose grammar needs the doc as a noun | Keep the sentence, append the citation in parens. Never mangle a sentence to fit a token. |
| `scripts/{research-index,kitty-parity,alacritty-parity}-lint` `I1`-`I8` | **Definitions**, not citations -- the files define them in their own headers. Leave alone; skip by path. |
| `TerminalSemanticPromptInvariantViolation` raw values in `Terminal.swift` (`case ownership = "I1 ownership"`) | Enum **raw values**, serialized into corpus failure output. Do not touch. Only the surrounding doc comment changes. |
| `scripts/saturate-scrollback.sh` heredoc | Citations printed to the operator. Safe to rewrite (nothing asserts on it), but call it out in the commit message and read the rendered help text. |

Previously-unresolvable citations, now resolved -- fix them, do not leave TODOs:

- `TerminalPackedRetainedRowTests.swift` `PO2`/`PO3`/`I3` -> owned by
  `plans/impl/2026-08-03-2357-packed-retained-rows.md`. The comment attributing
  `PO3` to doc 28 is wrong. Restate.
- `TerminalLogicalLineStoreTests.swift` `28/I3` -> same plan. Doc 28 has no
  `I3`. Restate.
- The bare `D1` in `terminal-benchmark-validation.py` and
  `terminal-benchmark-median-fallback.py` -> `research/7/D1`
  (`7-fast-performance-benchmarks.md`, "minimum effects of interest and required
  accuracy rates" -- exactly the 60-trial rule and the injected-effect gates
  those sites describe).
- `tests-ui/SidebarSelectionCacheTests.swift`'s "the F1 over-retention case" --
  genuinely unowned. Delete the id, keep the description.

## Docs to write

**`AGENTS.md`** -- new `### Citing docs` at the **end of `## Code Style`**
(after `### Tests`, before `## Build`). `## Code Style`'s subsections are
per-context gates for file headers, declarations, and tests; citations cross all
three, so the rule reads correctly placed after them. Content: the three rules
under "The convention" above, each with its one-line why, matching the file's
rule-first voice.

**`AGENTS.md`'s existing `file#identifier` rule** -- the "Cite refetchable
source trees as `file#identifier`, never `file:line`" paragraph under
`## Local source references`. Append a pointer: as written, `file#identifier`
and `research/N/ID` look contradictory, and a reader hitting the `#` form in
`docs/scratch/` cannot tell which governs. Say that rule is for `references/`,
and cross-reference the new section.

**`docs/research/README.md`** -- one bullet at the top of `**Project notes.**`,
stating the external `research/N/ID` form and that `FORMAT.md`'s bare `9/F3` is
the within-tree form. README, not FORMAT: FORMAT.md forbids links resolving
outside `docs/research/`, and this rule points at `AGENTS.md`.

## Deferred, not in this plan

**Doc 31's `I1`-`I11`.** These are the live contract of `LogicalLineStore.swift`,
not a historical note, and restating 11 invariants across ~85 sites is the wrong
trade. The right move is the one
`docs/design/2026-08-01-osc-133-prompt-anchoring.md` already set a precedent for:
graduate them out of the plan into a design doc and cite that by path+id. That is
a real design decision and would be unreviewable buried inside a mechanical
commit, so it gets its own plan. The `AGENTS.md` rule already names this escape
hatch ("when restating the same invariant across many files gets tiresome, that
is the signal it has outlived its plan").

Consequence to state honestly: after this sweep, `31/I2` and friends remain in
their current form and are the one inconsistency left in scope.

**A citation lint.** Decided against for now -- too many classes of false
positive (function keys, hex bytes in JSON fixtures, escape sequences, vendored
checkouts, self-defining script headers). Revisit once the sweep shows which
ones actually bite.

## Non-goals / accepted risks

- **AR1 -- bare research ids outside the known file list may survive.** There is
  no reliable bare-id regex (hex bytes, Unicode scalar ranges, function keys all
  collide), so Phase 4 works from a file list rather than a pattern and the
  post-sweep search cannot prove the absence of bare ids. Accepted: the residue
  is in files nobody has flagged, and a lint that would catch it is itself
  deferred for the same false-positive reason.
- **AR2 -- `research/N/ID` requires the README index to resolve a number to a
  path.** One indirection, on a stable number, in exchange for one notation
  everywhere. The alternative -- a per-file path line -- was tried in an earlier
  draft and created a second notation to police.

## Rejected ideas

- **RI1 -- `R15/F4`.** `R#` is already a research id prefix; the citation would
  collide with real rejected-idea headings.
- **RI2 -- per-file first-citation path line, and per-file bare-id scope
  declarations.** Three rules instead of one, with header declarations to
  maintain, and the two interacted badly: the mechanical pass qualifies the very
  ids a scope header would have covered.
- **RI3 -- graduate doc 31's contract into a design doc *first*, as a hard
  predecessor to this sweep.** It would remove the deferred bucket, but it gates
  eleven commits of independent, purely-mechanical value on an unrelated design
  decision of unknown size. The 85 deferred sites are exactly as resolvable
  after this sweep as before it -- the residue is non-regressive and written
  down -- so the sequencing buys consistency at the price of blocking the work
  that creates the rule the consistency is measured against.

## Verification

Five residual searches over the in-scope paths, each trusted only under the
empty-result rule in Scope:

1. No unqualified `N/ID` token survives, except the deferred `31/I*`, `31/PO*`,
   `31/AR*`.
2. No prose `doc N's ID` citation survives. Bare "doc 31" with no id attached is
   legal and stays.
3. No glob path form (`docs/research/18-*.md`) survives.
4. **Every distinct `research/N/ID` token resolves to a real heading in
   `docs/research/`.** This is the whole verification obligation: one notation,
   all of it resolvable.
5. `Terminal.swift`'s `TerminalSemanticPromptInvariantViolation` raw values are
   untouched by the diff.

`just test` per commit boundary. No test asserts on citation text: the
source-reading tests in `scripts/tests/` (e.g. `HarnessBuildContractTests`,
which reads the benchmark harness script) assert on build flags and paths, not
comments -- so the only realistic break is a comment mangled into a syntax
error. `swift build --package-path lib/TerminalCore` after each mechanical phase
catches that faster.

Eyeball the one thing tests cannot see: run `scripts/saturate-scrollback.sh`'s
help path and read the operator-facing heredoc.

## Commit progress

- [x] 1. `docs(agents): standardize how DanTerm's own docs are cited` -- AGENTS.md section + `## Don't guess` cross-ref + docs/research/README.md bullet. No code.
- [x] 2. `docs(terminal): qualify research citations in the terminal core` -- Phases 1-3 over `lib/TerminalCore/Sources/`.
- [x] 3. `docs(terminal): qualify research citations in the terminal tests` -- Phases 1-3 over `lib/TerminalCore/Tests/`.
- [x] 4. `docs(scripts): qualify research citations in the benchmark tooling` -- `scripts/`, `scripts/tests/`, `justfile`. Message notes the `saturate-scrollback.sh` operator-visible text.
- [x] 5. `docs(guides): qualify research citations in the agent and design docs` -- `agent-docs/`, `docs/design/`, `docs/scratch/`, `integrations/`; includes Phase 2's glob and comma-form fixes.
- [x] 6. `docs(terminal): resolve the doc-focused probe files' bare ids` -- Phase 4. Mixed mechanical and judgment work; message names the plan-owned ids restated and the deferred ones left alone.
- [x] 7. `docs(config): restate the font-family plan's invariants inline` -- `app/`, `lib/DanTermCore/`, `tests-ui/`, `RenderMetricsTests.swift`.
- [x] 8. `docs(recovery): restate the checkpoint plan's invariants inline` -- checkpoint tests in `lib/DanTermSupport/`, `lib/DanTermCore/`, `app-tests/`.
- [ ] 9. `docs(scripts): restate the btop diagnostic plan's invariants inline` -- `terminal_btop_*`, `terminal-benchmark{,-profile}.sh`, plus the mis-attributed `29/I*`/`29/PO*`. Message names the mis-attribution.
- [ ] 10. `docs(scripts): restate the paired-benchmark plan's invariants inline` -- `terminal_benchmark_{compare,snapshot}_test.py`, `terminal_draw_acceptance_test.py`, plus the two bare `D1` -> `research/7/D1`.
- [ ] 11. `docs(terminal): restate the packed-retained-row plan's invariants inline` -- `TerminalPackedRetainedRowTests.swift`, `TerminalLogicalLineStoreTests.swift`, `SidebarSelectionCacheTests.swift`.

Commits 2-6 are the mechanical block and can split further by directory if the
diffs are too large to review in one pass. Commits 7-11 are judgment work and
should not be batched -- each requires reading a different plan.
