# Decisions -- the unweighed windows-terminal corpus

Append-only. One entry per stable ID. See
[README.md](README.md) for the doc's purpose, rules, and task ledger.

Cross-doc IDs are qualified: `D1` is this doc's, `26/D2` is doc 26's.

### D1 -- what to adopt from the twelve unweighed files

- Status: decided.
- Evidence used: F1-F7, F10, F11.
- Decision: adopt five cases, all from input encoding. Decline the other 123.

  | Case | Source | What it pins |
  | --- | --- | --- |
  | `KeyPressTests` rows `D F1`/`F2`/`F4` | `kittyKeyboardProtocol.cpp` | kitty flag 1 moves F1/F2/F4 off the legacy SS3 form to `ESC [ P`/`Q`/`S` |
  | `KeyPressTests` row `D Shift+a` | `kittyKeyboardProtocol.cpp` | under kitty flag 1, Shift alone on a text key stays plain text |
  | `TerminalInputNullKeyTests` | `inputTest.cpp` | Ctrl+`@` emits NUL |
  | `DifferentModifiersTest` | `inputTest.cpp` | Ctrl+`?` emits DEL |
  | `DcsDataStringsReceivedByHandler` | `StateMachineTest.cpp` | CAN and SUB abort a DCS data string |

- Tradeoffs and correctness risks: all five are `adapted`, not `adopted`. Four
  translate from Win32 `INPUT_RECORD` construction or a kitty flag-set table into
  `encodeTerminalKey` calls; the fifth translates from a `dcsDataString` handler
  callback into public stream actions. None can be a replay fixture: the fixture
  format feeds bytes *into* the terminal, and four of these five assert bytes the
  terminal *emits* for a key event, which is the opposite direction. They land as
  native tests, and the manifest cites the native test as their evidence.
- Behavioral verification: every adoption candidate passed the mutation bar --
  break the engine behavior the case asserts, confirm the existing suite stays
  green. Six candidates were falsified there (F7), three of them by replayed
  fixtures that no reading could have credited (F8).
- **Additional gate from F10**: probe-verify each mutation before trusting a
  SURVIVED result. An inert mutation and an uncaught mutation both present as
  "suite green", and the emoji-cluster candidate needed a two-site mutation
  before it reproduced its regression at all. Apply this to all five before
  landing.
