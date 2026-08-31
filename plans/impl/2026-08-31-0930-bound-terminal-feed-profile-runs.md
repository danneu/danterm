# Plan: a `--profile` run that cannot outlive its window

## Context

Commit 2 of `plans/impl/2026-08-29-1635-wide-runs-and-rep-memory.md` profiled two
benchmark arms and left both `TerminalCoreBenchmark --profile` processes running.
They were found 33 minutes later at `PPID 1`, each pinning a core, long after the
sampling that needed them had finished and been written up.

Nothing was wrong with the numbers. The problem is structural:

- `TerminalCoreBenchmark/main.swift:65-70` runs `--profile` through
  `runSustainedFeed` with no `maximumCycles`, so
  `TerminalCoreBenchmarkSupport.swift:128-138` is a `while true` loop with **no
  exit condition of any kind**. It runs until something else kills it.
- The child cannot notice it has been abandoned: `stdin` is a regular file (no
  EOF, no `SIGHUP`), `stdout` is `DEVNULL` (no `SIGPIPE`), and the loop reads no
  clock.
- So *every* spawner must reap it, and every spawner is one `SIGKILL` away from
  not doing so. `scripts/terminal-feed-profile.py:145-147` reaps from an
  in-process `try/finally` -- which a hard abort of the driver defeats -- and the
  path that actually leaked, research 39's hand-rolled `<arm-binary> --profile` +
  `sample <pid>` recipe, has no reaper at all and is written down nowhere.

The repo already knows this failure mode. `scripts/tests/test-terminal-pty-cleanup_test.sh:1-11`
records sixteen strays up to five days old, "all with pid 1 for a parent", and
`scripts/run-with-deadline.py` exists to answer it for the test lanes. None of
that machinery is wired into the profiling path.

**Outcome:** a `--profile` run has a finite lifetime that it enforces itself, so
no spawner -- scripted, manual, or improvised -- can strand one.

## Contract

1. `--profile` takes a required duration: a positive, representable number of
   seconds, with no default and no unbounded form. No cycle starts at or after
   the deadline, and the process exits `0` once the cycle already in flight
   finishes -- the loop does not interrupt a feed mid-cycle, because that would
   corrupt the boundary the profile exists to measure.
2. A `--profile` run never waits indefinitely to acquire its fixture. In that
   mode standard input must be a regular file, which always reaches EOF;
   anything else -- a terminal, a FIFO, a pipe -- is rejected before any work
   starts. Together with (1) this makes the whole profile process finite, not
   just its loop.
3. `runSustainedFeed` has no unbounded form. Every caller supplies the condition
   under which the loop continues, so a never-terminating profile run cannot be
   written by accident either.
4. `scripts/terminal-feed-profile.py` derives the child's duration from the work
   it is about to do (warmup + `--seconds` + margin), so the bound is tight
   without the operator naming it. It still reaps promptly on the normal path and
   on error, escalating `SIGTERM` -> bounded wait -> `SIGKILL` rather than
   blocking forever. That is timeliness; (1) and (2) are the guarantee.
5. The entire cleanup path is error-preserving: a failure while tearing down --
   the kill, the wait, or the fixture unlink -- never replaces the error that
   caused the teardown.
6. `agent-docs/terminal-performance.md` states the guarantee and carries the
   manual per-arm recipe with its duration, so the path that leaked is written
   down instead of being reinvented per research task.

## Changes

### `lib/TerminalCore/Sources/TerminalCoreBenchmarkSupport/TerminalCoreBenchmarkSupport.swift`

Replace `runSustainedFeed(maximumCycles:feedCycle:)` with a form that takes an
explicit continuation predicate, evaluated once per cycle, plus the injectable
`now:` clock this file already uses at `:104`
(`DispatchTime.now().uptimeNanoseconds`). The `Int?` overload and its `?? true`
default -- the thing that makes "forever" the default -- go away.

The deadline is checked between cycles, so the real bound is the duration plus at
most one cycle (~167 ms on the `unicode` arm). That is the honest guarantee and
what the test asserts.

Reusing the existing `now:` seam keeps the whole thing unit-testable with a fake
clock -- no sleeping, no forking, no platform process API. See `RI1`.

### `lib/TerminalCore/Sources/TerminalCoreBenchmark/main.swift`

`--profile` gains a required seconds argument and passes the deadline. The parse
admits only a positive value that converts to a nanosecond deadline without
trapping; missing, zero, negative, non-numeric, and too-large values all take the
existing `fail()` path. Usage text (`:13-18`) changes to `--profile <seconds>`.

In the `--profile` branch only, require standard input to be a regular file and
`fail()` otherwise. The check cannot go on the shared read at `:64`: the
measurement modes are fed through a pipe by
`scripts/terminal-benchmark-validation.py:986` and
`scripts/tests/kitten_feed_ladder_test.py:119` (`subprocess.run(input=...)`), so a
universal regular-file check would break the ladder and the benchmark gate.
Profile mode has no such caller -- the driver redirects a regular file and the
manual recipe uses `< fixture.bin` -- so nothing changes for existing callers.

Both `--profile` checks must run *before* the stdin read, not after it. Today the
read at `:64` happens first and the mode branch at `:65` second, so a guard left
in place would block on the very input it is meant to reject.

