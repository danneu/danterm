# Decisions -- external test corpus expansion

Every decision below inherits doc 1's standing constraints: pin every imported
corpus, preserve source path and license in fixture metadata, never
regenerate-and-auto-accept another emulator's output as DanTerm truth, and
review obligations before copying or translating GPL/LGPL test code.

### D1 -- re-adjudicate the two stale libvterm rationales

- Status: selected and implemented.
- Evidence used: F3 (`92lp1640917`, blocked on Milestone 6), F4 (seven
  `90vttest_*` recordings, blocked on Milestone 4 staging), F2 (the contrast:
  every other out-of-scope rationale is still accurate).
- Candidate solutions:
  1. Adopt all eight now (seven recordings plus the mouse case), leaving
     `90vttest_01-movement-1` out-of-scope on its DECALN dependency.
  2. Adopt only `92lp1640917`, which F3 shows covers an uncovered behavior, and
     leave the recordings until Milestone 9 needs them.
  3. Rewrite the rationales for accuracy but change no disposition.
- Tradeoffs and correctness risks: (1) costs the most fixture-authoring and
  carries F4's real risk that some recordings duplicate `state-mode.json`,
  `state-movecursor.json`, and the tab-stop fixtures -- the Alacritty `vttest_*`
  entries all resolved `superseded`, which is a prior against novelty. (2) is
  the highest confidence-per-unit-work but leaves seven rationales lying.
  (3) fixes the manifest's accuracy without improving coverage, and is strictly
  contained in the other two.
- Recommendation: (1), sequenced as (3) first so no rationale cites a checked
  milestone as a live blocker regardless of how the dispositions land, then
  `92lp1640917`, then the recordings one at a time with `superseded` as a
  legitimate per-file outcome. Do not force `adopted` on a recording whose
  behavior existing fixtures already pin -- a defensible `superseded` with named
  evidence is the same quality of result.
- Direction review: accepted by the owner on 2026-07-31.
- Selected direction: option 1, with `superseded` retained as a valid per-file
  result for any recording whose behavior existing fixtures already pin.
- Behavioral verification: each adopted case replays as a neutral fixture
  through public inspection views, one-chunk and at split points, matching the
  existing runner's contract.
- Decision and rationale: fix every stale rationale, adopt the uncovered mouse
  case, then adjudicate the seven supported recordings individually. This
  repairs manifest accuracy immediately without forcing duplicate recordings
  into the maintained fixture set.
- Implementation result: all eight reclassifiable cases are `adopted`; the
  seven recordings proved novel at the session-interleaving level even though
  isolated fixtures cover their individual sequence families.

### D2 -- whether to mine Ghostty and windows-terminal as case sources

- Status: decided; adopt windows-terminal narrowly and decline Ghostty as a
  maintained corpus for this scope.
- Evidence used: F5 (1689 `test` blocks under `.ghostty-src/src/terminal/`, MIT,
  never in doc 1's candidate table), F8 (windows-terminal's ~183 `TEST_METHOD`
  conformance suite, MIT, also never surveyed), F8's third inference (xterm
  `ctlseqs.txt` is now local and can serve as the adjudication instrument).
- Candidate solutions:
  1. Mine both, Ghostty for scrollback/selection/style and windows-terminal for
     parser/adapter/mouse/base64 conformance.
  2. Mine windows-terminal only, on the grounds that a spec-organized
     conformance suite is a safer source than the incumbent engine's own tests.
  3. Mine Ghostty only, on the grounds that it is the behavior DanTerm is
     replacing and disagreements are most diagnostic there.
  4. Decline both and treat Milestone 8's Slice 18 adjudication as covering
     them by analogy.
- Tradeoffs and correctness risks: Ghostty carries the highest reference-bug
  risk of any source in this doc, precisely because it is the incumbent -- a
  Ghostty-derived expectation that merely restates Ghostty's behavior would make
  the thing being replaced normative, which is the failure doc 1's neutrality
  rule exists to prevent. Much of `PageList.zig` and `page.zig` tests a paged
  storage model DanTerm does not share and would violate the
  no-private-structures rule. windows-terminal is lower-risk on both counts but
  is C++/WEX and tests a different buffer model; its value concentrates in
  `OutputEngineTest.cpp`, `Base64Test.cpp`, and `MouseInputTest.cpp`.
  (4) is cheap but rests on an analogy F8 explicitly rates as weak for a
  conformance suite.
