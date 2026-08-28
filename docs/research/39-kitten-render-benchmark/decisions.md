# Decisions

## D1 -- Fixture source for the kitten byte streams

DECIDED 2026-08-28: port the generator, do not record.

The generator is `tools/cmd/benchmark/main.go` in the kitty checkout. It was
outside the sparse cone, but the pinned commit's objects were already local,
so `just fetch-references kitty` now includes `tools/cmd/benchmark` and
`tools/tty` (the writer whose behavior `F3` cites).

What the generator does, per arm, before the `\x1b[m\x1b[H\x1b[2J` +
`Running: ...\r\n` reset that follows every repetition:

- `ascii`: 2,097,165 bytes drawn uniformly from 94 printable ASCII characters
  plus `\n` and `\t`, using an unseeded `math/rand/v2`.
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
`tools/cmd/benchmark/main.go` still matches the constants the port encodes.
`just test-tooling` can assert the string constants against the reference
file once the port exists; that is the Phase 2 headless task's job.
