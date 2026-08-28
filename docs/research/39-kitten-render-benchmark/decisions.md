# Decisions

## D1 -- Fixture source for the kitten byte streams

DECIDED 2026-08-28: port the generator, do not record.

The generator is `references/kitty/tools/cmd/benchmark/main.go`. It was
outside the sparse cone, but the pinned commit's objects were already local,
so `just fetch-references kitty` now includes `references/kitty/tools/cmd/benchmark`
and `references/kitty/tools/tty` (the writer whose behavior `F3` cites).

What the generator does, per arm, before the `\x1b[m\x1b[H\x1b[2J` +
`Running: ...\r\n` reset that follows every repetition:

- `ascii`: 2,097,165 bytes drawn by uniform index from kitten's 88-entry
  `ascii_printable` + `control_chars` string, using an unseeded `math/rand/v2`.
  It is an indexed string and not a set: space appears twice in it, so space is
  twice as likely as any other character. An earlier reading of this decision
  said "94 printable ASCII characters", which is neither the count nor the
  distribution.
- `unicode`: a fixed Chinese lorem ipsum plus a fixed misc-Unicode block plus
  `\n\t`, repeated 1024 times. Deterministic.
- `unique_unicode`: 262,144 cells of `a` followed by three combining marks
  from U+0300..U+036F, indexed base-112 by the cell number. Deterministic.
- `csi`: chunks chosen by an unseeded random draw from seven fixed escape
  strings and a random ASCII run of 1-72 bytes, until 1,048,593 bytes.

Two of the four arms are random and unseeded, so a recording is bit-exact to
one run and nothing else; "bit-exact to what kitten sends" does not exist for
`ascii` or `csi`. A port with a fixed seed is regenerable, reproducible across
machines, and statistically the same stimulus. It also makes the alt-screen
wrapper (`\x1b[?1049h`, `\x1b[?25l`, the per-repetition reset, the
`\x1b[5n` x3 tail) part of the fixture rather than an artifact of one capture.

Rejected alternative: capture one run with `danterm pane tape` and commit the
bytes. It is available today with no code, but 200 MiB per arm is not a
fixture that belongs in the repository, and it freezes one random draw.

Ideal beside it: the same port, plus a periodic check that the local
`references/kitty/tools/cmd/benchmark/main.go` still matches the constants the port encodes.
`just test-tooling` can assert the string constants against the reference
file once the port exists; that is the Phase 2 headless task's job.

DONE: `scripts/kitten-benchmark-parity-lint.py` parses
`references/kitty/tools/cmd/benchmark/main.go` and
`references/kitty/tools/tui/loop/terminal-state.go` for every constant the port encodes, asks the built executable for its
own account of them, and pins both reference files by hash.

## D2 -- Freeze the four `kitten-feed-*` decision rules

DECIDED 2026-08-28: freeze all four arms at 2 pairs, the same cell in `quick`
and `confirm` -- `kitten-feed-ascii` +/-1.70%, `kitten-feed-unicode` +/-1.80%,
`kitten-feed-unique-unicode` +/-1.60%, `kitten-feed-csi` +/-1.45%. Each name
moves out of `CANDIDATE_WORKLOADS` into `WORKLOADS`, and each threshold into
both `DECISION_RULES` tables.

The evidence is `F5`, and it is the two-stage protocol the corpus requires, not
a screen: 12 quartets per arm at 50,000 trials on seed 20260730 selected the
cells, then those exact cells were re-run at 100,000 trials on seed base
20260828 -- disjoint seeds, no parameter changed after screening -- at tree
`83badba2973b`. Every arm was confirmed on its own series and never pooled, so
no arm rides on another's evidence. A/A false positives are 0.0000 in all eight
cells. Detection is the binding gate, at 0.915 against the 0.90 floor on the two
Unicode arms; that is what sets the thresholds, and it is why none of them can
be tightened by asking for it.

This is the step a script must not take, which is the whole reason Phase 2 task 2
sat open: `terminal-benchmark-candidate-screen.py` writes a report and never a
rule. The act here is a human reading `F5` and accepting it.

Runtime, checked rather than assumed. `research/7/D4` budgets the complete
`confirm` suite at under five minutes including cached build and harness
overhead, and nothing in the scripts enforces that number -- it lives in `D4`
and in
[agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md).
`D4` froze it against an 86.72-second projection for the 20-pair suite; the
suite now carries 24 pairs plus these 8. `F5`'s screens took 2.6-5.3 minutes for
12 quartets of one arm, so 1 quartet of each of four arms is 52-106 seconds of
added collection. The suite stays under the budget, with less headroom than
before. Anything that adds another workload should re-check it against a
measured confirm run rather than this projection.

Rejected alternative: leave them as candidates and read Phase 3 descriptively.
That is what `F5` was collected to end. A fix measured on an arm that cannot
decide is an anecdote, and the funnel in this doc says a fix ships on a ladder
verdict.

Not decided here: whether the arms belong in the A/A control table in
[agent-docs/terminal-performance.md](../../../agent-docs/terminal-performance.md).
That table reports between-invocation noise from whole `confirm` runs, which
these arms have never been through. The doc says so instead of guessing.
