# Decisions -- baseline memory with ten tabs open

One entry per stable ID. `D1` is a standing rule; later entries record
direction gates and their verdicts.

### D1 -- the process total decides, attribution explains

- Status: **settled**; governs every claim in this doc.
- Evidence used: `F1` (the total is what the chart and Activity Monitor
  show), `15/F1` (the malloc heap was about a quarter of the app's footprint,
  so a heap-only reading misattributes), and
  `agent-docs/measurement-discipline.md` (every aggregate carries its count).
- Candidate solutions considered:
  - Decide on in-app counters alone. Rejected: a counter reports what the app
    thinks it released, not what the render server or the kernel kept.
  - Decide on `vmmap` class lines alone. Rejected: it cannot be read from a
    benchmark harness and is a diagnostic, not a receipt.
  - Decide on whole-process `phys_footprint` measured the way termfoot
    measures it, with class attribution and in-app counters reported beside
    it so a smaller total cannot be credited to a mechanism that did not move.
    Selected.
- Tradeoffs and correctness risks: the total is noisy across sessions and
  displays, which is why comparisons are contemporaneous and same-conditions
  only.
- Decision and rationale: a change is credited with a memory improvement only
  when the contemporaneous total moved, the attributed class moved by a
  matching amount, and tab-switch latency was reported beside both.

### D2 -- direction for hidden-pane presentation memory

*Superseded in part by `D5`: the fast path this entry chose was measured and
removed. Everything below is left as written, as the reasoning `D5` answers.*

- Status: **settled** (`T7`, 2026-09-01); the gate for `T8`. Nothing below
  is implemented yet.
- Evidence used: `F4` (30 surfaces are 94% of the footprint; ten are shared
  with the WindowServer, twenty are app-only), `F5` (a reveal presents no
  frame today; a from-scratch swapchain rebuild is 16.59 ms median, 43 ms
  tail), `F7` (`T5`, kept: without the eager clear a buffer costs nothing
  until it is rendered), `F8` (`T6`, throwaway: volatile pages leave
  `phys_footprint` at once, 645 MB to 98.5 MB; the reveal is 1.37 ms with
  pages intact; the attached buffer was still `isInUse` after a committed and
  flushed detach in 44 of 44 hides; the discard path is unmeasured),
  `tests-ui/IOSurfaceLayerContentsTests.swift` pin two (a detached surface
  frees only after later presentations, and once free stays free),
  `33/T25` (a live swapchain never changes shape; a trust break is always
  replacement; a buffer is written only when detached and reported free), and
  the SDK: `IOSurfaceRef.h:434-449` (`IOSurfaceSetPurgeable` and the meaning
  of the returned old state), `IOSurfaceRef.h:438-440` (a texture bound to a
  surface that comes back `Empty` has undefined content), `IOSurfaceRef.h:394-412`
  (`IOSurfaceIsInUse` is the only call that may decide "in use"; the count is
  system-wide across processes). Neither `IOSurface.framework` nor
  `QuartzCore.framework` declares a notification or callback for a surface's
  use count changing (grep of both header sets, macOS 26.5 SDK), so the app
  can only ask.

**The two properties the structure must give by construction.** (1) Pixel
memory of a hidden pane cannot dominate the baseline. (2) No surface the
render server may still read can hold undefined pixels. Property 2 has one
sufficient rule, and it is the rule `T25` already trusts for writes: a
surface is made volatile only while it is detached from the layer and
`IOSurfaceIsInUse` reports it free, and pin two says such a surface cannot
be re-acquired. Marking a free detached surface volatile is exactly as safe
as writing it, which the swapchain does on every publish.

