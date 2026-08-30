# Stop copying the whole `Terminal` to read its own state on the feed path

Research: [docs/research/39-kitten-render-benchmark](../../docs/research/39-kitten-render-benchmark/README.md)
(`F2`, `F6`, `D5`).

## 1. Problem

Every parser action copies the whole `Terminal` value once, and every printed
cell copies it again. `apply` closes each action by taking the damage snapshot,
the snapshot reads the public `scrollProjection` getter, and the compiler
materializes a 1513-byte copy of `self` to call that getter from inside a
mutating method. `recoverClusterContextFromGridIfNeeded` pays the same copy per
print to call `gridClusterPredecessor`. The release object holds 58 sites of this
shape; these two are the unconditional ones on the feed path.

Evidence (`F2`, `F6`, and the probe recorded in `D5`): `memcpy` of 1513 bytes at
`apply+392`; `_platform_memmove` is 13.9% of the `ascii` PTY thread and 18.4%
of `unicode`, and 94% of those samples sit under the two sites. A screen with
both sites removed read `kitten-feed-ascii` `faster` at -17.11% and
`kitten-feed-unicode` `faster` at -18.11%.

Load-bearing premises about existing behavior:

- `Terminal` is a value type with compiler-checked `Sendable`; the PTY host
  publishes fence-copied values across threads and tests compare whole terminals
  with `==`. Nothing here may weaken that.
- The scroll projection is a pure function of five cheap inputs (alternate-screen
  state, row count, history row count, viewport state, evicted row count), and
  the cluster predecessor is a pure function of the live screen plus the column
  count (`columnCount` is terminal-stored, not part of `ScreenState`).

Desired outcome: no function on the feed path copies a `Terminal`-sized value,
every observable result is unchanged, and a copy that comes back fails a gate.

## 2. Decision

The projection is derived by **one function of its inputs**, and both the public
getter and the damage snapshot call it; the projection is never computed twice
and never read through a member call on `inout self`. The cluster predecessor is
resolved **on the screen sub-value**, or read inline, so the value it is called on
is never the terminal.

A **tooling gate** builds the release `TerminalCore` object, takes
`MemoryLayout<Terminal>.size` from the built product, and fails when a whole-value
copy of a terminal appears anywhere in the union of the transitive call graphs rooted
at every public `feed` overload -- not in a fixed list of named functions, so a
copy that moves into a newly extracted helper is still caught. It fits in
`just test-tooling`.

The ideal -- a pointer-wide `Terminal` over one copy-on-write storage box, in
which the copy is impossible everywhere -- is recorded in `D5` with what it costs
(`@unchecked Sendable`, hand-kept uniqueness at 26 public mutating entries, a
whole-file rewrite). It is not built here; the gate is what stands in for it, and
`D5` names the condition under which the box becomes the fix.

## 3. Invariants

- **I1** No function on the feed path copies a whole terminal in the release
  build -- a `memcpy` or a `memmove` whose length is `MemoryLayout<Terminal>.size`
  or `MemoryLayout<Terminal>.stride`, because the lowering of a whole-value copy
  varies by both. The feed path is the
  union of the transitive closures of calls reachable from every public `feed`
  overload in the release object -- both the `[UInt8]` and the
  `UnsafeBufferPointer<UInt8>` entry -- not an enumerated set of names, so
  extracting a helper cannot move a copy out of scope.
- **I2** `scrollProjection` returns the same value as before the change for every
  screen, viewport state, history depth, and eviction count, and the damage
  snapshot reads the identical projection.
- **I3** Cluster-context recovery resolves the same predecessor cell as before for
  every cursor position, pending-wrap state, and wide-tail arrangement.
- **I4** The damage published per action, the grapheme-cluster assembly across a
  feed boundary, and grid content after any feed are unchanged.
- **I5** `Terminal` keeps compiler-checked `Sendable` and whole-value `==`; a copy
  taken before a feed is unaffected by the feed.
- **I6** The gate cannot pass vacuously: it derives both lengths it looks for from
  the built product, it matches both copy calls named in I1, and it fails if it
  cannot find the object, the lengths, or any one of the roots it walks from.

## 4. Proof obligations

Behavioral and structure-insensitive; a refactor that keeps the behavior keeps
these passing.