### `scripts/terminal-feed-profile.py`

Pass the derived duration to the child. Rewrite the teardown at `:145-147` to the
pattern the repo already uses in `scripts/terminal_btop_workload.py:384-401` and
`scripts/terminal-benchmark.sh:6-14`: `terminate()`, bounded `wait(timeout=...)`,
then `kill()` and wait again -- with the whole block written so no cleanup
failure escapes to mask the original error.

### Tests

| Test | Pins |
|---|---|
| `TerminalCoreBenchmarkSupportTests.swift` (extend, ~`:169`) | `runSustainedFeed` stops after the predicate first reads false, and returns the completed count. Replaces the current `maximumCycles: 3` case, which tests an API that no longer exists. |
| `TerminalCoreBenchmarkSupportTests.swift` (new) | With a fake clock, the loop runs while the deadline is ahead and stops on the first cycle boundary at or after it -- including a deadline already passed at entry, which must run zero cycles. |
| `scripts/tests/terminal_feed_profile_orphan_test.sh` (new) | **The contract, at the executable.** (a) Start `--profile <short>` from a throwaway parent, `kill -9` that parent, and assert the harness is gone within a deadline comfortably above the declared window. (b) With stdin on a pipe whose writer stays open, the harness exits non-zero promptly instead of waiting for EOF. (c) A missing, zero, negative, non-numeric, or too-large duration exits non-zero without feeding anything. Model on `scripts/tests/test-terminal-pty-cleanup_test.sh` -- private sandbox path, `pgrep -f` anchored to it, `wait_until` polling, best-effort `cleanup` trap -- and read `agent-docs/test-timing.md` before choosing the deadline. |
| `scripts/tests/terminal_feed_profile_test.py` (new) | The driver escalates to `kill` when a stub child ignores `SIGTERM`; and a cleanup failure raised while a sampling exception is already in flight leaves the sampling error as the one that surfaces. The script has **no test at all** today, and `scripts/gate-test-coverage-lint.py` does not require one, so this must be added by hand. |

Register both new script tests in `scripts/run-test-suite.sh`'s tooling list
(near `:243` and `:284`).

### `agent-docs/terminal-performance.md`

In the profiler section (~`:579-581`, beside the `just benchmark-feed-sample`
paragraph): state that a `--profile` harness runs for a declared window and then
exits on its own, and give the manual per-arm recipe -- build the arm, run
`--profile <seconds>` against the fixture, `sample <pid>` -- with the duration set
above the sampling window. Contrast it with the `benchmark-loop` note at
`:589-592`, which already tells the reader how that mode stops.

## Rejected ideas

- **RI1 -- Exit when the parent dies (`getppid()` watch), instead of a duration.**
  Cannot deliver the guarantee, and does not cover the case it was chosen for.
  (a) The child cannot reliably learn its original parent: if the spawner is
  `SIGKILL`ed before the child's first `getppid()`, the child captures its reaper
  as the owner and never exits. `main.swift:64` reads the entire fixture from
  stdin *before* reaching the `--profile` branch, so the race window is the whole
  fixture read, not a few instructions. (b) In the manual recipe the interactive
  shell stays alive as the parent after `sample` returns, so the predicate never
  fires and the harness pins a core exactly as observed.
  Once a duration is required the check is also not worth keeping as a promptness
  optimization: the driver's bound is already warmup + sample + margin, so the
  check would save only the margin, at the cost of a startup race, a captured
  owner, a per-cycle syscall, and a platform process API in an iOS-pinned package
  (`lib/TerminalCore/Package.swift:6`).

## Non-goals / accepted risks

- **AR1 -- The measurement modes keep an unguarded stdin read.** `--fixed` and
  the default mode still block forever if handed a terminal or an open pipe.
  They must accept a pipe (see the two callers above), they are only ever invoked
  by scripts, a blocked read costs no CPU, and no such stray has been observed --
  so guarding them would cost the ladder its input shape to fix nothing.

## Verification

1. `swift test --package-path lib/TerminalCore --filter TerminalCoreBenchmarkSupport`
2. `just test-tooling` -- picks up both new script tests.
3. `just test-portability` -- `TerminalCoreBenchmarkSupport` is in an iOS-pinned
   package (`Package.swift:6`), and this change edits it.
4. `just lint`
5. **Reproduce the original leak and confirm it is gone.** Start
   `TerminalCoreBenchmark --profile 10` under a parent, `kill -9` the parent, and
   confirm with `ps -Ao pid,ppid,etime,command | grep TerminalCoreBenchmark` that
   nothing survives past the window. Before the change the same steps leave one
   at `PPID 1` indefinitely.
6. `just benchmark-feed-sample unicode-wrapping seconds=10` still produces a readable
   `sample.txt` under `.build/terminal-feed-profiles/<run>/`, and leaves no
   process behind.
7. `just test` before the commit.

No benchmark gate applies: nothing here is on a measured path. The deadline check
sits in the profiling loop only, which no ladder arm runs.

## Notes

- Single commit's worth of work; slice it only if the doc change is split off.
- The plan file's slug is auto-generated and meaningless -- rename it on promote.

## Commit progress

- [x] 1. fix(benchmark): bound profile runs to their declared window
