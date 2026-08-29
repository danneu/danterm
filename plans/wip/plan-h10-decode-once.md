# Decode each scalar once: the stream is the only decoder, and the printer stamps what it decoded

Research: [docs/research/39-kitten-render-benchmark](../../docs/research/39-kitten-render-benchmark/README.md)
(`F14`, `F16`, `D9`).

## 1. Problem

A run of non-ASCII scalars is decoded twice and its bytes are traversed three
times. The stream's probe decodes every byte through the resumable
state-machine decoder to classify each scalar and find the run's end, then
returns only the byte range and the width. The printer scans the bytes again
to count scalars for a segment, then decodes them a second time with a fresh
decoder inside the writer's supplier. A single scalar that is not
bulk-printable is classified in the stream and again in the single-scalar
print. Evidence (`D9`, headless `unicode` feed at HEAD): the printer's second
decode is about a fifth of the thread, the probe's per-byte decode about a
sixth, the re-scan 6%, the two classifications about 10%. Two prototypes read
`kitten-feed-unicode: faster (-35.63%)` with the re-scan and the printer's
state-machine decode gone, and `faster (-65.28%)` with the probe also decoding
each complete sequence in one step, with `kitten-feed-unique-unicode: faster
(-7.34%)`, `ascii` inconclusive (-1.25%) and `csi` equivalent (`D9`).

Load-bearing premises about existing behavior:

- Feeding is chunk-invariant: the same bytes fed in any chunking produce the
  same scalars, actions and grid, with a sequence split across chunks
  completed from the pending prefix (`TerminalInputStreamTests`,
  `TerminalStateSynchronizationTests`).
- Malformed UTF-8 is replaced by U+FFFD per maximal subpart, and the byte that
  proves a sequence malformed is re-offered as its own input; an encoded
  U+FFFD is an ordinary scalar (`TerminalInputStreamTests`).
- C1 control scalars (U+0080-U+009F) decoded from UTF-8 are consumed with no
  action; a scalar run never contains ASCII, an ignored scalar, a scalar that
  is not bulk-printable, or two widths (`TerminalInputStreamTests`).
- A run fed as one action leaves the grid, cursor, wrap latch, damage,
  inspection state, cluster context and REP memory equal to feeding it one
  scalar at a time, and a joiner after a run joins only its last cell
  (`TerminalBulkRunTests`).
- The synchronization stream restores the decoder's pending prefix and the
  terminal continues the sequence from it (`TerminalStateSynchronizationTests`).

Desired outcome: each scalar's bytes are decoded once and its classification
read once, both in the stream; the printer never turns bytes into scalars;
every observable result is unchanged; `kitten-feed-unicode` and
`kitten-feed-unique-unicode` read `faster`.

## 2. Decision

**The stream is the only decoder, and it decodes each scalar exactly once.**
The probe decodes a complete well-formed UTF-8 sequence in one step and defers
to the resumable decoder only where the bytes at hand are not one -- the chunk
tail, or an invalid sequence -- so the resumable decoder's replacement and
resumption behavior is untouched and a deferral is only the slow path for the
same answer. The run action carries its scalar count beside its width. The
scalars the probe decoded reach the printer through a scratch that lives for
one feed call and is bounded by a fixed cap on the run's scalar count; the
printer stamps from the scratch and reads no run bytes. A single-scalar print
action carries the classification the stream read, and the single-scalar
print uses it instead of looking it up again.

This is `D9`'s ideal. `D9` records the cheap shape it measured -- the printer
keeps decoding, statelessly, by lead-byte length -- and the plan lands it as
the first commit on the way, gated on its own; the scratch is the last commit
and is kept only if the ladder says it is faster than the cheap shape.

## 3. Invariants

- **I1** Decode equivalence: for every byte sequence, in every chunking, the
  stream yields the same scalars in the same order as the resumable decoder
  alone would -- every well-formed 2-, 3- and 4-byte sequence, every overlong
  form, every surrogate encoding, every value above U+10FFFF, every truncated
  sequence including one cut at a chunk boundary, a continuation byte with
  no lead, and an encoded U+FFFD -- with the same replacement scalars and the
  same re-offered bytes.