- Recommendation: (1), scoped rather than exhaustive, and gated on a novelty
  check against the native suite before any fixture is authored. Justify every
  imported expectation against `references/xterm/ctlseqs.txt` or the DanTerm
  contract, never against the source engine's behavior. Start with
  windows-terminal's three named files, because they map onto gaps this doc
  already found rather than onto a size signal.
- Direction review: accepted by the owner on 2026-07-31 by continuing the Phase
  3 mine and confirming DanTerm's existing stricter malformed-SGR policy.
- Selected direction: option 2. Adopt the two non-ASCII OSC 52 decode cases
  shared by `Base64Test.cpp#DecodeUTF8` and
  `OutputEngineTest.cpp#TestSetClipboard`. Decline the rest of the three scoped
  windows-terminal files and all three scoped Ghostty files as already covered,
  unsupported, or implementation-coupled.
- Behavioral verification: `Fixtures/windows-terminal/osc52-unicode.json`
  replays both adopted payloads through the public clipboard-write channel
  whole, bytewise, and at every split point. The complete 71-method ledger is
  `windows-terminal-manifest.json`; its notice is
  `LICENSE.windows-terminal.txt`.
- Decision and rationale: F9 found two novel supported expectations in 4,315
  windows-terminal lines and none in 10,777 Ghostty test-section lines. The
  selected payloads test OSC 52's valid Base64-to-UTF-8 boundary without changing
  DanTerm's canonical padding, strict UTF-8, write-only, or size policies.
  Ghostty's portable cases are already covered through stronger public
  projections; its remaining cases describe pages, pins, caches, style maps, or
  unsupported features. Maintaining a Ghostty-derived corpus for zero new
  behavior would add neutrality and license overhead without coverage.

### D3 -- close the Unicode and decoder fixture gaps

- Status: selected and implemented.
- Evidence used: F6 (nine imported decoder cases against a hand-rolled
  `UTF8Decoder.swift`; `GraphemeBreakTest` 17.0.0 pinned, no `WordBreakTest`),
  F8 (vte's `utf8-test.cc` and `unicode-width-test.cc` sit on the same gap but
  are LGPL-3.0/GPL-3.0).
- Candidate solutions:
  1. Pin Markus Kuhn's `UTF-8-test.txt` for decoder boundary coverage, and pin
     `WordBreakTest.txt` only if word selection claims UAX #29 semantics.
  2. Translate vte's `utf8-test.cc` scenarios instead.
  3. Decline both, on the grounds that native decoder tests may already cover
     the boundary space.
- Tradeoffs and correctness risks: (1) uses freely redistributable data and the
  generator path `GraphemeBreakCorpus.generated.swift` already established, so
  its cost is low and its licensing is clean. Kuhn's corpus will disagree with
  DanTerm on the recorded U+10FFFF and U+FFFD deviations, so it lands partly as
  `adapted` -- expected, not a defect. (2) reaches the same coverage through a
  license doc 1's rules require reviewing first, which is strictly more
  friction for no more coverage. (3) is only defensible if the audit shows
  native coverage is already complete, which has not been run.
- Recommendation: (1), sequenced behind an audit of native `UTF8Decoder`
  coverage so the corpus is not adopted to duplicate tests that exist. Treat
  the `WordBreakTest` half as a contract question first: pin it only if
  double-click word selection is meant to claim UAX #29 word semantics.