**How the render server's hold bounds every shape.** After
`layer.contents = nil` is committed and flushed, the buffer that was attached
is still in use (`F8`, 44 of 44). Pin two says it frees only after later
presentations flush the pipeline, and a hidden layer presents nothing. So
whichever shape wins, that one surface per hidden pane leaves the footprint
only when the render server lets go, and the app cannot make that happen or
be told when it does; it can only ask again later. Two facts follow. The
"release" shapes and the "volatile" shapes tie on this term: dropping the
app's reference to a surface the server still holds does not free its pages
(the surface is reference-counted across processes, and by default its
memory stays on the creating task's ledger --
`IOSurfaceSetOwnershipIdentity`, `IOSurfaceRef.h:466`, exists to move it).
And the term is bounded by what `F8` found: the two free buffers of every
hidden pane go at hide, and the third goes when the server frees it, which
is 0 to 9 surfaces (0 to 182 MB at this staging) depending on a behavior no
reading has measured yet (uncertainty 1 below).

- Candidate solutions considered, all at the ten-tab `D3` staging with `T5`
  in the tree. "Idle" is the empty arm; "after use" is a hidden pane that
  rendered three frames before it was hidden; "residual" is the ex-attached
  surface the server may still hold, 0 to 20 MB per hidden pane.

  | Shape | Idle bytes | After use, hidden | Reveal | Correctness seams | Lifecycle owner |
  |---|---|---|---|---|---|
  | (a) visible-lifetime release: hide detaches, commits, drops the swapchain and the displayed store | 37 MB app + 20 MB visible pane + residual | same as idle | rebuild every time: 16.59 ms median, 43 ms tail (`F5`); 6.32 ms in `F8`'s faster session; synchronous inside the reveal turn, so no blank frame, only a later commit | none new: a released surface stays valid for whoever still holds it; fresh buffers are untrusted by construction (`isCurrent`) | lowest: hide is one more trust break; the retry is inert once `swapchain` is nil; needs "no presentation while hidden" |
  | (b) all volatile at hide (`F8` as measured) | 98.5 MB measured without `T5`; ~57 MB with it | same as idle | 1.37 ms with pages intact (`F8`); discarded path unmeasured | the attached buffer goes volatile while in use, 44 of 44; a discard under pressure hands undefined pixels to whatever the server still composites from it (`IOSurfaceRef.h:438`) -- fails property 2 | as (c) minus the in-use branch |
  | (c) volatile only when free: hide detaches, marks the free buffers volatile, and re-asks the in-use one on a bounded per-refresh retry; reveal restores and rebuilds if anything came back `Empty` | 57 MB + residual, same residual as (a) | same as idle | 1.37 ms intact (`F8`); a rebuild, as (a), when a buffer was discarded (unmeasured) | none beyond pin two's premise; a discarded buffer is a trust break and takes the replacement path | (a) plus: per-buffer purgeable state, a bounded deferred check with the same shape as the presentation retry, a three-way restore outcome, and "no write while released" enforced in the swapchain |
  | (d) detach, wait for free, then release or make volatile | as (a) or (c): waiting changes nothing, because releasing an in-use surface is already safe and the wait is the deferred check (c) has anyway | -- | -- | -- | (c) with no advantage |
  | (e) one frozen surface per hidden pane: keep the attached buffer, release two | 57 MB + 182 MB, deterministic | same | no render at all: the old frame is still attached | the frame is stale until the reveal publish lands; a thumbnail of a hidden window shows old content | low |
  | (f) `T5` alone | 241 MB idle (`F7`) | full 60 MB per busy pane | no frame, as today | none | none |

  `T5` is orthogonal to the choice and is kept: it is what makes the visible
  pane's own idle term 20 MB rather than 60, and under (a) it is what makes a
  reveal's three fresh buffers cost one buffer of pages rather than three.
  (e) is rejected on memory: it leaves exactly the term (c) only leaves when
  the server does, and leaves it always. (b) is rejected on property 2. (d)
  reduces to (a) or (c). (f) is not a direction, it is the floor every shape
  starts from.