- **I2** Token equivalence: expanding every run action to one print per
  decoded scalar yields the same token stream as before for any input,
  including runs ending at an ignored scalar, at a joiner, at a width change,
  at ASCII, at an escape, and at the chunk end; the run's scalar count equals
  the number of scalars its range decodes to.
- **I3** Grid equivalence: feeding any byte sequence, in any chunking, leaves
  the grid, cursor, wrap latch, soft-wrap flags, margin provenance, content
  identities, cluster context, REP memory, drained damage and inspection state
  equal to feeding it one scalar at a time -- for narrow runs, wide runs, mixed
  narrow and wide, runs longer than a row and longer than the run cap, runs
  across the right margin with DECAWM on and off, in insert mode, with a wrap
  latched at entry, and with a joiner after the run.
- **I4** Synchronization round trip: a terminal restored from a
  synchronization stream mid-sequence continues the sequence to the same
  scalar as the terminal that fed it whole, and its encoder reads the same
  pending prefix.
- **I5** A single-scalar print of a scalar the stream classified places the
  same cell, width and cluster join as it does today for a joiner, a
  zero-width scalar, an emoji with and without a variation selector, and a
  scalar reached through the generic path (after an escape, after a chunk
  tail), and REP and the synchronization stream, which print scalars the
  stream never saw, place the same cells as today.
- **I6** Cost: the printer performs no decode of a run's bytes; the resumable
  decoder runs inside the run probe on no byte of a complete well-formed
  sequence; a scalar's classification is read once per scalar on the feed
  path; and no allocation is made per run action or per feed call beyond a
  bounded scratch.

## 4. Proof obligations

Behavioral and structure-insensitive; a refactor that keeps the behavior
keeps these passing.

- **PO1 (I1)** Every 1-, 2- and 3-byte sequence exhaustively, and every 4-byte
  sequence over the boundary values of each byte position, decoded by the
  stream and by the resumable decoder alone, in one chunk and split at every
  byte offset, yield identical scalar sequences and consume identical byte
  counts. The existing malformed-sequence and encoded-U+FFFD cases stay
  green.
- **PO2 (I2)** The existing token-stream expectations stay green with the
  count added, and expanded token streams match for the run-ending cases I2
  names; a run longer than the cap expands to the same prints as one shorter.
- **PO3 (I3)** The whole-terminal equivalence between a fed run and the
  scalar-at-a-time feed, over the cases I3 names, including drained damage
  and inspection state. The existing narrow, wide and mixed cases stay green.
- **PO4 (I4)** A synchronization round trip taken mid-sequence and mid-run
  reproduces the pending prefix and completes the sequence identically.
- **PO5 (I5)** The single-scalar cases I5 names match the scalar-at-a-time
  feed, and the existing REP and synchronization suites stay green.
- **PO6 (I6)** No shipped surface counts decodes, classifications or
  allocations, and a sampling profile cannot prove an absence, so I6 is not
  proved by measurement. It is carried by structure -- the printer holds no
  decoder and no classifier once it stamps from the scratch, so it cannot
  decode or classify -- and by the benchmark ladder, which is what a lost
  decode would move. The frame-presence reading in the benchmark gate is
  cost attribution and corroboration: it says where the remaining time is
  and shows the frames the change was meant to remove are gone from the
  sample, not that they never run (`AR4`).

## 5. Benchmark gate

Frozen rules from `research/39/D2`; conditions from
[agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md).
Note the pre-change revision before starting. Each commit is gated on its own
pre-change revision.

1. `just benchmark-quick baseline=<pre-change> workload=kitten-feed-<arm>` on
   all four arms after each commit: `unicode` (+/-1.80%) must read `faster`
   for the first two commits, `unique-unicode` (+/-1.60%) for the second; no
   arm may read `slower`. The last commit, the scratch, is kept only if
   `unicode` reads `faster` against the commit before it; an `equivalent`
   there is recorded in the research doc and the cheap shape stands. A
   direction on an arm a commit cannot reach (`ascii` +/-1.70%, `csi`
   +/-1.45%) is read against `F7`'s change-free control. A miss is recorded,
   not hidden.
2. `just benchmark-confirm baseline=<pre-change>` before any performance
   claim is recorded anywhere durable; `content-churn` and `retained-browse`
   are read against `F7`'s control, per `D4`.