- **PO1 (I1, I6)** The tooling gate, run against the release object: green after
  the change; and its self-test, in the style of `scripts/tests/*_test.sh`, shows
  it fails on a fixture disassembly where the copy sits two direct call edges below
  a root -- so a walker that visits only immediate callees cannot pass -- and fails
  when the object, either length, or any root symbol is missing. The multi-edge
  case is run from each root in turn, so neither public overload can be silently
  unguarded, and it is covered once in the `memmove`/stride form as well as the
  `memcpy`/size form. Because a hand-written fixture cannot prove the walker parses
  real disassembly -- mangled callees, thunks, tail calls -- the gate is also run
  once against the *pre-change* release object and must fail there, naming both
  known sites; that result is recorded with the gate.
- **PO2 (I2)** The projection published through `scrollProjection` and the
  projection carried by the damage snapshot agree, on both screens, following and
  browsing, with and without evicted history. Existing viewport, alternate-screen,
  and damage tests must stay green untouched.
- **PO3 (I3, I4)** Recovery is actually exercised: every scenario clears the
  cached cluster context between the base scalar and the combining scalar (a
  cursor move, as the existing tests do), so the second scalar can only join
  through the grid. Both outcomes are preserved -- recovery joins through a
  *preceding* wide tail back to its wide head, and recovery does not join when
  the cursor itself sits on a wide tail -- alongside the plain cases: column 0,
  mid-row, on a pending wrap, and across a soft-wrapped row boundary. Existing
  grapheme tests stay green untouched.
- **PO4 (I4)** Damage published per action is unchanged for a feed that prints,
  scrolls, and switches screens; existing damage tests stay green untouched.
- **PO5 (I5)** A value copy of a terminal taken before a feed compares unequal to
  the fed terminal and equal to itself, and `Terminal` still compiles as
  `Sendable` with no `@unchecked`.

## 5. Benchmark gate

Frozen rules from `research/39/D2`; conditions from
[agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md).
Note the pre-change revision before starting.

1. `just benchmark-quick baseline=<pre-change> workload=kitten-feed-<arm>` on
   all four arms: `ascii` +/-1.70%, `unicode` +/-1.80%, `unique-unicode`
   +/-1.60%, `csi` +/-1.45%. The cost is per action, so every arm should read
   `faster`; one that does not is recorded, not hidden.
2. `just benchmark-confirm baseline=<pre-change>` before the performance claim
   is recorded anywhere durable. `terminal-feed` and `scrollback-stream` share
   the feed path and are expected to move. Read `content-churn` and
   `retained-browse` against `F7`'s change-free control, not in isolation.
3. Confirmation of `H3` itself, after the ladder verdict, read **by copy size
   in the release object**: no `memcpy` or `memmove` whose length is
   `MemoryLayout<Terminal>.size` or `.stride` remains in any feed-path
   function, and every site left in the object is named as guarded or cold. It
   is read that way and not as an absence of `_platform_memmove` samples under
   `apply` or `recoverClusterContextFromGridIfNeeded`, because a profile stack
   carries no copy length and small copies legitimately stay on those paths --
   an absence of the frame is neither necessary nor achievable, and a share is
   no substitute because the fix shrinks the denominator. The external
   confirmation stays what it was: the kitten `ascii` and `unicode` MB/s
   figures move, recorded with window state and geometry.
4. Record the decision-bearing values -- mode, workload, both tree identities,
   the median symmetric estimate, the classification -- in the commit, and add
   the outcome to `docs/research/39-kitten-render-benchmark/findings.md` as a
   finding.

`just test`, `just lint`, and `just test-tooling` before the commit.

## 6. Non-goals

- The 55 guarded or cold copy sites. They share the mechanism, not the profile;
  `D5` names the storage box as their answer if one ever profiles.
- The storage-box structure itself.
- `H2`, `H4`, `H6`, and the `takeOutputTurn` array copy. Each is its own change
  and its own gate.
- Any change to what the projection or the damage snapshot means.

## 7. Accepted risks

- **AR1** The gate resolves the call graph from direct calls in the disassembly,
  so a copy reached only through an indirect call (a closure or a witness) is out
  of its view. Accepted: the feed path below the roots is a concrete non-generic
  call chain, the one closure edge in it -- the array overload's
  `withUnsafeBufferPointer` -- is not load-bearing because that overload is itself
  a root, and the benchmark ladder catches a regression the gate misses.
- **AR3** The gate names its roots by symbol, so renaming a public entry point
  moves the guard. Bounded by I6: a root it cannot find is a failure, not a pass.
- **AR2** The gate needs a release build, which is why it lives in
  `test-tooling` and not `just test`; a regression can land in a commit and be
  caught only at the tooling gate. Accepted because the ladder also catches it
  at the next benchmark run, and because the alternative is a release build in
  the commit gate.

## 8. Rejected ideas