- **The ideal.** (a). It is the smallest structure in which both properties
  hold: a hidden pane owns no pixels, so nothing of its can be resident or
  volatile, and every trust break while hidden is answered by the one rule the
  swapchain already has -- replacement on reveal. It adds no state and no
  premise. What is wrong with it is one behavior it loses: the reveal. Today
  a tab switch presents nothing and costs nothing (`F5`); under (a) every
  switch allocates three surfaces and renders a full frame first, 6 to 17 ms
  median with a 43 ms tail, on the most frequent action a ten-tab user makes.
  The README's own rule says a memory win is also a latency claim and the two
  are reported beside each other, never netted. (c) removes that cost in the
  common case (pages intact, 1.37 ms) and degrades to exactly (a) in the rare
  one (pages discarded), at the same idle bytes.

- **Decision: (c), built as (a) plus a fast path, in that order.** A hidden
  pane is *detached and untrusted*: it presents nothing, its layer holds no
  contents, and its buffers are either gone or volatile. `T8` lands two
  commits. Commit 1 is (a) complete: hide is a trust break, no presentation
  while hidden, the retry made safe, every hidden-time input reconciled on
  reveal, all the behavioral coverage below that does not mention
  purgeability. Commit 2 adds the volatile fast path inside the swapchain,
  with the real-AppKit pin and the census field. Commit 1 stands on its own,
  and if commit 2's measurement (`T9`) shows the deferred check never
  succeeds or its state does not earn its latency, dropping commit 2 leaves
  the ideal in the tree. That is the trade in plain terms: commit 2 spends
  one bounded retry, one purgeability state per buffer, and one three-way
  outcome to buy back 5 to 15 ms on every tab switch. The user sees both
  numbers before the branch is merged.

- Tradeoffs and correctness risks: the residual (uncertainty 1) is the same
  under both commits and is the render server's, not the app's. The
  `phys_footprint` win of a volatile page is an accounting fact until the
  kernel reclaims it (`F8`, competing interpretations); that is the number the
  chart reads, and it is reported as such. Window occlusion is already a hide
  (`AppRuntime.syncPaneVisibility` folds `occlusionState` into the pushed
  visibility), so an occluded window's panes detach too; the reveal on
  de-occlusion is the same path and the same cost, and what a window
  thumbnail shows in between is uncertainty 4.

#### What `T8` implements

**State.** A pane is in one of two presentation states, decided by
`isPaneVisible` and nothing else. *Visible*: as today. *Hidden*: the layer's
`contents` is nil, `displayedStore` is nil, no presentation runs, and the
swapchain (if one exists) has its pixels released -- every buffer that was
detached and reported free is `kIOSurfacePurgeableVolatile`, any buffer
still reported in use is non-volatile and waiting on the deferred check.
Two new swapchain entry points own the purgeable state, with the in-use and
purgeability calls injected the way `isStoreInUse` already is so the
headless suite can drive every outcome:

- `releasePixels() -> Int`: called only after the view has detached the
  layer, so attachment is no longer a criterion; set every buffer that
  reports free volatile and return how many are still in use. Sets a
  `pixelsReleased` flag under which
  `publish` and `retryPendingPresentation` return nil and keep the plan
  pending: a released buffer is never written, enforced by the type that
  writes.
- `reclaimPixels() -> Bool`: set every buffer non-volatile, clear the flag,
  return true only if every returned old state was `Volatile` or
  `NonVolatile`. `Empty` or a non-`KERN_SUCCESS` return means the pixels are
  untrusted and the caller must replace the swapchain. Do not call
  `requireEveryBufferToRenderAgain` in either outcome: it moves the
  convergence barrier and does not clear `isCurrent`, so it cannot make a
  discarded buffer safe (the next render would apply damage over garbage),
  and after an intact reclaim the pages are exactly what they were
  (`IOSurfaceRef.h:445`) and the stale-damage ledger is still right, so a
  barrier would only force two extra full renders. Untrusted means
  replacement, which is `T25`'s only distrust mechanism; intact means
  nothing.

