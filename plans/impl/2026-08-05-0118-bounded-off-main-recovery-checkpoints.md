# Quit hang: bounded, off-main recovery checkpoints

## Context

Quitting the optimized dev build hung the app. The quit confirmation panel stayed
on screen and stopped responding; macOS sampled the process after 29 seconds of
unresponsiveness and filed a 30.10s hang report.

Stackshot: `dump.txt` at the repo root (4.7 MB, untracked — local artifact, not
committed). All 11 samples share one stack, and every other thread is idle, so
this is main-thread CPU burn, not a deadlock:

```
QuitConfirmationPanel.confirmQuit → AppRuntime.send → perform → -[NSApplication terminate:]
  AppDelegate.applicationWillTerminate         (AppDelegate.swift:804)
    AppRuntime.prepareRecoveryForApplicationExit  (AppRuntime.swift:1209)
      performEnrichedCheckpoint(async: false)     (AppRuntime.swift:1281)
        scrollbackByPaneId()                      (AppRuntime.swift:1265)
          Terminal.primaryHistoryText             (Terminal.swift:2282)
            projectedHistoryText(from:)           (Terminal.swift:3015)
              String.UnicodeScalarView.append<A>(contentsOf:)
                specialized static String.+ infix
                  _StringGuts.prepareForAppendInPlace → _platform_memmove
```

Three separate problems stack up on that path. Only the first caused the hang.

**1. Quadratic text projection (root cause; fix already applied in the working
tree).** `forEachProjectionUnit` emits one unit per *cell*, so the accumulator
body ran once per character. It appended via `unicodeScalars.append(contentsOf:)`,
whose generic-sequence overload routes through `String.+` — visible in the stack
above — which leaves the accumulator non-uniquely referenced and copies the whole
string on every call. N characters cost N full copies.

Measured against the real `Terminal`, release, one pane at a budget-full history:

| retained history | before | after |
|---|---|---|
| 156K chars | 0.58s | 0.015s |
| 1.25M chars | 14.7s | 0.098s |
| 1.94M chars (16 MiB budget full) | **38.11s** | **0.15s** |

38s for a single pane matches the observed hang. The same path backs
`fullHistoryText` (the `danterm read-pane-text` IPC route) and `selectedText`, so
a large copy and a CLI text read hung identically. Fixed by appending scalars
singly at both projection sites in `Terminal.swift`, plus a regression test that
compares *per-character* cost at two history sizes.

**2. The projection is ~97% wasted work.** `scrollbackByPaneId()` projects each
pane's entire retained history, then `truncateScrollback` discards everything but
the last 4000 lines / 400K characters. The scrollback budget is 16 MiB per
terminal, so the projection is sized by the budget rather than by what is kept.
Even with the linear accumulator this is ~0.15s per budget-full pane.

**3. All of it runs on the main thread.** `performEnrichedCheckpoint(async:)`
only makes the *write* asynchronous — `scrollbackByPaneId()` runs on the main
thread either way. The checkpoint window is 600s, so before the fix an active
session froze for tens of seconds every 10 minutes, not just at quit. Quit made
it visible because `terminate:` runs `applicationWillTerminate` before the run
loop can return and redraw the panel.

**Desired outcome.** Recovery checkpoints cost time proportional to the
scrollback actually retained in the checkpoint, and do not stall the UI —
during a session or at quit.

## Decision

Three changes, in order. Each is independently shippable and independently
measurable.