- Gating the whole object instead -- classifying every `Terminal`-sized copy site
  with a per-symbol allowed maximum. It proves the same thing the reachability
  walk proves, but drags the 55 cold and guarded sites this plan declares a
  non-goal into a hand-kept table whose counts move with any codegen change.

## 9. Implementation discretion

- Where the projection function lives and whether the cluster predecessor is a
  `ScreenState` method or an inline read, and where it takes the column count
  from once it no longer reads the terminal's; an `@inline(__always)` is permitted
  where the gate shows it is still needed, with a comment naming the gate.
- How the gate obtains `MemoryLayout<Terminal>.size` from the built product,
  which disassembler it reads, and how it walks direct calls to build the
  reachable set.

## Commit progress

- [x] 1. perf(terminal): stop copying the whole terminal to read the projection and the cluster predecessor
- [x] 2. test(tooling): gate the feed path against a terminal-sized copy

## Implementation notes

- The projection derivation is a `private static func` on `Terminal` taking the
  five inputs; the public `scrollProjection` getter forwards to it and the
  damage snapshot calls it directly. The cluster predecessor became a
  `ScreenState` method taking `columnCount` as an argument, since the column
  count is terminal-stored. Both shapes are the plan's first choice under
  section 9, and neither needed an `@inline(__always)`.
- Section 5's third criterion was restated by copy size on the user's
  adjudication of 2026-08-28. A `sample` stack carries no copy length, so "no
  `_platform_memmove` under `apply`" is not a criterion an implementer can meet
  or refute; the release object read by length is. `D5`'s matching criterion and
  the README's `H3` text were changed the same way, so the three agree.
- The `scrollback-stream` `slower` verdict (+9.54%, then +11.25%) is recorded in
  `F8` as an off-target, non-reproducing call, with the change-free control
  (+5.16% on zero code delta) beside it, on the user's adjudication of the same
  date. The slot-position draw-tail confound behind it is noted in `F8` for
  `research/7`, which owns the ladder.
- **For commit 2.** The release object still holds 48 whole-terminal copies,
  down from `D5`'s 58, and two of them are inside functions the feed path
  enters: four in `recordDamage(from:to:)` (the `damagedViewportRows(for:)`
  calls, reached only when the selection or the hovered link changed) and one in
  `appendToOpenClusterIfJoined` (the `clusterTargetCanChangeWidth` call, reached
  only when a combining mark would change a cluster's width). Both are in `D5`'s
  guarded bucket and neither runs on an ordinary printed character, but `I1` as
  written -- "no function on the feed path copies a whole terminal" -- is
  literally false for them. The gate has to say what it means: unconditional
  copies only, or a named and justified exemption. It cannot be written as a
  bare reachability walk that fails on the tree it is supposed to pass.
- **Commit 2, as shipped.** The gate answers that question with a named list of
  unconditional feed-path functions -- `feedBuffer`, `apply`, `execute`,
  `recoverClusterContextFromGridIfNeeded` and the `print*` family -- written in
  `scripts/terminal-self-copy-gate.py` with the reason beside it, and not with
  the reachability walk section 2 wrote. `I1`'s "no function on the feed path"
  is true only of the unconditional ones, so the list is what states which those
  are; the five guarded copies stay `D5`'s guarded bucket. `I6` survives whole:
  the gate fails when a root symbol, the object, or either length is missing.
  Both lengths come from a release `TerminalValueLayoutProbe` built in the same
  scratch (1521 size, 1528 stride today). `PO1`'s pre-change reading was taken
  as an injected regression instead of against the pre-change commit: the damage
  snapshot back on an `@inline(never)` `scrollProjection` failed the gate at
  `apply+0x87f4` and `feedBuffer`'s stretch closure at `+0x8164`, both a
  `memcpy` of 1521 bytes, which is the same proof that the walker parses real
  disassembly.

## Follow Up

- Take the external kitten confirmation `D5` still owes: `kitten
  __benchmark__ --render` on an optimized slot at 179x66, `ascii` and `unicode`,
  recorded with window state and geometry, and add the column to the `Trigger
  and current evidence` table in
  `docs/research/39-kitten-render-benchmark/README.md`. `F8` states plainly that
  it is not taken.
- Carry the slot-position draw-tail confound into the two docs that own the
  ladder: `docs/research/7-fast-performance-benchmarks.md` and
  `agent-docs/terminal-performance.md`, beside `scrollback-stream`'s 3-of-8
  false-call record. On this session's three probes a candidate on physical slot
  `b` paid 17.0-18.4 ms of draw tail against a cached slot-`a` baseline's
  10.5-15.8 ms with no code difference. `F8` records the observation; neither
  ladder doc carries it, so the next reader of that cell cannot price it.