3. Corroboration of `H10`, after the ladder verdict, read by **which frames
   are present** against a pre-change sample of the same stimulus (an empty
   subtree is "not measured", not "measured zero"): on the headless `unicode`
   feed, no decoder frame under the printer's writers, the resumable decoder
   under the probe only on the generic path, and no second classification
   frame per scalar; subtree sample counts recorded on both trees. Read as
   evidence about where the time went, not as a count (`PO6`, `AR4`). The
   external confirmation is the kitten `unicode` and `unique_unicode` figures
   moving, taken frontmost at 179x66 with the other arms beside them and read
   against `F16`'s delivery term.
4. Final acceptance, once the last kept commit is in: the whole change read
   against the pre-change revision noted at the start, not against the commit
   before it. `kitten-feed-unicode` and `kitten-feed-unique-unicode` must both
   read `faster` there and no arm may read `slower`. Per-commit verdicts do
   not compose -- two `equivalent` readings inside their bands can cancel a
   gain the ladder already banked -- so this is the reading that decides
   whether the desired outcome was met. If an arm misses, the miss is recorded
   as the outcome and the last commit is reconsidered against it.
5. Record the decision-bearing values -- mode, workload, both tree
   identities, the median symmetric estimate, the classification -- in each
   commit, and add the outcome to
   `docs/research/39-kitten-render-benchmark/findings.md` as a finding.

`just test`, `just lint`, and the `TerminalCore` suite before each commit.

## 6. Non-goals

- `H6`'s blank fill, which lands as its own task after this one (`D9`).
- The delivery path: the `read` handoff and the per-turn copy that `F16`
  sizes at 12-16% of the `unicode` feed thread.
- Any change to what a scalar run may contain, to where a run is cut, or to
  the bulk writers' cut rules.
- A faster resumable decoder. It survives only for the chunk tail and invalid
  sequences, which no arm exercises.

## 7. Accepted risks

- **AR1** Two decoders must accept exactly the same set. Accepted because PO1
  is exhaustive through three bytes and structural at four, and a mismatch
  is a different scalar, which PO1 fails on.
- **AR2** A supplier or scratch reference that is stored rather than passed
  boxes its state and puts a dynamic exclusivity check on every read; `D8`'s
  first cut lost 58 points of its gain to exactly that. Accepted because the
  benchmark gate reads it directly.
- **AR3** The run cap splits a run into several actions, and a direct
  `TerminalCore` caller can ask for a grid wider than the cap:
  `Terminal.acceptsGeometry` bounds columns only from below, and the 1024
  limit is the app's pane-grid override (`DanTermProtocol`), not the
  engine's. So in the app no row segment is ever split by the cap, but a
  wider direct geometry can split one and pay an extra action and its
  bookkeeping. Accepted because the split changes cost, not results, and I3's
  over-cap run and PO2's over-cap expansion already pin the equivalence for
  any run longer than the cap.

- **AR4** I6 is not provable by the instruments this repo has: a sampling
  profile cannot distinguish "never ran" from "never sampled", nor count
  allocations. Accepted because I6 is carried by structure and by the ladder
  (`PO6`), and an exact counting instrument is mechanism built for a cost
  invariant no observable behavior depends on.

## 8. Rejected ideas

- A heap array of decoded scalars per action: `research/33/F9` sized the one
  it replaced at 60-80x the corpus; the feed-scoped bounded scratch is the
  form that escapes it.
- A lazily-decoded cursor the printer drives, with the stream finding the run
  boundary by byte pattern alone: the boundary depends on the classification,
  which needs the decoded value, so the stream decodes anyway, and it would
  move the token boundary into the printer.
- Caching classifications across scalars: flatters a repeated corpus and no
  real stimulus.

## 9. Implementation discretion

- Whether the run action keeps its byte range beside the count once the
  scratch carries the scalars, and how the scratch is passed to the stream
  and the printer, provided nothing is allocated per action.
- Where the one-step decoder lives and how it is shared with the printer's
  interim stateless decode in the first commit.

## Commit progress

- [ ] 1. perf(terminal): carry the scalar count in the run action and decode the run statelessly in the printer
- [ ] 2. perf(terminal): decode each complete well-formed sequence in one step in the stream probe; carry the classification in the single-scalar action
- [ ] 3. perf(terminal): stamp a scalar run from the scratch the stream decoded into, so the printer reads no bytes -- kept only on a `faster` verdict against commit 2