- Rejected, and why, for the large families: 45 `out-of-scope` cases split into
  two clusters that each turn on **one** capability. Seven DCS-carried reports
  (DECTABSR, DECCIR, DECRQSS, DECDLD, DECAUPSS, DECRQUPSS, DECDMAC) are blocked
  by `Terminal.swift` having no DCS dispatch at all. Five page-model cases
  (DECRQDE, PPA/PPR/PPB/NP/PP, DECPCCM, DECXCPR's page field) are blocked by
  DanTerm having a single page. Both are support-matrix decisions that must
  precede any test change, per `26`'s standing rule.

### D2 -- whether pinning a corpus obliges a complete ledger

- Status: open.
- Evidence used: the README census table; `26/D2`;
  `TerminalFixtureTests.swift:279`.
- Problem: doc 26 pinned windows-terminal, classified 71 of 199 cases, and left
  no record *in the manifest* that the ledger was partial. The manifest lists
  three `files` entries and nothing marks the other thirteen as unread, so the
  JSON reads as complete. That is how 128 cases stayed unweighed for a month
  while the engine changed underneath them.
- Where partiality *is* recorded: only in the test.
  `TerminalFixtureTests.windowsTerminalManifestCoverage` is titled "classifies
  the scoped conformance files", its preamble says "the three Phase 3 source
  files", and it asserts the manifest's path set equals a hardcoded
  three-file map (`TerminalFixtureTests.swift:304`, `:311`). So the boundary is
  pinned -- adding a file to the manifest fails the test until the map is
  updated -- but the boundary is stated nowhere a reader of the manifest, or of
  the corpus, would look. The test pins that the ledger covers three files; it
  cannot pin that thirteen more exist.
- Contrast with the other ledgers: the libvterm and Alacritty manifests really
  are complete against their corpora (`26/F1` diffs both directions and gets
  zero unclassified entries). windows-terminal is the only partial one, and
  nothing in its file distinguishes it from the two complete ones.
- Mechanical note: the disposition allowlist in the coverage test gained
  `implementation-coupled` (see `H2`), which the libvterm and Alacritty ledgers
  do not need and should not gain -- those corpora drive their engines through a
  byte stream, so they have no class-level cases to file under it.

### D3 -- reading cannot settle a census; the mutation bar is the instrument

- Status: decided.
- Evidence used: F8, F10, and the six falsifications in F7.
- Problem: this doc's census was performed by reading test files against engine
  source. That method was wrong in both directions and in both a false-positive
  and a false-negative form:
  - Three candidates that reading called novel were caught by **replayed
    fixtures** (`libvterm/state-pen`, `libvterm/state-input`, the resize fuzz
    walk). A fixture asserts a whole projection at once and names nothing, so no
    amount of reading test titles finds it.
  - The charset re-adjudication in `06e158b4` made the opposite error: reading
    called three cases covered when they were not.
- Decision: the mutation bar is the census instrument, not a final check.
  Reading is the cheap filter that decides what to mutate. Every adoption in
  this doc passed it, and the six that did not were declined.
- Second rule, from `F10`: **probe-verify a mutation before trusting a SURVIVED
  result.** An inert mutation and an uncaught mutation both present as "suite
  green". The emoji-cluster candidate needed a two-site mutation before its
  regression reproduced at all, because `recoverClusterContextFromGridIfNeeded`
  rebuilds the state the single-site mutation cleared. Reporting either
  single-site run would have adopted a test for an unbreakable behavior.
- Third rule, from `F7`: **let the mutation dictate the test's shape.** For all
  five survivors the obvious test passes against the mutant -- kitty F1/F2/F4
  must be asserted unmodified, Ctrl+`@` must be asserted on `@` rather than
  space, and the kitty Shift row needs Shift alone. A test written from the
  case's title rather than from the regression it must catch passes for the
  wrong reason.
- Destination: these three rules are about external corpus work generally, not
  about windows-terminal. They belong in whichever guide owns that subject
  rather than only here. Not yet graduated.
- Candidate solutions:
  1. Require a complete ledger whenever a corpus is pinned: every file, every
     case, a disposition each. Expensive up front, and it forces judgment on
     cases nobody has a reason to care about yet.
  2. Keep partial ledgers, but make partiality explicit and machine-checked: the
     manifest gains the corpus's full file inventory, and a test fails when a
     file in the tree has no entry. Unread files carry an explicit
     `unclassified` marker rather than being absent.
  3. Keep partial ledgers and rely on periodic batch re-synchronization, which
     is the model selected on 2026-08-25 for rationale staleness.
- Tradeoffs and correctness risks: (2) is the only option under which "the
  ledger is silent about this file" and "the ledger has judged this file" are
  distinguishable. (3) already governs rationale staleness, and this doc is the
  first batch under it, so choosing (3) here is consistent -- but rationale
  staleness and ledger *incompleteness* have different failure modes: a stale
  rationale is a wrong claim, an absent file is no claim, and only the first is
  visible to a reader who trusts the file.
- Selected direction: option 2, and the ledger is now complete as well.
  `scripts/external-corpus-ledger-lint.py` reads the pinned checkout, extracts
  every case, and fails on any case or file the manifest does not classify (I2,
  I4), on any manifest entry naming a case that does not exist upstream (I3),
  and on a `pinnedCommit` that does not match `fetch-references.py` (I1).
- Why the lint rather than the test: the question "does the ledger cover the
  corpus" can only be answered against the corpus, and `references/` is
  gitignored, so the test bundle cannot see it. The existing coverage test could
  therefore only ever pin what the ledger *claimed*, never what it *missed* --
  which is exactly how it passed for a month while thirteen files went unread.
- The skip is deliberate and is the one part worth arguing about: with no
  checkout, I2-I4 are unanswerable and the lint exits 0 after saying so. A
  completeness check that reported success having read nothing would be worse
  than no check, so the self-test pins the wording of the skip, not just its
  exit status. I1 is still checked without a checkout, because it is answerable
  from the repository alone.
- Behavioral verification:
  `scripts/tests/external-corpus-ledger-lint_test.sh` builds fixture trees and
  pins all four invariants in both directions, plus the skip and the
  incomplete-ledger-with-no-checkout case. Both are registered in the gate.
- Second change, in the coverage test: the hardcoded 71 case names became
  per-file counts. Mirroring all 213 names in Swift would be a second copy of
  the ledger under no maintenance -- the failure the research index format rule
  warns about -- and the lint now checks the names where they can actually be
  checked. The test keeps what only it can hold: the file inventory, the counts,
  the disposition vocabulary, and the names of the seven cases that produced a
  fixture or a test.
- Decision and rationale: partiality is now impossible to reintroduce silently.
  A new upstream file, a renamed case, or a pin bump each fail the gate for
  whoever runs it with a checkout, and say plainly what is unjudged.