The view gains one rule and one retry. The rule: `present(plan:damage:metrics:)`
and `retryPendingPresentation` return at once while `isPaneVisible == false`.
That single guard covers the theme, font, backing-scale, color-space, and
benchmark re-renders, all of which reach `present` through
`rerenderCurrentPlan`, and it is what stops a hidden pane from ever
allocating or writing buffers. The retry: `armPixelReleaseRetryIfNeeded()`,
the same shape as `armPresentationRetryIfPending` -- one
`DispatchQueue.main.asyncAfter` per display refresh, `[weak self]`, armed
only when `releasePixels()` returned a nonzero count, bounded by a tick
budget, and inert when the pane is torn down, visible again, or holding a
different swapchain than the one it was armed for. Each tick calls
`releasePixels()` again and re-arms while the count is nonzero and the
budget remains. The budget's value is set from the `T8` trace (uncertainty
1); start at 120 ticks and record the tick at which the surface freed as a
presentation event.

**Hide** (`setVisible(false)` from visible):

1. Record `.hide`; `isPaneVisible = false`.
2. `CATransaction.begin`; `setDisableActions(true)`; `layer.contents = nil`;
   `commit`; `CATransaction.flush()`. `displayedStore = nil`. The flush is
   what makes the next step's in-use read meaningful (`F8`).
3. Commit 1: `discardSwapchain()` (records `.rebuild` only if a chain existed;
   the retry finds `swapchain == nil` and stops). Commit 2 replaces this
   step: `let inUse = swapchain?.releasePixels() ?? 0`; if `inUse > 0`, arm
   the pixel-release retry. Record one event per buffer as `F8` did
   (`hideVolatileFree` / `hideVolatileInUse` / `hideVolatileFailed`).
4. `controller.setVisible(false)`.

**Reveal** (`setVisible(true)` from hidden):

1. Record `.reveal`; `isPaneVisible = true`; the pixel-release retry is now
   inert by the visibility guard.
2. Commit 2 only: if a swapchain exists and `reclaimPixels()` returns false,
   `discardSwapchain()`. Record the per-buffer outcome (`revealIntact` /
   `revealDiscarded` / `revealNonVolatile` / `revealFailed`).
3. `let submittedGrid = synchronizePresentation()`, which already submits a
   grid deferred while hidden and replaces a swapchain whose metrics or color
   space moved. Reveal renders exactly once: if `submittedGrid` is true the
   controller's republish presents (and would replace the chain on geometry
   anyway), so nothing renders here; otherwise `rerenderCurrentPlan()`. Never
   both -- a hidden resize followed by a reveal must not pay two rebuilds. If
   `synchronizePresentation` bailed (no window, zero bounds), the pane stays
   blank exactly as a fresh pane does until geometry arrives.
4. `controller.synchronizeState()` if `submittedGrid` or
   `hasUnfencedHiddenGridSubmission`, then clear the flag, as today.
5. `controller.setVisible(true)`, which publishes the damage accumulated
   while hidden; under an intact chain that is an incremental apply over
   pixels the kernel guarantees unchanged, under a replaced chain it is a
   full render by `isCurrent`.

**Each trust break while hidden.** Theme: `applyResolvedTheme` discards the
swapchain as today (a volatile chain may simply be dropped), `setTheme` does
not republish on a hidden controller, and the `rerenderCurrentPlan` fallback
is stopped by the visibility guard; reveal step 3 rebuilds. Backing scale
and window color space: `viewDidChangeBackingProperties` runs
`synchronizePresentation`, which records the new metrics and reaches
`rerenderCurrentPlan`, stopped by the guard; reveal step 3 sees the mismatch
and replaces. Font: `setFont` is the same path. Grid: rectangle geometry is
already deferred while hidden and submitted at reveal; an override is
submitted immediately and fenced at reveal (existing tests); either way the
republish replaces the chain on geometry. In every case the reveal renders
once. A discarded chain cancels the pixel-release retry by identity.