**D1 — Linear text projection (applied).** Keep the per-scalar accumulation in
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift` at both projection sites,
and the scaling regression test in `TerminalScrollbackTests.swift`.

**D2 — Bounded tail read.** Give `TerminalCore` a way to project only the tail of
retained history under an explicit line and character budget, and have the
checkpoint use it instead of projecting everything. The store already supports
this shape: display rows are addressable, `locate(displayRow:)` is a binary
search, and soft-wrap state is readable per row without materializing a row. The
budget is passed in by the caller; `TerminalCore` learns no recovery policy.

`truncateScrollback` in `lib/DanTermCore/Sources/DanTermCore/Persistence.swift`
keeps its exact semantics and stays the authority on the final cut — the tail
read only shrinks its input.

**D3 — Move the checkpoint off the main thread.** `Terminal` is a `Sendable`
value and the session controller holds it, so the main thread can capture the
per-pane terminal values and the model snapshot, then hand projection,
truncation, grafting, encoding, and writing to the existing checkpoint IO queue.
`graftScrollback` and the snapshot codec are already pure. The main thread
retains only the state capture, which must stay on the main actor because it
synchronizes session state first.

Everything after the capture is a pure function of it — captured state in,
encoded bytes out — and lives outside `app/`, which has no unit-test target. That
placement is what makes the checkpoint payload testable at all, so it is a
decision of the plan rather than of the implementation.

Quit stays synchronous — the process is exiting and the checkpoint must land —
but after D2 the synchronous cost is proportional to what is written.

**D4 — Lint guard.** Add a gate step, in the style of the existing
`scripts/*-lint.sh` checks and registered in `scripts/run-test-suite.sh`, that
rejects the generic-sequence `unicodeScalars.append(contentsOf:)` overload within
`TerminalCore`, with an explicit allowlist for the bounded single-append sites.
The guard catches the concrete mechanism only; PO1 carries the semantic
guarantee, and no lint is expected to recognize accumulation in a walk.

## Invariants

- **I1.** Projecting retained history costs time proportional to the text
  produced, not to its square.
- **I2.** The scrollback a checkpoint stores is identical to what projecting the
  full history and truncating it would have stored, for any terminal state —
  including histories shorter than the budget, histories with no hard line
  breaks, soft-wrapped runs spanning the tail boundary, and empty histories.
- **I3.** Checkpoint cost is proportional to the retained scrollback budget, not
  to the terminal's scrollback capacity.
- **I4.** A periodic checkpoint performs no scrollback projection, truncation, or
  encoding on the main thread.
- **I5.** Concurrent checkpoints observe a consistent per-pane pairing of model
  snapshot and scrollback: a checkpoint never writes one pane's text against
  another checkpoint's model.
- **I6.** Restore fidelity is unchanged: a session checkpointed and restored
  yields the same panes, scrollback, and pane state as before these changes.
- **I7.** Enriched checkpoint writes land in capture order, and the quit
  checkpoint drains any in-flight checkpoint work before returning. A checkpoint
  captured earlier can never overwrite one captured later. Keeping each
  checkpoint's whole pipeline as a single work item on the existing serial queue
  satisfies this; moving any stage to an unordered queue breaks it.

## Proof obligations

- **PO1 (I1).** A test that establishes the projection's scaling behavior without
  an absolute time budget, so it holds on a slower machine. *Applied:*
  `primaryHistoryTextStaysLinear` compares per-character cost across history
  sizes; verified to fail on the quadratic accumulator (5.5x growth) and pass on
  the linear one (1.04x), against a 2.5x threshold.
- **PO2 (I2).** Equivalence between the bounded tail read and truncating the full
  projection, over terminal states that exercise the boundary conditions named in
  I2. This is the obligation that lets D2 ship; it is not discretionary.
- **PO3 (I3).** A measurement showing checkpoint cost tracks the retained budget
  rather than the scrollback capacity — the same instrument that produced the
  table above, re-run after D2.
- **PO4 (I4).** Thread placement is structural, not behavioral, and `app/` has no
  unit-test target — so this is discharged by a placement check in the style of
  the existing `scripts/terminal-exit-concurrency-lint.sh`, plus the end-to-end
  step below.
- **PO5 (I5).** A unit test over the captured state value showing each pane's
  scrollback is paired with the model snapshot captured alongside it, including
  when a pane closes between captures. This is a test of the pure pipeline, which
  is why D3 places it outside `app/`.
- **PO6 (I6).** The existing checkpoint and restore suites pass unchanged. If a
  scrollback assertion needs editing to accommodate D2, that is a signal I2 was
  violated, not a test to update.
- **PO7 (I7).** A test that a checkpoint captured earlier cannot overwrite one
  captured later, over the pure pipeline and its write step.

## Non-goals

- Changing the retained-scrollback budget, the checkpoint window, or the
  truncation limits. This plan changes what the existing limits cost, not what
  they are.
- Reworking the quit confirmation UI. Once the checkpoint is bounded, the panel
  has nothing to wait for.
- Auditing every `append(contentsOf:)` in the codebase. The hyperlink URI site is
  a single bounded append into a fresh string and is correct as written.

## Accepted risks

- **AR1.** Holding `Terminal` values off the main thread makes the arena
  non-uniquely referenced, so the next admission copies the chunk it writes. The
  store is chunked specifically so this is one chunk rather than the whole arena
  (`31/D5`), and the window is the duration of one checkpoint. If admission cost
  during a checkpoint proves material, the mitigation is to project on the main
  thread — cheap after D2 — and move only encoding and writing.
- **AR2.** Capturing every pane's terminal value at once holds those arenas alive
  for the checkpoint's duration, raising peak footprint on sessions with many
  full panes.
- **AR3.** D3's win is the multi-pane sum, not the per-pane figure. After D2 the
  projection still costs roughly 30ms per budget-full pane — the measured
  0.15s/1.94M-character rate scaled to the 400K-character retained budget — plus
  truncation and encoding. One pane is a hitch; N panes every checkpoint window
  is a stall, which is what I4 exists to prevent. The figure is derived from D1's
  table and should be confirmed by PO3 after D2 lands.

## Rejected ideas

- **RI1.** Accumulating into a scalar array or a byte buffer instead of appending
  per scalar. Measured slower than per-scalar appending (0.094s vs 0.027s over
  1.6M scalars) for more code.
- **RI2.** Deferring the quit checkpoint or writing it asynchronously. The
  process is exiting; the write must complete before it does.

## Implementation discretion

- How the tail read locates its start row — including whether it over-fetches and
  retries — so long as I2 holds.
- Whether the off-main capture hands over terminal values or a narrower
  per-pane snapshot.

## Verification

1. `just test` — the full gate, including the new lint steps (D4's append guard
   and PO4's placement check).
2. `swift test --package-path lib/TerminalCore` — projection scaling and tail
   equivalence.
3. Re-run the scaling measurement that produced the table above, at a budget-full
   history, and confirm checkpoint cost tracks the 400K-character retained budget
   rather than the 16 MiB capacity.
4. End to end: build the optimized dev bundle, fill a pane's scrollback, leave the
   session running long enough for a periodic checkpoint, then quit through the
   confirmation panel. The panel should dismiss without a hang, and the restored
   session should come back with its scrollback intact.

## Commit progress

D1 shipped ahead of this checklist as `4b402d8`, so the entries below cover the
remaining decisions. Each is one of the plan's "independently shippable and
independently measurable" changes, and each leaves the tree green.

- [x] 1. D2 -- bounded tail read: project only the tail of retained history under
  the caller's budget, and have the checkpoint use it (PO2, PO3).
- [ ] 2. D3 -- move the enriched checkpoint pipeline off the main thread, with the
  pure capture-to-bytes stage outside `app/` (PO4, PO5, PO6, PO7).
- [ ] 3. D4 -- lint guard rejecting the generic-sequence
  `unicodeScalars.append(contentsOf:)` overload inside `TerminalCore`.

## Implementation notes

**D2 -- the tail read's stopping rule is checked on its own output.** The
"Implementation discretion" clause allows over-fetch and retry, and the walk
takes it: it projects a row window, asks whether that text already pins where a
suffix-keeping cut falls, and doubles the window until it does or the window is
all of history. The condition is a disjunction -- at least `maxLines` hard breaks
*or* more than `maxChars` characters, both measured after the leading and
trailing whitespace a truncation trims. Either alone is sufficient, and the proof
is short in both directions: with enough breaks the line cut lands on the same
newline in tail and full, and with enough characters the character cut takes the
same suffix of a common suffix. The alternative -- computing the exact start row
up front -- has to model soft wrap, blank rows past the last content, and the
leading trim before projecting anything, and it would still be checked by the
same test.

**D2 -- leading/trailing whitespace is modelled with `Character.isWhitespace`.**
`TerminalCore` imports nothing, so it cannot ask Foundation what
`.whitespacesAndNewlines` covers. `isWhitespace` is a superset of it, so the
model over-trims, which undercounts, which can only cost an extra pass -- never a
tail that stops short. The direction of that error is the reason the substitution
is safe, and it is stated where the code makes it.

**D2 -- the first window adds the live screen's height.** A bare `maxLines + 1`
misses by a handful of rows in the ordinary case, because the rows below the
cursor are blank and the projection stops at the last row with content, so the
window yields one break short of the budget and doubles. Seeding with the screen
height covers exactly that systematic shortfall: at 80 columns it took the tail
read from 600K characters over two passes to 304K over one.

**D2 -- PO3, re-measured (release, `Terminal` at a budget-full 16 MiB history).**
The full projection reproduces D1's post-fix figure, and the tail read is sized
by the retained budget rather than by the capacity:

| width | full projection | bounded tail |
|---|---|---|
| 80 cols | 0.162s / 1.91M chars | **0.030s / 304K chars** |
| 200 cols | 0.160s / 1.94M chars | **0.072s / 790K chars** |

80 columns matches AR3's ~30ms estimate. 200 columns costs more because the
4000-*line* half of the budget binds there -- 4000 rows of ~195 characters is
790K characters, which `truncateScrollback` then cuts to 400K. That is still the
budget rather than the capacity, which is what I3 asks; a read that stopped at
whichever half binds first would need to know the answer before projecting.

**D2 -- PO2 lives in `app-tests/`, not beside either half.** The obligation is
that `TerminalCore`'s projection and `DanTermCore`'s `truncateScrollback` agree,
and `DanTermAppTests` is the only target that compiles both. Giving
`lib/DanTermCore` a `TerminalCore` dependency to host it would couple the pure
model package to the terminal engine for a test's sake. The cost is that the
boundary-condition table is written twice -- once there for the equivalence, once
in `TerminalCore` for the engine-side contract -- because separate SwiftPM
packages cannot share test fixtures. Both were verified to fail on a tail read
that omits the retry.

**PO4's premise is wrong about `app/`.** The plan says `app/` has no unit-test
target; `app-tests/` (`DanTermAppTests`, `@testable import DanTerm`) is one, and
it is in the `just test` gate. That does not change D3's placement decision --
the pure pipeline still belongs outside `app/` on its own merits -- but the
"there is nowhere to test it" argument for discharging PO4 by lint alone does not
hold, and D3 should reconsider it.
