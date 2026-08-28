# CLI-1: the TCP connect honours the caller's whole deadline

Source: `docs/scratch/2026-08-26-improvement-audit.md#cli-1` (Wave 11).

## 1. Problem

`TCPSocketTransport.init` (`lib/DanTermClient/Sources/DanTermClient/TCPSocketTransport.swift`)
takes a `connectTimeout`, derives a deadline from it, and then hands each
per-address connect `min(remaining, 1)`. The documented target form is an IPv4
literal, which resolves (`AI_NUMERICHOST`) to one address, so the whole connect
budget is one second no matter what the caller passed.

Two callers are hurt:

- `ios/.../MobileSession.swift` passes 5 and gets 1 on every reconnect attempt.
  A link whose handshake needs more than a second never connects.
- `cli/main.swift` passes `DANTERM_SOCKET_TIMEOUT` (default 5), which
  `integrations/danterm/SKILL.md` documents as the wait the CLI honours. The
  prose contract and the code disagree.

Evidence: the literal arrived whole in `6a8cbc3e` with no rationale; no later
commit touched it; no test observes the connect budget (existing
`TCPSocketTransportTests` only cover successful connects).

## 2. Decision

Delete the cap. The per-address wait is the time left on the one deadline the
caller supplied; the existing `remaining > 0` guard is what ends the loop. There
is one clock and one place that reads it.

Behavioral scope: the connect phase of `TCPSocketTransport` only. No CLI
surface, flag, or SKILL.md change -- SKILL.md already states the contract the
code now meets.

## 3. Invariants

- I1. `TCPSocketTransport` does not throw `connectTimedOut` before
  `connectTimeout` has elapsed while an unexhausted address is still being
  tried.
- I2. The deadline is shared across addresses: total connect time never exceeds
  `connectTimeout` by more than one poll granularity.

## 4. Proof obligations

- PO1 (I1). In `lib/DanTermClient` tests, without any network dependency: a
  loopback listener whose accept queue is full (small backlog, unaccepted
  pending clients) makes further connects hang, since the kernel drops the SYN
  rather than refusing it. Connect to it with `connectTimeout: 3`; the transport
  throws `connectTimedOut` and the elapsed time is at least 3 s. Lower bound
  only, on a duration production defines (`agent-docs/test-timing.md`); it
  never skips. Red today at ~1 s.
- PO2 (I2). Not proven by a test; see AR2.

## 5. Non-goals / Accepted risks / Rejected ideas

- Non-goal: per-address fast-fail for multi-address hostnames. If wanted later
  it is a declared transport parameter, not a literal in the loop.
- AR1. A hostname whose first address black-holes now spends the whole budget
  on it before trying the next. That is the meaning of "the caller's deadline";
  the documented literal-IP target is unaffected.
- AR2. I2 (one deadline shared across addresses) has no behavioral test. The
  only wall-clock proof is an upper bound that distinguishes ~T from ~2T, which
  `agent-docs/test-timing.md` forbids as an acceptance threshold, and a clock +
  poll seam through the transport is more mechanism than the one-token fix it
  would guard. I2 is held by the diff (`timeout: remaining`) and the existing
  `remaining > 0` guard, checked at implementation review.
- RI1. Name the constant (`perAddressConnectBudget`) instead of removing it --
  keeps the defect, only makes it findable.

## 6. Verification

- `swift test --package-path lib/DanTermClient --filter TCPSocketTransportTests`
  red then green.
- `just lint`, then `just test` before commit.
- Manual (needs a route): `DANTERM_SOCKET_TIMEOUT=10 danterm --tcp
  192.0.2.1:24863 ls` fails after ~10 s, not ~1 s.

## Commit progress

- [x] 1. fix(client): honor the full TCP connect deadline
- [ ] 2. docs(audit): mark CLI-1 complete