**Teardown while hidden.** `tearDown()` is unchanged. The swapchain and its
surfaces are released with the view; a volatile surface may be released
without restoring it, and nothing composites it (it was free when marked).
Both retries are `[weak self]` and guard `isTornDown`, so a closure that
fires after teardown does nothing. A visible pane being closed keeps its
contents attached until the layer dies, as today.

**The armed presentation retry.** It stays armed across a hide; the
visibility guard makes it a no-op that leaves the plan pending. Nothing
cancels it and nothing has to: `presentAttempt` re-arms only from a
presentation, and there is none while hidden. On reveal, step 3's render
supersedes the pending plan (`publish` replaces `pendingPlan`), or step 5's
republish does. Commit 2 adds the second line of defense inside the
swapchain: a released chain refuses to write regardless of who asks.

**The census.** `readSurfaceCensus` gains, per store, the current
purgeability read with `kIOSurfacePurgeableKeepCurrent`
(`IOSurfaceRef.h:447`), and the census reports counts by state plus the
bytes of the non-volatile stores. Derived at read time, so it stays inside
`D4`. This is `T8` commit 2 scope: without it `T9` cannot attribute a
volatile saving with the app's own number.

#### Behavioral verification for `T8`

Headless, `lib/TerminalCore` `FrameSwapchainTests`, driving the injected
in-use and purgeability seams:

- `releasePixels` marks volatile exactly the buffers that are detached and
  reported free; a buffer reported in use stays non-volatile; the return
  value is the count left.
- a second `releasePixels` after the in-use buffer frees marks it and
  returns zero.
- while pixels are released, `publish` and `retryPendingPresentation` return
  nil, write nothing, and keep the plan pending; the first publish after an
  intact reclaim presents it.
- `reclaimPixels` returns true when every old state is `Volatile` or
  `NonVolatile`, false when any is `Empty` or the call fails.
- across release, intact reclaim, and rotation, every presented buffer equals
  a from-scratch render (extend the existing rotation gate).

`tests-ui`, `SwiftTerminalSessionViewTests` (the session view needs AppKit;
there is no headless app-test seam for it):

- hide detaches: after `setVisible(false)` the layer's contents is nil and
  the census reports the pane hidden; commit 2: the free stores volatile.
- a hidden pane keeps consuming PTY output, and reveal presents the current
  state: exactly one render on reveal, and its plan holds the hidden-time
  output, not the frame from hide.
- a hide with an armed retry: the retry fires while hidden and
  `renderCountForTesting` does not move; the reveal renders once.
- theme, font, backing scale, window color space, and grid changed while
  hidden: nothing renders while hidden, the reveal renders one correctly
  sized frame, and the swapchain was replaced (a `.rebuild` event, or a
  different census).
- a hidden resize followed by reveal rebuilds once, not twice.
- an untrusted reclaim (the recording surface returns false) replaces the
  swapchain and renders in full.
- closing a hidden pane releases everything: extend "a released pane is
  unreachable by every controller callback" so that a pixel-release retry
  armed before teardown fires after it and touches nothing.
- repeated hide/reveal across two tabs through `syncPaneVisibility` leaves
  only the visible pane's chain non-volatile in the census.

Real-AppKit pin, `tests-ui/IOSurfaceLayerContentsTests.swift`, pin four
(commit 2): a surface is attached to a composited layer, then detached with
`contents = nil` in a committed, flushed transaction while a *sibling* layer
in the same window keeps presenting frames. Assert, in order: the surface is
still in use immediately after the flush (the `F8` fact the deferred check
exists for); it reports free within the frame budget of sibling
presentations; `setPurgeable(.purgeableVolatile)` succeeds while free;
through another frame budget of sibling presentations it is never reported
in use again; `setPurgeable` back to non-volatile returns `Volatile`; the
fill byte written before attach is still there. If the second assertion
never holds -- the surface does not free while its own layer presents
nothing -- that is uncertainty 1 answered "never", the pin records it, and
the deferred check is dropped rather than tuned. Pin two's rule stands
unchanged: a free surface stays free is the premise both writing and
volatility rest on.