- Direction review: accepted by the owner on 2026-07-31.
- Selected direction: option 1 for decoder coverage, without `WordBreakTest`.
- Decision and rationale: adopt a compact neutral fixture derived from every
  Kuhn category under CC-BY-4.0 and retain DanTerm's modern maximal-subpart
  expectations. Double-click selection is terminal-oriented: every Unicode
  whitespace scalar and a fixed punctuation set are separators, while period,
  slash, hyphen, underscore, and equals keep paths, flags, identifiers, and
  assignments intact. It therefore does not claim default UAX #29 word
  boundaries, so `WordBreakTest.txt` is declined. vte's decoder and width cases
  are also declined because the neutral fixture closes the decoder gap and the
  generated native suite already exhaustively covers the width policy without
  importing LGPL-3.0/GPL-3.0-derived cases.
- Implementation result: `utf8-decoder-corpus.json` records source version,
  SHA-256, license, every Kuhn category, modern replacement counts, printable
  recovery, U+10FFFF, and all Unicode noncharacters; its attribution is
  `LICENSE.UTF-8-test.txt`. `Terminal.terminalTokenRange(at:)` owns the
  hard-coded double-click contract and classifies projected units by their
  leading scalar.

### D4 -- whether manifest re-adjudication becomes a standing milestone-exit step

- Status: decided; no standing milestone-exit step.
- Evidence used: F3 and F4 -- two rationales citing blockers that resolved one
  and four milestones ago; and the asymmetry that Milestone 8 Slice 1
  re-adjudicated the Alacritty vttest ledger while leaving the libvterm one
  untouched. Supports H2.
- Candidate solutions:
  1. Add a milestone-exit step: any manifest rationale citing a milestone that
     just closed must be re-read and either reclassified or rewritten.
  2. Forbid milestone references in rationales entirely -- state the missing
     capability instead, which does not go stale.
  3. Do nothing; re-adjudicate ad hoc when someone notices.
- Tradeoffs and correctness risks: (2) is the more durable fix and is nearly
  free at classification time, since "DECALN is not implemented" is both more
  informative and more stable than "staged as Milestone 4 acceptance evidence".
  It does not help the entries already written. (1) catches those but adds a
  recurring step, and this doc is evidence the step gets skipped for one corpus
  while being done for another. (3) is what produced F3 and F4.
- Recommendation: both (2) going forward and (1) as a one-time sweep folded into
  D1's rationale rewrite. Prefer capability-stated rationales; the existing
  milestone-stated ones are what D1 is already fixing.
- Direction review: accepted by the owner on 2026-07-31.
- Selected direction: option 2 going forward, plus option 1 as the completed
  one-time sweep in D1.
- Decision and rationale: manifest rationales must state the missing capability
  or coverage fact rather than a milestone number. This prevents the observed
  staleness at classification time and avoids a recurring process step; D1's
  sweep repairs the existing affected entries.

### D5 -- what actually closes Milestone 9's external leg

- Status: recommended framing; not a decision to implement anything yet.
- Evidence used: F7 (neither esctest2 nor vttest is pinned or runnable, while
  their prerequisites -- real PTY, host replies, documented capability contract
  -- all landed in Milestones 3-7), F1 (the corpora are fully classified, so
  there is no mining backlog to work through first).
- Candidate solutions:
  1. Build the esctest2 subset and the replayable vttest sessions, and assemble
     the pinned evidence package.
  2. Record an owner waiver for one or both legs, as Milestone 8 waived scripted
     workflow automation and DanTerm-owned recordings, and restate doc 1's close
     condition accordingly.
- Tradeoffs and correctness risks: esctest2 is GPL-2.0 and must be run as a
  separately fetched pinned program, never vendored -- a boundary doc 1 already
  set. The real risk in (1) is scope: esctest2 covers far more than DanTerm's
  advertised capability contract, so the subset must be selected against that
  contract or the gate will fail on unpromised behavior. (2) is legitimate but
  must be written down, because doc 1 closes on this package existing and an
  unrecorded waiver would leave doc 1 permanently live.
- Recommendation: (1), with the subset scoped against the advertised capability
  contract before any run, and every failure reduced to the smallest native
  byte-stream fixture before it is fixed. If the owner prefers (2), record it
  here so doc 1 has a close condition it can actually meet.
- Direction review: pending.
- Selected direction: pending.
- Decision and rationale: pending.
