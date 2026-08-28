# PTY-7: the canonical gate's verdict belongs to the submission

Source: `docs/scratch/2026-08-26-improvement-audit.md`, finding PTY-7 (Wave 8,
"Attach the PTY host's obligations to values"). Tick its `## Plan of work` box
when this lands.

## Problem

`TerminalPTYHost.flushInput` calls `prepareCurrentInputRecordForWrite` on every
loop iteration (`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`,
~1914-1984). When the child is canonical, that function runs
`CanonicalInputDeliveryGate.isOversized` over the whole remaining tail of the
head submission. `isOversized` returns early only on a 1024-byte run, so a
paste of ordinary lines walks the entire tail each time.

Evidence that the tail is walked many times per submission: xnu's `ptcwrite`
(`references/xnu/bsd/kern/tty_dev.c:919-922`) stops accepting master-side bytes
once the canonical input queues hold `TTYHOG - 2` (1022) bytes with a completed
line queued, returning the partial count under `O_NONBLOCK`. So a canonical
reader takes about 1 KiB per `flushInput` turn, and a multi-megabyte paste
costs thousands of turns, each rescanning the remaining tail -- quadratic byte
work on the owner queue that the render fence and every actor call wait behind.

This bound is derived from source. **No number has been measured.** Per
`agent-docs/measurement-discipline.md`, the magnitude is a claim until the
instrument below records it, and the change is not accepted on the argument
alone.

## Decision

Attach the gate's verdict to the value it describes. The head submission
carries one cached verdict for the input-flag set it was computed under; the
host reuses it while the same submission is head, the observed flags are
unchanged, and every reading in between saw canonical mode. It discards the
verdict the moment any of those change -- a raw-mode reading ends the epoch
because bytes may cross in raw mode and shorten the head. The tty mode is still
read with `tcgetattr` immediately before each write attempt: the child is a
separate process and can change modes between two write attempts of one turn,
so a turn-wide mode snapshot would let an oversized run reach a canonical
queue after a partial write and lose bytes (`references/xnu/bsd/kern/tty.c`,
`MAX_INPUT` discard).

Soundness of caching: `isDelimiter` is per byte and the scan resets on each
delimiter, so no run in a suffix can exceed the run it was cut from. Under
unchanged flags, a head that was not oversized never becomes oversized, and an
oversized head stays oversized until the child leaves canonical mode or the
flags change.

Behavioral scope: only the cost of the write path changes. Delivery order,
completion results, the canonical hold and its timeout, and the flight tape's
record of what crossed are unchanged.

## Invariants

- I1. Within one contiguous epoch -- same head submission, same observed
  `c_iflag`, every reading canonical -- the canonical scan runs at most once,
  regardless of how many write turns or retry firings the epoch spans. A change
  to the observed flags (including A -> B -> A) or a noncanonical reading
  starts a new epoch.
- I2. No tty-mode reading is reused across write attempts: each attempt reads
  the mode fresh, and any change the child completed before that reading
  governs the attempt.
- I3. Existing gate behavior holds: an oversized head is held, times out with
  `.canonicalModeTimeout`, and never wedges the submission behind it.

## Proof obligations

- PO1 (the measurement; blocks the change). A host test sends a multi-megabyte
  submission of 80-column lines into a child that stays canonical and drains
  lines until the paste ends, and waits for `.delivered`. The instrument
  reports, beside elapsed time, the number of canonical scans and the bytes
  they examined, and the number of write turns. Record baseline and fixed
  runs taken in the same session in the commit message. Elapsed time is
  informational, never an acceptance threshold (`agent-docs/test-timing.md`);
  the scan count and bytes examined are what the test asserts.
- PO2 (I1). Reintroducing the per-turn rescan must turn PO1 red on the scan
  metrics.
- PO3 (I1, epochs). A canonical child changes `c_iflag` while holding the
  head: the verdict follows the new flags; changing them back re-evaluates the
  now-shorter head rather than reusing the old verdict.
- PO4 (I1, I2; transitions coordinated between attempts). A canonical child
  holding an oversized submission switches to raw mode: the submission is
  delivered on the next attempt. A raw child switches to canonical after a
  partial write: the remaining oversized suffix is held, not reported
  delivered. A canonical child holding an oversized head goes raw, takes part
  of it, and returns to canonical with the same `c_iflag`: the shorter head is
  re-evaluated, not held on the stale verdict.
- PO5 (I3). The existing `oversizedCanonicalInputTimesOutWithoutWedge` and the
  `canonical-inlcr` / `canonical-igncr` tests keep passing unchanged.

## Non-goals / Rejected ideas

- Non-goal: changing the 64 KiB write turn limit or the read turn constant.
- RI1. Reading `termios` once per `flushInput` turn (the audit's ideal). The
  child runs concurrently with the turn, so a stale snapshot after a partial
  write is a data-loss window; the ioctl beside each `write` is cheap and is
  the guard.
- RI2. Hoisting only `tcgetattr` (the audit's cheaper fallback). It leaves the
  half that scales and has the same defect as RI1.

## Implementation discretion

- Where the verdict lives (a field on the record vs. a side value keyed by the
  head), how the scan metrics are exposed to the test, and how the drain-lines
  and mode-switching children are provided (new `PTYProbe` modes are the
  obvious shape; no existing mode reads more than one line).

## Verification

1. Write PO1 first against the current tree and record the baseline.
2. `swift test --package-path lib/TerminalPTY --filter TerminalPTYHostTests`
   plus `just lint` in the loop; `just test` before the commit.
3. Re-run PO1 after the change; put both runs' numbers in the commit.
4. Tick PTY-7 in the audit's `## Plan of work`.