#### Decision-bearing measurements for `T9`

- The tier-2 pair (`D3`): the pre-change commit against the landed change,
  both arms, one session, after `T2b`'s A/A pair exists. Two rows for the
  landed change if commit 2 lands: commit 1 alone and commit 1 + 2, so the
  fast path's bytes are its own.
- `surfaces` census: mapped bytes will read 607,518,720 in every arm and
  must not be cited as the saving. Report the new per-state counts and the
  non-volatile bytes; the expectation at idle is 3 non-volatile stores for
  the visible pane plus 0 to 9 residual in-use stores, and 27 to 18 volatile.
  The residual count is uncertainty 1's number.
- Reveal latency, `tab-switch-latency.py`, `F5`'s table again: the intact
  path is expected near `F8`'s 1.37 ms; commit 1 alone is expected near the
  rebuild row. Both are reported beside the bytes.
- The discard path: stage, then `memory_pressure -l critical` until `vmmap`
  shows the hidden surfaces `PURGE=E`, then reveal. Read the per-buffer
  `revealDiscarded` count, the reveal-to-attach latency, and confirm on
  screen that the revealed pane is correct. This is the one path no reading
  has taken.
- The deferred check: per hide, the tick at which the ex-attached surface
  freed, or that the budget expired. This sets the budget or deletes the
  retry.

#### Open uncertainties

1. Does the render server free a hidden layer's ex-attached surface at all,
   and when: never while that layer presents nothing, after the sibling
   tab's reveal frame, or after some number of window commits? Decides the
   residual (0 to 182 MB at this staging) and whether the deferred check
   exists. Resolved by pin four and the `T8` trace tick count.
2. Whether a discarded buffer's reveal is as cheap as a rebuild less the
   allocation, and whether the discard path is correct on screen.
   Resolved by the `memory_pressure` reading in `T9`.
3. Whether the kernel returns volatile pages to the machine before pressure,
   or only stops charging them. `F8` measured the charge, not the physical
   pages. Resolved by `footprint`'s reclaimable line against system free
   memory in the `T9` session; it does not change the decision, only how the
   win is worded.
4. What a window thumbnail, Mission Control, or the app switcher shows for
   an occluded window whose panes are detached: theme background until the
   reveal renders, which is one commit later. Not undefined pixels -- that is
   impossible under the in-use rule -- but blank. Resolved by a manual check
   in `T8`; if it matters, the fallback is to push occlusion as a planning
   gate only and let tab visibility alone drive detachment, which is a
   one-line split in `syncPaneVisibility`.
5. Whether `contents = nil` on a layer whose container is already `isHidden`
   commits a presentation at all, and so whether the flush in hide step 2
   gives the render server the detach before the in-use read. `F8` shows the
   read is "in use" either way, so the deferred check covers it; pin four
   settles it.

### D3 -- the instrument is termwars' reading of one staged slot

- Status: **settled**.
- Evidence used: `agent-docs/terminal-performance.md`, "Profile memory":
  `terminal-memory-probe` is headless and cannot allocate the surfaces `F2`
  attributes; `benchmark-memory` is a leak detector that once reported a
  fixed build as larger than a leaky one because IOSurface churn was twice the
  effect (`15/F6`). termwars' `danterm_footprint` and its memory harness read
  `phys_footprint` over the slot bundle's pid set, which is the number the
  chart and Activity Monitor show, and the slot guard refuses any bundle that
  might be the app in use.
