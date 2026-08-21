# Wall-clock values in tests

Read this before you write any deadline, timeout, poll interval, or sleep into a
test. The general test rules -- TDD, assert observable behavior -- are in
`AGENTS.md`; this file covers only durations.

**Every wall-clock value in a test is a hang guard.** `just test` runs the gate
as an oversubscribed, deprioritized pool, so any deadline a passing run could
approach is a race the gate will eventually lose. Size a guard so a passing run
cannot come near it -- 30 seconds under a `.timeLimit(.minutes(1))` backstop is
the house pair -- and keep it strictly below that backstop so the failure names
the waiter rather than the whole test. A `.timeLimit` alone is not enough: it
reports a failure but cannot unwind a blocking syscall, so an in-test guard is
still required.

Two rules follow:

- **An expiry says it was an expiry.** Throw `POSIXError(.ETIMEDOUT)`. Never
  reuse an error whose meaning is that data was malformed or a read failed, and
  never return a bare `false` or `nil` into an expectation -- that cannot say
  whether the awaited thing failed to happen or the test merely stopped waiting.
  The one exception is a guard whose expiry *is* the outcome the caller rules
  out, such as polling for a socket teardown: there "the deadline passed" and
  "it never happened" are one observation, and a bool states it honestly.
- **No test passes or fails on whether production was fast enough.** An elapsed
  duration is never an acceptance threshold. Two uses stay legitimate: a
  generous bound that only proves an operation terminates, and an assertion
  about a duration production itself defines, such as a debounce interval.

A duration a test needs to expire -- a probe that learns something by *not*
getting an answer -- is a different thing from a guard. Supply it explicitly at
the call site, keep it far below the guard, and say in a comment that it is
meant to fire.