- Candidate solutions considered:
  - Extend `benchmark-memory` with a ten-tab workload. Rejected: it samples a
    sawtooth and brackets with memory graphs that suspend the target; its
    design question is growth, not level.
  - A new in-repo GUI harness. Rejected: it would duplicate the adapter
    termwars already calibrated (window geometry for 170x60 at Menlo 13,
    focus-once staging, grid readback) and split the receipts across two
    repos.
  - Two tiers over termwars' code: a scripted spot reading for the edit loop
    and the full harness for a series row. Selected.
- Tradeoffs and correctness risks: the instrument lives in another checkout
  at `~/Code/termwars`, so a series row names the receipt file by path and
  the reading is not reproducible from this repo alone. Tier 2 is GUI-driving
  and cannot run in the gate; the series is written by a person choosing the
  moment. Tier 1 runs at whatever grid the slot window gives, which is why it
  records the grid and makes no claim.
- Decision and rationale: a claim is a tier-2 pair in `series.md`; a tier-1
  reading steers the work and is written under the ledger task, never in the
  series.

### D4 -- the app's surface attribution is derived, never counted

- Status: **settled**; implemented as `danterm debug surfaces` (`T1`), first
  read at `S3`. It shipped as the bare verb `danterm surfaces` and moved under
  the `debug` namespace, which holds diagnostic reads: this reports internal
  state for an investigation and is not a control. `T11`'s per-pane terminal
  census will join it as `debug memory`.
- Evidence used: `D1` (attribution explains, the total decides), `F4` (the
  `vmmap` IOSurface class is page-rounded, so an arithmetic byte figure cannot
  be reconciled to the tool that decides), and
  `agent-docs/measurement-discipline.md` (zero must stay distinguishable from
  unmeasured).
- Candidate solutions considered:
  - A process-wide registry of live swapchains in `TerminalRenderExecution`,
    with weak references so a released chain drops out. Rejected: it is a
    second structure every producer must register into, it cannot attribute a
    surface to a pane or to a visibility state, and the one case it would catch
    that a walk does not -- a chain held by a leaked view -- is the case `D1`
    assigns to `vmmap`, not to an in-app number.
  - A frame-rate-log line. Rejected: that sampler is per pane, env-gated at view
    creation, and emits only for a window with activity, so an idle hidden pane
    -- the very thing this doc counts -- writes nothing.
  - A walk, at read time, over the runtime's live pane sessions, each session
    asking its own rotation. Selected.
- Tradeoffs and correctness risks: the walk sees only surfaces reachable from
  an installed pane, so a leak outside that table is invisible here and stays
  `vmmap`'s job. `allocationSize` is mapped size, not resident pages, so after
  a change that drops the eager clear (`T5`) or marks pages volatile (`T6`) this
  number and `phys_footprint` diverge by design -- which is what it is for.
- Decision and rationale: nothing increments on create or decrements on
  release, so nothing can drift; the byte source is each surface's
  `allocationSize`, the page-rounded figure a `vmmap` line sums; a session that
  cannot answer returns nil, which is reported as `unmeasured` and left out of
  every sum, so a pane that was not measured can never read as a pane holding
  nothing.

### D5 -- the volatile fast path comes out; the ideal ships alone

- Status: **settled** (2026-09-01, on `F9`); reverts `T8` commit 2
  (`471e8c01`) in `3c5dfef6`. `T8` commit 1 (`8ccdec4d`), which is `D2`'s
  ideal (a), is the shipped shape.
- Evidence used: `F9` (both arms in one session -- 56,902,928 bytes with the
  fast path against 56,935,312 without it, a 32,384-byte difference that is
  0.06% of either total and inside both spreads; reveal to frame 4.76 ms
  against 4.61 ms, the same number within either spread; the residual is 0
  surfaces, so the two shapes have nothing left to differ about at idle),
  `F8` (the fast path's whole case: 1.37 ms against a 6.32 ms rebuild),
  `F5` (the rebuild that case was priced against: 16.59 ms median, 43 ms
  tail), `F7`/`T5` (what changed the price), and `D2`'s own closing
  paragraph, which pre-committed to this outcome: "if commit 2's measurement
  (`T9`) shows the deferred check never succeeds or its state does not earn
  its latency, dropping commit 2 leaves the ideal in the tree".
- **Why the premise failed, and it is not that the measurement was wrong.**
  `F8`'s 4.6x was real on the tree it was taken on. It priced a volatile
  reveal against a from-scratch rebuild that still `memset` three whole
  surfaces on creation. `T5` then removed that clear, and the rebuild the
  ideal actually pays in the tree it ships in costs 4.6 ms, not 16.59. The
  fast path was buying back a cost that no longer exists. What is left in
  both arms is the one full render a reveal must do either way, and no
  structure inside the swapchain can remove that.
- Candidate solutions considered:
  - Keep commit 2 and tune it. Rejected: there is nothing to tune. The
    deferred check already succeeds in 1 to 3 ticks, the budget never
    expires, and the outcome it produces is a reveal indistinguishable from
    the one without it.
  - Keep commit 2 for the bytes. Rejected by `D1`: 0.06% did not move the
    total, and `F9`'s own census says both arms charge the process for
    exactly the visible pane's three buffers.
  - Keep the census fields alone, drop the mechanism. Rejected: with no
    volatile buffer in the tree, `nonVolatileStores` / `volatileStores` /
    `emptyStores` / `unknownStores` / `nonVolatileBytes` report a constant,
    and a census field that cannot vary is a `D4` violation dressed as
    attribution. `bytes` is already the mapped figure `vmmap` sums, and under
    commit 1 a hidden pane has no rotation to report at all, which is the
    stronger statement.
  - Revert commit 2 entirely and ship `D2`'s ideal. Selected.
- **What was given up.** One unmeasured upside: the discard path. `F9` took
  no `memory_pressure` reading, so nobody has seen what a reveal costs after
  the kernel dropped the pages, and the fast path's degraded case was
  designed to be exactly the ideal's normal case anyway -- so the loss there
  is bounded by construction, not by measurement. The real exposure is that
  the ideal's price is the rebuild, and the rebuild is machine- and
  grid-dependent. `F9` read it at one geometry (170x60) on one machine. A
  slower machine, a much larger grid, or a change that puts allocation cost
  back into swapchain creation would make the rebuild expensive again, and
  then the fast path's case returns intact. `471e8c01` is in the history with
  its tests, so it can be brought back rather than rebuilt.
- **What reopens it.** A reveal-to-frame median above **8 ms** on the tier-1
  staging (`tab-switch-latency.py`, `F5`'s table). Two reasons for that
  number, not one. It is about one refresh interval at 120 Hz (8.33 ms), so
  it is where a reveal stops fitting in the frame it was asked for and a
  person can see the delay. And it is twice what is recoverable today:
  `F8`'s 1.37 ms is the floor a kept-pages reveal can reach, so at `F9`'s
  4.6 ms median the fast path could return at most 3.3 ms, which it did not;
  at 8 ms it could return 6.6 ms, which is worth one purgeability state per
  buffer, a bounded retry, and a three-way reclaim outcome. Below 8 ms the
  answer stays no on the same arithmetic that produced this decision.
- Tradeoffs and correctness risks: none new. Commit 1 holds `D2`'s two
  properties on its own -- a hidden pane owns no pixels, so nothing of its
  can be resident, volatile, or undefined -- and it adds no premise beyond
  the one the swapchain already had. `D2`'s uncertainty 1 stays answered:
  the render server does free the ex-attached surface, which is what makes
  commit 1's residual 0, and pin four in
  `tests-ui/IOSurfaceLayerContentsTests.swift` keeps that half. The
  purgeable half of pin four went with the code it gated.
- Decision and rationale: the fast path spent structure to buy a latency the
  tree no longer pays. `D2` said what to do when the measurement came back
  this way, and this is that. `T9` still owes the tier-2 pair, and it now
  has one arm to take rather than two.
