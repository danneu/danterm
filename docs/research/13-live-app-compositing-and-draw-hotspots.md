# Live-app compositing and draw hotspots under interactive scroll

Research started: 2026-07-28. **Status: Phase 1 closed (F5, F6). Phase 2 closed
and measured: R1+R1b (F7, H1 closed), R2 (F8, H2 closed), R4 (F9). Phase 3's
gate is now open -- what it wants first is the F10 re-capture, which needs the
user.**

## Purpose

This file owns the hotspots that appear only when the **real app** is profiled
under **real user input**, and that the headless and harness instruments
structurally cannot see.

It exists because the profile that opened it named three costs that no existing
instrument could have produced:

1. a **secondary CoreAnimation thread** (`CA::CG::Queue`) doing 1,316 samples of
   glyph and rect work -- `just benchmark-draw` renders into an offscreen bitmap
   and never creates this queue at all;
2. the main thread **blocking ~1,065 samples** inside
   `CABackingStoreGetFrontTexture` waiting on that queue -- doc 11 F1's own
   caveat says its absolute figure "omits whatever compositing costs the window
   server adds", and this is that cost, measured; and
3. a per-run `[NSAttributedString.Key: Any]` dictionary in `drawTextRuns` that
   costs **as much as all the glyph drawing** and that doc 9's four synthetic
   profiles did not name.

Scope split from the four adjacent files:

| Question | Owned by |
| --- | --- |
| `Terminal.feed` cost | doc 10 (**closed**) |
| Per-cell / per-draw allocation inside `planFrame` and `drawRenderFrame` | doc 9 |
| Does the draw path fit the frame budget; optimize-or-replace | doc 11 |
| What a cell costs in bytes, moves, and refcount traffic | doc 12 |
| **What live compositing and real-input profiling reveal that the above cannot** | **this file** |

The distinction from doc 11 is the instrument, not the question. Doc 11 asks
whether the draw *number* is small enough and gates on doc 9's backlog before
deciding. This file supplies live evidence that doc 11's Phase 1 explicitly
lacks -- an app profile at real geometry on a redraw-shaped workload -- and hands
doc 11 two of its unchecked tasks' worth of data. The distinction from doc 9 is
that doc 9's evidence base is four samples of the *synthetic churn harness* with
`DANTERM_BENCHMARK_PROFILING=1` active; this profile has no observer in it.

The boundary with doc 12 is the one most likely to blur, because doc 12 owns
**reference-counting traffic** and this file's R2 removes some. The split: doc 12
owns what a *cell* costs and whether its representation should change; R2 is a
single mis-resolved `Optional` comparison that copies a struct which happens to
hold `rows: [GridRow]`. It is a call-site bug, not a representation question, and
fixing it neither depends on nor forecloses anything doc 12 decides. If doc 12
concludes the row array should change shape, R2 is unaffected -- it stops copying
the array either way. **R2 stays here.**

Nothing here supersedes doc 9, 11, or 12. Where this profile disagrees with
theirs, the disagreement is recorded as a workload difference (F4), not a
correction.

## Investigation rules

Inherited from docs 9-11, because they were earned there:

- **Sample shares are attribution, not timings.** Name the inclusive root and the
  artifact. Nothing in this file is a benchmark result.
- **A directional claim uses `benchmark-quick` / `benchmark-confirm` against an
  explicitly named pre-change revision**, per
  [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md).
- **Verify a change on a workload that can see it.** `terminal-feed` and
  `scrollback-stream` cannot see draw work; `content-churn` and `style-churn`
  cannot see feed work (`10/F9`).
- **Never quote a draw cost without its geometry and its scenario** (`11`, F1).
- **An attribution can be wrong even when its measurement is right** (`10/F8`
  correcting `10/F4`). An experiment excludes only what it actually varied.

Three rules specific to this file:

- ~~**This is a one-sample profile.**~~ **Satisfied 2026-07-28.** Doc 9's
  standing rule is two profiles before a stack is treated as stable; F6 records
  the repeat, and every load-bearing node reproduced within a few percent. Shares
  below are no longer provisional on this ground. The rule stays visible rather
  than deleted because it is what forced the repeat, and the repeat is what
  turned up the 720-versus-1,064 correction in F1.
- **A live capture must record the human gesture.** The workload here is a person
  holding a key. The gesture, the target program, and its geometry are part of
  the provenance; a profile without them is not reproducible and not comparable.
- **Every live capture is a hard stop: pause and ask the user to run it.** An
  agent cannot produce this evidence alone -- the workload is a human holding a
  key in a focused GUI window, and no scripted driver exists. When a task needs a
  capture, stop, give the user the exact `sample` command and the gesture, and
  wait. Do not synthesize the input with `osascript`, `cliclick`, or a key-repeat
  script to avoid asking: that silently substitutes a different workload for the
  one every finding in this file was measured on, and the substitution would not
  be visible in the resulting profile. Do not proceed on the previous capture as
  though it were the new one, and never write a number a capture has not
  produced. The user has been willing; asking costs one message.
- **Do not land two *separately measurable* candidates in the same function
  without measuring between them.** R1 and R4 both edit `drawTextRuns`. Landing
  them together destroys both attributions and repeats exactly what doc 9's
  re-post rule exists to prevent. The qualifier is load-bearing: R1b also edits
  `drawTextRuns` and is deliberately exempt, because at 19 samples no benchmark
  run can separate it from R1 anyway, so there is no attribution to lose. The
  test for exemption is "would a separate measurement resolve it?", not "is it
  small?" -- and an exempt change still owes a broken-out node in the re-posted
  tree.

## Trigger and current evidence

One diagnostic sample profile, collected 2026-07-28.

| Field | Value |
| --- | --- |
| Artifact | `.build/manual-profiles/2026-07-28-113733-72198-btop-scroll.txt` (1.6 MB) |
| Original capture path | `/tmp/danterm-btop-sample.txt` |
| Sampled binary | `~/Applications/DanTerm Dev.app`, built 2026-07-28 10:58 |
| Build configuration | **optimized** (`just build-optimized`; the install is a re-signed copy of `.spm-build/release/DanTerm`, mtime 10:58) |
| Source commit | **`4ca27ee`** ("perf(terminal): carry one damage snapshot per feed action", 10:55:58). The next commit, `4de86b6`, is 11:02 -- after the build. |
| Instrumentation | **none.** No `DANTERM_BENCHMARK_PROFILING`, no benchmark observer, no fixture harness. |
| Process | pid 72198, launched 10:58:33, sampled 11:37:33 (~39 min uptime) |
| OS | macOS 26.5.2 (25F84), ARM64 |
| Footprint | 116.2 MB, peak 191.9 MB |

Command:

```
sample "$(pgrep -a -x 'DanTerm Dev')" 20 -mayDie -fullPaths \
    -file /tmp/danterm-btop-sample.txt
```

**The gesture, which is part of the evidence.** For the duration of the capture a
person **held the down-arrow key** to scroll the process list of `btop` running
in a DanTerm pane. This drives, on repeat: PTY output of a redrawn panel, damage
generation, a frame plan, and a full compositing cycle -- at DanTerm's real
window geometry rather than a fixture grid. It is the closest thing this project
has to the redraw-shaped, real-geometry workload doc 11's Phase 1 asks for and
does not have.

**Caveat on the gesture:** it is human, so its rate is neither constant nor
reproducible to better than roughly its own magnitude. This artifact can support
*attribution* (which node is large) and it cannot support *comparison* (whether a
node got smaller). Comparison stays with the named instruments in D1.

A **second capture** of the same process under the same gesture was taken at
12:16:29 and is recorded in F6, with its own artifact
(`.build/manual-profiles/2026-07-28-121629-72198-btop-scroll-run2.txt`) and one
extra caveat: an unrelated benchmark was running in another process at the time.

`.build/` is disposable, so the artifact paths are pointers only; every
decision-bearing number is transcribed into F1-F6 below.

### Thread census

17,003 samples on the main thread at a 1 ms nominal interval, so a ~17 s window
against the 20 s requested; the remainder is sampler overhead. Four threads did
work. `Thread_38406245`, `Thread_38415403`, `Thread_38396749` and
`Thread_38415067` total 47,756 samples of idle `__workq_kernreturn` worker
parking and are excluded everywhere below.

| Thread | Samples | Busy | Share of process busy |
| --- | ---: | ---: | ---: |
| Main | 17,003 | **4,256** (12,747 idle in `mach_msg`) | 65% |
| `CA::CG::Queue` (CoreAnimation CG replay) | 1,316 | 1,316 | 20% |
| `com.danneu.danterm.terminal-pty-host` | 831 | 831 | 13% |
| CA mtl submission / completion / misc | ~150 | ~150 | 2% |

Process busy ≈ 6,550 samples over ~17 s ≈ **38% of one core**.

One qualification that matters for every share that follows: **1,064 of the main
thread's 4,256 "busy" samples are not CPU.** They are `kevent_id`, blocked
(corrected from 720 -- see F1's correction note). True main-thread CPU is roughly
**3,192**, so a quarter of what looks like main-thread work is a wait. Shares
below are stated against the 4,256 figure and flagged where the distinction
changes the reading.

Run 2 (F6) reads 16,819 main-thread samples, 12,296 idle, **4,523 busy**, with
1,065 blocked. Both runs are tabulated side by side in F6.

## Reproducing the evidence

Everything below was derived by hand in a chat session. None of it is wired into
a script in the repo, so a fresh agent starting cold would otherwise re-derive it
-- and one of the derivations has a trap that already produced a wrong number
once (F1's correction). This section exists so that does not happen twice.

### Re-capturing a live profile

**Stop here and ask the user.** This is the one step in the investigation an
agent cannot perform: it needs a person holding a key in a focused GUI window,
and no scripted driver exists (Phase 4 owns whether to build one). Hand over the
command and the gesture and wait for the artifact. Both existing captures were
produced this way and the user has been willing.

Ask for exactly this, incrementing `N`:

```
sample "$(pgrep -a -x 'DanTerm Dev')" 20 -mayDie -fullPaths \
    -file /tmp/danterm-btop-sample-N.txt
```

> While it runs, hold the **down-arrow** key to scroll `btop`'s process list in a
> DanTerm pane, at the window's normal size, for the full 20 seconds.

Also ask whether anything else heavy was running -- run 2 was taken with an
unrelated benchmark active, which moved the idle/busy split and left the shares
alone (F6). That caveat only exists because the user volunteered it.

**Do not** substitute `osascript`, `cliclick`, or a key-repeat script for the
human. It would silently measure a different workload than every finding here was
measured on, and nothing in the resulting profile would reveal the substitution.

Then record, in the finding:

- pid and **launch time** from the sample header -- if launch time matches an
  earlier capture, it is the same process instance and therefore the same binary,
  which is much stronger provenance than a commit hash;
- the binary's build configuration. `~/Applications/DanTerm Dev.app` is a
  re-signed copy of `.spm-build/{debug,release}/DanTerm`; compare mtimes to tell
  which, since `just build` and `just build-optimized` both install to the same
  path. Do not assume debug -- both captures here were **optimized**;
- the source commit, inferred by comparing the binary's mtime against
  `git log --format='%h %ci'`;
- **anything else running on the machine.** Run 2 was taken with an unrelated
  benchmark active; it moved the idle/busy split and left the shares alone.

Copy the artifact somewhere before `/tmp` is cleared. This file uses
`.build/manual-profiles/`, which is an ad-hoc directory created for it, not a
project convention -- `.build/` is gitignored and disposable, so transcribe every
decision-bearing number into a finding.

### Analyzing a `sample` text file

`sample` prints an indented call tree where **each node's number is already
inclusive** of its subtree. Two derived quantities are wanted, and they are not
the same:

```python
import re, collections

def load(path):
    """Rows of (indent_depth, inclusive_count, frame_text) from the call-graph section."""
    lines = open(path).read().split('\n')
    end = lines.index('Total number in stack (recursive counted multiple, when >=5):')
    rows = []
    for line in lines[22:end]:          # 22 skips the header block
        m = re.match(r'^([ +!:|]*)(\d+) (.*)$', line)
        if m:
            rows.append((len(m.group(1)), int(m.group(2)), m.group(3)))
    return rows

def inclusive(rows, thread_substring=None):
    """Inclusive samples per function, optionally restricted to one thread.

    A function appearing at several call sites is summed; a function appearing
    inside its OWN subtree (recursion) is counted once, which is what the
    ancestor check is for. Without it, recursive frames like
    CA::Layer::collect_layers_ inflate by an order of magnitude."""
    total, stack, current = collections.Counter(), [], ''
    for depth, count, frame in rows:
        name = frame.split('  (in ')[0]
        while stack and stack[-1][0] >= depth:
            stack.pop()
        if depth <= 4 and 'Thread' in name:
            current = name
        if thread_substring is None or thread_substring in current:
            if name not in {s[1] for s in stack}:
                total[name] += count
        stack.append((depth, name))
    return total
```

Thread names to pass as `thread_substring`: `'Main Thread'`,
`'terminal-pty-host'`, `'CA::CG::Queue'`.

**The trap that produced F1's correction.** A single function is usually printed
as *several sibling nodes* at different instruction offsets
(`CABackingStoreGetFrontTexture + 128`, `+ 240`, `+ 748`, ...). Reading the one
node that happens to be visible in an excerpt gives a number that is real but
partial: `+ 128` carries 723 samples while the function carries 1,079. To ask
"how much of X is spent in Y", sum Y across the *whole* subtree of every X node:

```python
def subtree_leaf(path, root_substring, leaf_substring):
    """(total samples under all `root` nodes, samples of `leaf` anywhere beneath them)."""
    rows, root_depth, root_total, leaf_total = load(path), None, 0, 0
    for depth, count, frame in rows:
        name = frame.split('  (in ')[0]
        if root_depth is not None and depth <= root_depth:
            root_depth = None
        if root_substring in name and root_depth is None:
            root_depth, root_total = depth, root_total + count
            continue
        if root_depth is not None and leaf_substring in name:
            leaf_total += count
    return root_total, leaf_total

# The blocked-wait figure, the one that was wrong:
#   subtree_leaf(path, 'CABackingStoreGetFrontTexture', 'kevent_id') -> (1079, 1064)
```

Per-source-line attribution inside one Swift function -- how F2's table was
built -- comes from the `/path/File.swift:NNN` suffix `-fullPaths` puts on
DanTerm frames:

```python
agg = collections.Counter()
for depth, count, frame in load(path):
    if 'drawTextRuns' in frame and 'DanTerm Dev' in frame:
        m = re.search(r'TerminalRenderExecution\.swift:(\d+)', frame)
        agg[m.group(1) if m else 'other'] += count
```

Note this sums *nodes*, so it double-counts nested frames and its total (2,085
in run 1) exceeds the function's inclusive figure (1,970). It is valid for
**shares within the function** and must not be quoted as an absolute.

### Reproducing F5's fixture probe

Drop this in `lib/TerminalCore/Tests/TerminalDrawBenchmarkSupportTests/`, run it,
delete it. It needs no new dependencies -- that test target already has the three
imports.

```swift
import TerminalCore
import TerminalRenderPlanning
import Testing
@testable import TerminalDrawBenchmarkSupport

@Suite("ZZ fixture shape probe")
struct ZZFixtureShapeProbe {
    // Coarse ranges only, mirroring the switch in drawTextRuns. This OVER-counts
    // sprites: a coarse-routed scalar whose family returns nil still falls
    // through to the font path. For the fixture's 12 glyphs it happens not to
    // matter -- all three families are total over their ranges (see F5).
    static let spriteRanges: [ClosedRange<UInt32>] = [
        0x2500...0x257F, 0x2580...0x259F, 0x25E2...0x25FF, 0x2800...0x28FF,
        0xE0B0...0xE0D4, 0xF5D0...0xF60D, 0x1FB00...0x1FBEF, 0x1CC1B...0x1CEAF,
    ]

    @Test("probe: run density and font-path fraction")
    func probe() throws {
        for grid in DrawBenchmarkGrid.standard {
            let plan = try #require(makeBtopShapedPlan(for: grid))
            var cells = 0, sprite = 0, font = 0, multi = 0
            for run in plan.textRuns {
                for cell in run.cells {
                    cells += 1
                    let scalars = Array(cell.scalars)
                    guard scalars.count == 1, let s = scalars.first else { multi += 1; continue }
                    if Self.spriteRanges.contains(where: { $0.contains(s.value) }) { sprite += 1 }
                    else if s.value <= UInt32(UInt16.max) { font += 1 }
                }
            }
            print("\(grid.columns)x\(grid.rows): runs \(plan.textRuns.count) cells \(cells) "
                + "sprite \(sprite) font \(font) multi \(multi)")
        }
    }
}
```

Run it with the **type** name, not the suite display name:

```
swift test --package-path lib/TerminalCore --filter ZZFixtureShapeProbe
```

`--filter "ZZ fixture shape probe"` matches nothing and exits 0 with "No matching
test cases were run" -- a silent no-op that reads like a pass.

### Instruments, and what is known about each

| Instrument | Invocation | Headless? | Status here |
| --- | --- | --- | --- |
| `benchmark-draw` | `just benchmark-draw [iterations=15]` | yes -- `swift run -c release`, offscreen bitmap | **run: F7, F9.** Doc 11 F1 reports ±2.5% over 15 iterations; F7's four scenarios each moved 25-34% and F9's 3-9%, both outside that. Primary instrument for R1/R1b/R4 -- but F9 shows it is only a *mechanism* check for changes touching the glyph or fallback paths, which F5's fixture never executes. |
| `benchmark-headless-draw` | `just benchmark-headless-draw <rounds> [candidate-core-path]` | yes | not run. Interleaves two checkouts in one process; use for an A/B that avoids cross-run drift. |
| `benchmark-quick` | `just benchmark-quick <baseline-rev> <workload>` | **yes, in practice** | **run: F7, F9** (`content-churn` both times), from an agent shell with no GUI interaction. The "plausibly needs a GUI session" caveat recorded here is answered: it does not. ~157 s per workload cold; a repeat against the same pair of revisions reuses the arm cache and costs ~14 s, which is what makes a replicate pair set cheap (F9). |
| `benchmark-confirm` | `just benchmark-confirm <baseline-rev>` | same as above | **run: F8.** Runs the full five-workload ladder. |
| `benchmark-draw-app` | `just benchmark-draw-app` | needs AppKit | not run. Real draw path but not sampled at the compositor. |
| live `sample` | above | needs a human | **run three times** -- F1, F6, F7. |

Workload names for `benchmark-quick`: `terminal-feed`, `scrollback-stream`,
`content-churn`, `style-churn`, `incremental-mixed`. Canonical geometry is
179x66, matching this file's captures.

**Superseded 2026-07-28.** This paragraph read "No benchmark has been run in this
investigation... D1's predictions are all unverified." Two have since been
verified against baselines resolved before implementation: R2 (F8) and R1+R1b
(F7). **R4 is now verified too (F9)**, leaving R3 -- which is research only and
has no instrument. Every *sample-derived* share in this file is still a
diagnostic share rather than a performance result.

## Current hypotheses

### H1 -- the per-run attributes dictionary is the single largest removable cost on the draw path

`TerminalRenderExecution.swift:367` builds a `[NSAttributedString.Key: Any]`
literal for **every run**, unconditionally. It is read at exactly one place --
line 588, inside the `for fallback in fallbackCells` loop -- which is empty for
the overwhelming majority of runs, because a run only produces fallback cells for
multi-scalar clusters, scalars above `UInt16.max`, or glyphs the font does not
map.

Lines 367-370 carry **382 of `drawTextRuns`' 2,085 node samples (18.3%)**, which
is within noise of `CTFontDrawGlyphs` itself at 372 (F2). The cost is
`Dictionary.init(dictionaryLiteral:)` → `__RawDictionaryStorage.find` →
`String.hash(into:)` → `Hasher.combine(bytes:)`: three `NSAttributedString.Key`
values, string-hashed, into a fresh allocation, per run.

Supporting evidence: F2, and the fact that the consumer is textually one loop
away and provably conditional.

Competing explanation: the 18.3% share is a property of btop's output shape --
short, heavily-colored runs mean many runs per row and therefore many
dictionaries per frame. A workload with long uniform runs would show a much
smaller share, and `benchmark-draw`'s fixture may be such a workload.

Confirmed if `just benchmark-draw` moves the full-frame figure by more than 10%
after the dictionary is made lazy. Rejected, and the competing explanation
adopted, if it moves less than 5% -- in which case the correct follow-up is to
count runs per frame in the fixture versus in real btop output, not to abandon
the change.

**Status: CONFIRMED and closed 2026-07-28 (F7).** The stated threshold was
cleared three times over: full-frame **-33.9%** at 80x24 and **-31.2%** at
160x50 against baseline `fcfff10`. The live re-capture (run 3) shows the
literal's node at **1 sample (0.1%)** of `drawTextRuns`, down from 382 (18.3%),
so the cost was removed rather than relocated. The competing btop-shape
explanation is not refuted and does not need to be -- it governs which number
transfers to real use, and F7 keeps 18.3% as that number. What the overshoot
does raise is the mirror-image question: the fixture may be *more* dictionary-
dense than live btop, which is the same run-density count the rejection branch
asked for, now motivated by a confirmation instead.

### H2 -- `damageActionSnapshot` pays a full array-bearing struct copy twice per stream action, to test a pointer against nil

`Terminal.swift:553` and `:565` both test `inactivePrimaryScreen` against `nil`.
`InactivePrimaryScreen` is `Equatable` (`Terminal.swift:328`), so Swift resolves
those to the generic `Optional.==(Wrapped?, Wrapped?)` overload rather than the
cheap `_OptionalNilComparisonType` one. That overload takes both operands by
copy, and the struct holds `rows: [GridRow]` -- so each comparison retains and
releases the entire row array.

The profile shows this directly and unambiguously: **187 samples in `outlined
destroy of (Terminal.InactivePrimaryScreen?, Terminal.InactivePrimaryScreen?)`**
-- a *two-element tuple of optionals*, a shape that can only be produced by a
two-argument comparison -- reached from `Terminal.damageActionSnapshot.getter` at
two distinct call-site offsets (`+144` and `+396`), matching the two source lines
exactly (F3).

That is **~22.5% of the entire PTY thread** and ~25% of `Terminal.feed`, on a
snapshot that `4ca27ee` had just finished halving the *call count* of. This
halves the remaining *per-call* cost, and the two compose.

Supporting evidence: F3.

Competing explanation: the destroy could be the getter tearing down its own
local, not a comparison temporary. The tuple arity refutes this -- a local would
destroy as a single optional, not a pair -- but the refutation is a reading of a
mangled symbol, not an experiment. The experiment that settles it is the change
itself.

Confirmed if `just benchmark-quick 4ca27ee terminal-feed` reads faster and the
tuple-destroy node is absent from a re-post of the PTY tree.

**Status: CONFIRMED and closed 2026-07-28 (F8).** Both conditions met, the
second by a stronger instrument than the one written here. Absence was shown by
diffing release-built `Terminal.swift.o` at the baseline and after -- the
`outlined destroy of (InactivePrimaryScreen?, InactivePrimaryScreen?)` symbol is
gone from the *binary*, which entails its absence from any tree without needing
a live capture to sample it. The competing "getter tearing down its own local"
explanation is dead: removing the comparisons removed the symbol, so the
comparisons were what produced it. The feed leg read `terminal-feed` -6.61%
(`benchmark-confirm`, baseline `20a6eaf`) -- faster as required, though below
D1's predicted -8% to -15%; see F8 for why the magnitude is the weaker half of
this result.

### H3 -- the main thread's largest single stall is waiting on CoreAnimation's glyph-bounds computation, and the bounds are computed by copying glyph outlines

`CABackingStoreGetFrontTexture` is 1,079 main-thread samples, of which **1,064
(98.6%) are `_dispatch_sync_f_slow` → `__DISPATCH_WAIT_FOR_QUEUE__` →
`kevent_id`**: the main thread synchronously waiting on `CA::CG::Queue` to finish
replaying the previous display list (F1). Run 2 reads 1,068 and 1,065 (99.7%).
The node is not *mostly* a wait -- it is *essentially entirely* a wait.

What that queue spends its time on is specific and surprising: **547 of its 1,211
`DrawOp::render` samples are `DrawGlyphs::compute_dod_`** -- dirty-of-drawing --
which descends `get_glyph_bboxes` → `FPFontGetGlyphIdealBounds` →
`TFPFont::CopyGlyphPath` → `TGlyphOutlineDictionaryCache<unsigned short, 64,
512>::Copy` at **424 samples**. CoreText is **copying glyph outline paths purely
to compute bounding boxes**, and missing a 64-entry outline cache while doing it
(F1).

So the largest main-thread stall and the largest secondary-thread cost are the
same phenomenon seen from two ends, and it sits on the critical path twice.

Supporting evidence: F1.

Competing explanations, and there are two credible ones:

- The stall is a **pipeline**, not pure waste. Some of those 1,064 samples would be
  spent waiting regardless; shortening the queue shortens the wait but cannot
  remove it. The recoverable fraction is unknown and this profile cannot bound
  it.
- The outline-cache miss may be an artifact of **btop's glyph inventory**
  specifically (heavy box-drawing and braille), not a general property. DanTerm
  sprites both of those families, so it is not yet established *which* glyphs
  reach `CTFontDrawGlyphs` at all in this capture.

Confirmed only by an experiment that changes the number of `DrawGlyphs` ops or
the distinct-glyph count per frame and shows both nodes moving together.
**No existing instrument can observe either node.**

### H4 -- the plan/draw ratio doc 9 measured is a property of the synthetic churn harness, not of real use

Doc 9's content-churn attribution is **plan 35.4% / draw 27.7%** of non-idle main
thread. This capture reads **plan 8.5% (362 samples) / draw 47% (1,986)** (F4).

The likely mechanism is not a contradiction but a workload difference:
`full-screen-content-churn` forces a full re-plan every frame by construction,
while btop damages panels and re-plans a fraction of the grid. If that is right,
both numbers are correct for their workload and neither generalizes -- which
would mean **doc 9's ranking of plan-side work above draw-side work is
workload-specific**, and doc 11's decision (which is entirely about draw) should
weight this capture more heavily than doc 9's.

Supporting evidence: F4.

Competing explanation: doc 9's profiles carried a `TerminalBenchmarkObserver` at
7.6% and ran a fixture producer; this one has neither. Some of the gap is
plausibly harness, not workload.

Confirmed if a `benchmark-sample` capture of `incremental-mixed` -- the least
full-screen of the harness workloads -- lands between the two ratios rather than
near doc 9's.

## Candidate direction, pending evidence

**Provisional. Ordered by (attributed size) x (confidence) / (risk), with the
sequencing constraint that R1 and R4 must not land together.**

The ranking, its justification, and its predictions are in D1. In summary:

| Rank | Change | Attributed size | Predicted effect | Instrument |
| --- | --- | --- | --- | --- |
| **R1** | Make the `attributes` dictionary lazy | 18.3% of draw | `benchmark-draw` full-frame **-13% to -18%** | `benchmark-draw`, then `benchmark-quick content-churn` |
| **R1b** | Stop writing the CGColor cache on a hit | ~0.9% of draw | folded into R1's measurement | same run as R1 |
| **R2** | Replace `inactivePrimaryScreen == nil` with a non-copying test | 22.5% of PTY thread | `terminal-feed` **-8% to -15%** | `benchmark-quick <base> terminal-feed` |
| **R3** | Attribute and attack the CA glyph-bounds thrash | 17% of main busy (stall) + 32% of CA queue | **unknown; research only** | none exists -- repeat this capture |
| **R4** | Scratch buffers / `reserveCapacity` in `drawTextRuns` | ~9% of draw | `benchmark-draw` full-frame **-3% to -6%** | `benchmark-draw`, after R1 |

**All four rankable candidates are now resolved: R1+R1b (F7), R2 (F8) and R4
(F9) are landed and measured; R3 stays research-only.** The predictions column
above is preserved as written -- see each finding for what was actually
measured.

R1 and R2 are independent paths measured by independent instruments and may be
worked in parallel. R1b rides along with R1 -- it is three lines away, too small
to measure on its own, and separating it would cost a benchmark run to resolve a
sub-1% effect. R4 waits on R1. R3 is not a change and must not become one before
Phase 3.

## Task ledger

### Phase 1 -- make the evidence trustworthy

- [x] **Repeat the capture.** **Done 2026-07-28: F6.** Same pid and launch time
      as run 1, so byte-identical binary at `4ca27ee`. Every load-bearing node
      reproduced within a few percent; the attributes share read 18.3% then
      19.3%, the tuple destroy 187 then 166, the blocked wait 1,064 then 1,065.
      An unrelated benchmark was running in another process during run 2 --
      recorded in F6, visible in the idle/busy split, absent from the shares.
      The re-analysis also caught a subtree-versus-node reading error in F1
      (720 → 1,064 blocked samples), corrected in place with a note.
      **Phase 2 is unblocked.**
- [x] Record what fraction of `drawTextRuns` runs actually produce a non-empty
      `fallbackCells`, in `benchmark-draw`'s fixture. **Done: F5.** The answer is
      zero, and the fixture turns out to be the maximum-run-density case rather
      than a low-density one, which **inverts** the risk R1 was originally
      recorded against. R1's prediction is revised in D1 on the strength of it.
- [ ] Do the same count against **real** btop output. F5 covers only the fixture.
      F2's 18.3% is the real-workload figure measured end to end, so this is
      wanted for the run-density comparison, not to rescue the prediction.
      Capturing btop's byte stream needs a PTY recording; judge whether that is
      worth building before doing it. **Partial answer, F7:** live run 3 puts
      `drawTextCell` at 4.0% of `drawTextRuns`, so the fraction is non-zero in
      real btop output -- unlike the fixture. That is a share, not the count this
      task wants, and it does not close it. F7's 2x overshoot makes the
      run-density half of this comparison more interesting, not less.
- [ ] Establish which glyphs reach `CTFontDrawGlyphs` in the **live** capture.
      H3's second competing explanation turns on it and nothing currently
      measures it. F5 answers this for the fixture (none do); the live case is
      still open. Record in F1.

### Phase 2 -- land the two low-risk candidates, separately

- [x] **R1, with R1b in the same commit.** **Done 2026-07-28: F7.** The
      dictionary moved inside `if fallbackCells.isEmpty == false` and the cache
      store into an explicit miss branch, in commit `919838f` against baseline
      `fcfff10` -- resolved and benchmarked before the first edit, not inferred
      afterwards. `benchmark-draw` full-frame **-33.9%** / **-31.2%**, roughly
      double D1's -13% to -18%; `benchmark-quick content-churn` -4.36%. Live
      run 3 breaks the two nodes out as required: R1's literal 382 (18.3%) -> 1
      (0.1%), R1b's store 19 (0.9%) -> 7 (0.4%). No `(fontVariant, colorKey)`
      cache was built -- D1 said hold it back pending the fallback fraction, and
      F5 measured that fraction at zero in the fixture.
- [x] **R2.** **Done 2026-07-28: F8.** All thirty nil tests replaced, via
      in-place tag matching rather than a stored flag, so `Terminal` gained no
      field. The coverage audit ran first and found a real hole -- the
      primary-vs-alternate cursor branch was unpinned, because the alt tests
      assert cursors only on empty scrollback and the alt tests that build
      scrollback never assert the cursor -- so the four proof obligations landed
      in their own commit (`c13abc3`) ahead of the change (`cd57fa7`) and were
      mutation-verified against an inverted branch. `benchmark-confirm` was run
      in place of the prescribed `benchmark-quick`; `terminal-feed` **-6.61%**,
      below the predicted -8% to -15%, with `scrollback-stream` equivalent and
      the three render-bound workloads null as predicted. The
      `outlined destroy of (InactivePrimaryScreen?, InactivePrimaryScreen?)`
      symbol is gone from the release binary.
- [x] **R4.** **Done 2026-07-28: F9.** All thirteen collections hoisted above the
      run loop and emptied at the top of each iteration keeping capacity, in
      commit `07dd81f` against baseline `919838f` -- named in the plan before the
      first edit. No `reserveCapacity` guess was introduced. `benchmark-draw`
      full-frame **-4.40%** / **-8.99%**, straddling D1's -3% to -6%;
      `benchmark-quick content-churn` **-15.68%** and **-18.10%** across two
      independent pair sets, with plan time equivalent in both. AR1's predicted
      null did not happen. Behavioral coverage is six cross-run isolation tests,
      one per category of collection, each mutation-verified against its own
      deliberately omitted reset.

### Phase 3 -- decide what to do about compositing

- [x] **Gate: do not open R3 before Phase 2 is measured.** **Open as of F9.** R1,
      R2 and R4 are all landed and measured, so R3 can no longer inherit their
      effect. The gate opening does not license starting R3 -- the next task
      below still comes first, and D1 keeps R3 research-only until doc 11 has it.
- [ ] Re-capture after Phase 2 and read the `CA::CG::Queue` total and the
      `CABackingStoreGetFrontTexture` blocked fraction. Record in **F10**.
      **This needs the user** -- see the standing rule in Investigation rules and
      the hand-over text in "Re-capturing a live profile". Pause and ask; do not
      script the gesture, and do not reuse F1's, F6's **or F7's run 3** as the
      post-change one -- run 3 is post-R1 but pre-R4, so it is mid-Phase-2 and
      does not satisfy this task. Its incidental readings (queue 1,273, blocked
      1,053) are recorded in F7 and are what the eventual F10 capture should be
      compared against.
- [ ] Hand F1, **F5**, F8 and H3 to doc 11 as evidence for its Phase 1 and its H1/H3
      gate. This file does not own the optimize-or-replace decision and must not
      make it.

### Phase 4 -- close the instrument gap

- [ ] Decide whether a repeatable live-compositing instrument is worth building.
      The gap this file documents is real -- no harness observes
      `CA::CG::Queue`, the backing-store stall, or the window server -- and the
      cost of closing it is a scripted input driver plus a sample wrapper.
      Record the decision even if it is "no".

## Findings log

### F1 -- the main thread stalls ~1,064 samples on a CoreAnimation queue whose dominant cost is copying glyph outlines to get bounding boxes

- Status: recorded. Attribution from **one** profile. Not a timing, not a
  comparison.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: sampled binary built from `4ca27ee`, optimized
  configuration. Repository at capture time was `9655657` (three later commits,
  all `docs(research)` except `4de86b6`, none of which are in the binary).
- Command and gesture: see "Trigger and current evidence". `sample ... 20` while
  a person held the down-arrow key scrolling btop's process list.
- Artifact: `.build/manual-profiles/2026-07-28-113733-72198-btop-scroll.txt`.
- Measurements -- main thread, inclusive samples out of 4,256 busy:

  ```
  CA::Transaction::commit                          3600   85% of busy
  |- CA::Layer::display_if_needed                  2462
  |  \- NSViewBackingLayer display                 2156
  |     \- SwiftTerminalSessionView.draw(_:)       1991
  |        \- drawRenderFrame                      1986
  |           \- drawTextRuns                      1970
  \- CA::Layer::prepare_commit                     1083
     \- CABackingStoreGetFrontTexture              1079
        \- _dispatch_sync_f_slow -> kevent_id      1064   BLOCKED, not CPU (98.6%)
  ```

  `CA::CG::Queue` thread, inclusive samples out of 1,316:

  ```
  CA::CG::DrawOp::render                           1211
  |- DrawGlyphs::compute_dod_                       547
  |  \- get_glyph_bboxes                            497
  |     \- FPFontGetGlyphIdealBounds                468
  |        \- TFPFont::CopyGlyphPath                424
  |           \- TGlyphOutlineDictionaryCache<ushort,64,512>::Copy   382
  |- CA::CG::FillRects::draw_shape                  261
  |  \- CA::OGL::fill_rect                          241
  \- CA::CG::draw_glyph_bitmaps                     179
  ```

- Observation 1: `drawTextRuns` is **99.2% of `drawRenderFrame`** (1,970 of
  1,986). Everything else in the draw call is rounding error, so "draw cost" and
  "`drawTextRuns` cost" are the same quantity in this capture.
- Observation 2: **25% of the main thread's busy time is not CPU.** The 1,064
  blocked samples are a synchronous wait on the CG replay queue. Any accounting
  that reads 4,256 as CPU overstates main-thread compute by a third; true CPU is
  roughly 3,192.
- **Correction, 2026-07-28, found by the F6 repeat.** This finding originally
  recorded the blocked figure as **720**, read off the single
  `CABackingStoreGetFrontTexture + 128` node visible in the printed tree. That
  node has 723 samples; the *function* has 1,079 across several offsets, and
  summing `_dispatch_sync_f_slow` over all of them gives **1,064**, of which
  1,064 reach `kevent_id`. The original number was a subtree-versus-node error,
  not a sampling artifact -- run 1's own data always said 1,064. Everything the
  720 figure fed (Observation 2's percentage, H3's framing, R3's bound, the
  thread-census note) is corrected in place and listed here so the error is not
  silently absorbed. The direction of the correction **strengthens** H3: the wait
  is a quarter of main-thread busy, not a sixth, and the node is ~99% wait rather
  than ~67%.
- Observation 3: on the CG queue, **bounds computation (547) costs three times
  actual rasterization (179)**, and 78% of the bounds cost is `CopyGlyphPath` --
  building a full outline path to extract a rectangle, missing a 64-entry cache
  while doing so.
- Observation 4: `FillRects` + `fill_rect` is 261 + 241 samples. This is
  plausibly DanTerm's own sprite path (box-drawing and braille cells drawn as
  rects rather than glyphs) arriving at the compositor. If so it is the *cost
  side* of the sprite decision, and it belongs in any future comparison of
  sprite-versus-glyph -- sprites do not make cells free, they relocate the cost
  from glyph rasterization to rect fills.
- Inference: supplies doc 11 with the compositing cost its F1 explicitly
  excludes, and supports doc 11's H1 from a direction its instrument cannot
  reach.
- Competing interpretations: the stall is a pipeline and is not wholly
  recoverable; the outline-cache miss may be specific to btop's glyph inventory.
  Both are stated in H3 and neither is excluded by this profile.
- Uncertainty: **high**. One profile, human-paced input, no repeat. The tree
  shapes are unambiguous; the shares are not yet stable.
- Next action: the Phase 1 repeat capture, and the glyph-inventory task.

### F2 -- inside `drawTextRuns`, the per-run attributes dictionary costs as much as all glyph drawing

- Status: recorded. Attribution from one profile.
- Source: same artifact as F1.
- Measurements -- 2,085 `drawTextRuns` node samples attributed by source line in
  `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`:

  | Samples | Share | Line | What |
  | ---: | ---: | ---: | --- |
  | 372 | 17.8% | 575 | `CTFontDrawGlyphs` |
  | **382** | **18.3%** | **367-370** | **`attributes` dictionary literal** |
  | 146 | 7.0% | 499-500 | `characters` / `candidateCells` appends |
  | 131 | 6.3% | 399 | `BoxDrawingSprite.append` |
  | 119 | 5.7% | 513 | `fill(spriteRects)` |
  | 105 | 5.0% | 564-565 | `mappedGlyphs` / `positions` appends |
  | 89 | 4.3% | 549 | `CTFontGetGlyphsForCharacters` |
  | 89 | 4.3% | 584 | `drawTextCell` fallback |
  | 85 | 4.1% | 365-366 | CGColor cache lookup (66) and store (19) |
  | 45 | 2.2% | 547 | `Array(repeating: CGGlyph(), count:)` |
  | 285 | 13.7% | -- | compiler-generated / unattributed |

  The 382 decomposes as 110 samples in `Dictionary.init(dictionaryLiteral:)`,
  descending through `__RawDictionaryStorage.find` (44) into `String.hash(into:)`
  (43) and `Hasher.combine(bytes:)` (25), plus the surrounding literal
  construction and teardown.

- Observation 1: the dictionary is built at line 367 and read only at line 588,
  inside `for fallback in fallbackCells`. Every run that produces no fallback
  cell -- which is the common case for ASCII and for any sprite-classified cell
  -- builds and destroys it for nothing.
- Observation 2, incidental to the same three lines: the CGColor cache at 365-366
  **writes unconditionally**, so a cache *hit* still pays a dictionary mutation
  and its copy-on-write uniqueness check. Line 366 alone is 19 samples, and it is
  the write. This is R1b.
- Inference: supports H1. The change is a hoist or a lazy binding; the drawn
  output is bit-identical because the value's only consumer is unchanged. The
  same holds for R1b: writing only on a miss stores exactly the values the
  unconditional write already stored.
- Competing interpretation: the share is btop-shaped. Short colored runs mean
  many runs per row; a long-uniform-run workload would show much less. **This
  remains the correct caveat on the 18.3% figure**, and it is why 18.3% is the
  number that transfers to real use rather than whatever `benchmark-draw`
  reports.
- **Superseded sub-claim.** This entry originally continued: "...and it is the
  difference between R1's prediction transferring to `benchmark-draw` and not,"
  with the concern that the fixture might be *less* run-dense than real btop and
  so understate R1. F5 measured the fixture and the opposite holds -- it is one
  run per cell, the maximum, and it never reaches the font path. The caveat above
  still governs the real-workload number; the inference about the headless
  instrument is withdrawn and replaced by F5.
- Uncertainty: low on the mechanism, **medium on the magnitude** (one profile,
  one workload shape). R1b's 19 samples are additionally near the resolution
  floor of a single capture and should not be quoted with confidence.
- Next action: R1 and R1b in Phase 2, gated on the Phase 1 repeat.

### F3 -- `damageActionSnapshot` copies an array-bearing struct twice per action to test it against nil

- Status: recorded. Attribution from one profile.
- Source: same artifact as F1.
- Measurements -- PTY host thread (`com.danneu.danterm.terminal-pty-host`),
  inclusive samples out of 831:

  ```
  TerminalPTYHost.readReady                        796
  \- TerminalPTYHost.process                       776
     \- TerminalPTYHost.applyOutput                766
        \- Terminal.feed                           735
           |- outlined destroy of (InactivePrimaryScreen?, InactivePrimaryScreen?)  187
           |- Terminal.damageActionSnapshot.getter 178
           |- TerminalInputStream.feed             164
           |- Terminal.printNarrow                 116
           |- EscapeAbsorber.consume               106
           |- Terminal.recordDamage                 65
           \- Terminal.invalidateInspection         64
  ```

  The tuple destroy is reached from `damageActionSnapshot.getter + 144` (46
  samples at one sub-node, 4 more nearby) and `+ 396` (41 samples plus
  neighbours), i.e. **two distinct call sites**, matching `Terminal.swift:553`
  (`inactivePrimaryScreen == nil`) and `:565` (`inactivePrimaryScreen != nil`).
  Below it: `tuple_destroy` 140, `destroy for ClosedRange<>.Index` 73,
  `getEnumTagSinglePayload for InactivePrimaryScreen`, `swift_bridgeObjectRelease`.

- Observation: 187 samples is **22.5% of the whole PTY thread** and **25% of
  `Terminal.feed`**, spent destroying temporaries of a comparison whose entire
  semantic content is "is this optional populated".
- Inference: supports H2. `InactivePrimaryScreen: Equatable` (`Terminal.swift:328`)
  makes `== nil` resolve to the generic two-operand overload, which copies both
  sides; the struct holds `rows: [GridRow]`, so each copy retains and releases
  the row array. The fix is to test the case without copying the payload --
  `if case .some`, `.none` pattern matching, or a stored
  `isAlternateScreenActive: Bool` maintained at the single mutation site
  (`Terminal.swift:4252`).
- Competing interpretation: the destroy is the getter's own local teardown rather
  than a comparison temporary. The **tuple arity refutes it** -- a local would
  destroy as one optional, not a pair of them -- but that refutation reads a
  mangled symbol rather than running an experiment.
- Relationship to `4ca27ee`: that commit halved how *often* the snapshot is
  built. This halves what *each* build costs. They compose; neither subsumes the
  other, and F3 is measured on a binary that already contains `4ca27ee`.
- Relationship to doc 10: doc 10 closed with feed work not moving the two
  render-bound workloads (`10/F9`). R2 should therefore be expected to move
  `terminal-feed` and `scrollback-stream` and **not** `content-churn` or
  `style-churn`. A null on the churn workloads is the predicted result, not a
  failure.
- Uncertainty: low on the mechanism, medium on the magnitude.
- Next action: R2 in Phase 2.

### F4 -- this capture's plan/draw ratio is the inverse of doc 9's

- Status: recorded. Cross-reference, not a correction.
- Source: same artifact as F1.
- Measurements: `PaneFramePlanner.planFrame` totals **362 samples on the main
  thread** (354 + 8), i.e. **8.5% of main-thread busy**, against
  `drawRenderFrame`'s 1,986 (**47%**). Within the planner:
  `FramePlanner.inspectedCells` 138, `textRuns` 133, `decorationRuns` 30.
  `Terminal.drainDamage` is 6.
- Compare doc 9's content-churn attribution: **plan 35.4% / draw 27.7%** of
  6,088 non-idle main-thread samples.
- Observation: the ratio is roughly inverted -- 1.28:1 plan-to-draw there, 0.18:1
  here.
- Inference: supports H4. `full-screen-content-churn` re-plans the whole grid
  every frame by construction; btop damages panels. Both figures are probably
  right for their workload, and **neither generalizes**. The practical
  consequence is that doc 9's implicit ranking of plan work above draw work does
  not survive contact with a real damage-clipped workload, and doc 11's
  draw-centric question is the better-aimed one.
- Competing interpretation: doc 9's profiles carried a `TerminalBenchmarkObserver`
  at 7.6% plus a fixture producer; this one has no instrumentation at all. Part
  of the gap is plausibly harness overhead inflating the plan side rather than
  workload shape.
- Uncertainty: medium. One profile each side, different builds, different
  workloads, different instrumentation.
- Next action: the H4 confirmation task -- a `benchmark-sample` of
  `incremental-mixed` should land between the two ratios if workload shape is the
  mechanism.

### F5 -- `benchmark-draw`'s fixture is one run per cell and draws no glyphs at all

- Status: recorded. **Measured, not sampled** -- this is a deterministic property
  of the fixture, so unlike F1-F4 it does not need a repeat capture.
- Date and investigator: 2026-07-28, Claude (agent).
- Commit and worktree state: `9655657`, tracked tree clean.
- Command: a scratch probe over `makeBtopShapedPlan(for:)` counting runs, cells,
  and per-cell classification against the eight sprite coarse ranges. The probe
  was deleted after the numbers were transcribed. **Its full source and the
  invocation are in "Reproducing the evidence" above** -- including the filter
  gotcha that makes `--filter "<suite display name>"` silently match nothing.
- Measurements:

  | Grid | Cells | `textRuns` | Cells/run | Runs/row | Sprite-routed | Font candidates | Fallback cells | Distinct scalars |
  | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
  | 80x24 | 1,920 | **1,920** | 1.00 | 80.0 | 1,920 | **0** | **0** | 12 |
  | 160x50 | 8,000 | **8,000** | 1.00 | 160.0 | 8,000 | **0** | **0** | 12 |

- Observation 1: **the fixture produces exactly one run per cell** -- the
  theoretical maximum run density, not a low one. This is deliberate and
  documented: `btopShapedANSI(for:)`
  (`TerminalDrawBenchmarkSupport.swift:69-85`) changes the 256-color foreground
  on every cell and alternates bold on every cell, its doc comment says the
  changing color and emphasis "prevent adjacent text-run folding", and
  `TerminalDrawBenchmarkSupportTests` already asserts
  `plan.textRuns.count > columns * rows * 3 / 4`.
- Observation 2: **no cell in the fixture reaches the font path.** All twelve
  glyphs are sprite-classified -- six box-drawing (`┌─┐│└┘`), three braille
  (`⣿⣷⣯`), three block-element (`█▆▃`) -- and all three families are *total* over
  their coarse ranges, so routing cannot fall through. Braille maps the whole
  `0x2800...0x28FF` by construction (`BrailleSprite.swift:16-21`); Block Elements
  enumerates `0x2580...0x259F` exhaustively; Box Drawing's `pattern(for:)` ends
  in `default: preconditionFailure("complete Box Drawing mapping...")`, which is
  a compile-time-adjacent proof that the range is total. Consequently
  `characters`, `candidateCells` and `fallbackCells` are always empty, and
  **`CTFontGetGlyphsForCharacters` (`:549`), `CTFontDrawGlyphs` (`:575`) and
  `drawTextCell` (`:584`) are never called.**
- Inference 1, for R1: `attributes` is constructed 8,000 times per full frame at
  160x50 and read **zero** times. The fixture is therefore the *upper bound* on
  R1's benefit, not a conservative case. **This inverts the risk R1 was
  originally recorded against** -- the concern was that the fixture might have
  fewer runs than real btop and understate the win; it has the most runs
  possible and will overstate it. D1's prediction and falsification criteria are
  revised accordingly.
- Inference 2, for doc 11, and it is the more consequential one: **doc 11's F1
  measures a draw containing no glyph rasterization.** Its 15.6 ms at 160x50 and
  the ~23 ms extrapolation to 179x66 are sprite fills plus per-run dictionary
  construction plus planning overhead -- with `CTFontDrawGlyphs`, which was
  **17.8% of `drawTextRuns` in the real capture (F2)**, entirely absent. Doc 11's
  F1 caveat says the fixture is "btop-shaped and synthetic"; it does not say the
  measurement never rasterizes a glyph, and that omission is material to the
  H2-versus-H3 split, because H3 is precisely the claim that *CPU glyph
  rasterization has a floor*. The only sizing measurement backing it never
  rasterizes a glyph.
- Competing interpretations: none for the counts -- they are deterministic and
  reproducible. The interpretation that *is* open is whether the fixture's design
  is wrong. It is defensible on its own terms: it was built to stress run
  fragmentation and sprite geometry, and it does that well. The error is not in
  the fixture, it is in reading a number produced by it as "the cost of a
  btop-shaped draw" without the two qualifications above.
- Uncertainty: none on the measurement. The real-btop run-density comparison is
  still missing (open ledger task), but F2's 18.3% is already a direct
  measurement of the real workload, so the comparison is wanted for
  completeness rather than to settle R1.
- Next action: revise D1's R1 prediction (done); raise the doc 11 consequence in
  Open questions (done); leave the fixture itself alone pending doc 11's view.

### F6 -- the repeat capture reproduces every load-bearing node, and corrects one

- Status: recorded. **Satisfies doc 9's two-profile rule for F1-F4.**
- Date and investigator: 2026-07-28 12:16:29, capture by the user, analysis by
  Claude (agent).
- Artifact:
  `.build/manual-profiles/2026-07-28-121629-72198-btop-scroll-run2.txt`.
  Original capture path `/tmp/danterm-btop-sample-2.txt`.
- Provenance, and it is unusually tight: **same pid (72198), same launch time
  (10:58:33)** as run 1. This is not a rebuild or a relaunch -- it is the same
  process instance 39 minutes later, so the binary is byte-identical and still
  commit `4ca27ee`. Same gesture (down-arrow held, btop process list), same
  geometry, same command shape.
- **Contention caveat, reported by the user: an unrelated benchmark was running
  in another process during run 2.** The visible effect is in the idle/busy
  split, exactly where CPU contention would show: main-thread idle fell 12,747 →
  12,296 and busy rose 4,256 → 4,523. The *shares* are unaffected, which is what
  this file uses. Treat run 2's absolute busy total as contaminated and its
  ratios as sound; where the two disagree, prefer run 1's absolutes.
- Measurements, run 1 versus run 2:

  | Node | Run 1 | Run 2 |
  | --- | ---: | ---: |
  | Main thread total / idle / **busy** | 17,003 / 12,747 / **4,256** | 16,819 / 12,296 / **4,523** |
  | `CA::Transaction::commit` | 3,600 | 3,810 |
  | `CA::Layer::display_if_needed` | 2,462 | 2,661 |
  | `SwiftTerminalSessionView.draw(_:)` | 1,991 | 2,093 |
  | `drawRenderFrame` | 1,986 | 2,083 |
  | `drawTextRuns` | 1,970 | 2,067 |
  | `CABackingStoreGetFrontTexture` | 1,079 | 1,068 |
  | -- of which blocked in `kevent_id` | **1,064 (98.6%)** | **1,065 (99.7%)** |
  | `PaneFramePlanner.planFrame` | 362 | 307 |
  | `CA::CG::Queue` thread | 1,316 | 1,343 |
  | -- `DrawGlyphs::compute_dod_` | 547 | 530 |
  | -- `TFPFont::CopyGlyphPath` | 424 | 400 |
  | -- `FillRects::draw_shape` | 261 | 272 |
  | PTY host thread | 831 | 827 |
  | -- `Terminal.feed` | 735 | 693 |
  | -- `damageActionSnapshot.getter` | 178 | 163 |
  | -- **tuple destroy** | **187** | **166** |

  `drawTextRuns` by source line, as a share of its node total (2,085 / 2,180):

  | Line | Run 1 | Run 2 |
  | --- | ---: | ---: |
  | **367-370 `attributes`** | **382 (18.3%)** | **420 (19.3%)** |
  | 575 `CTFontDrawGlyphs` | 372 (17.8%) | 415 (19.0%) |
  | 399 `BoxDrawingSprite.append` | 131 (6.3%) | 121 (5.6%) |
  | 513 `fill(spriteRects)` | 119 (5.7%) | 121 (5.6%) |
  | 584 `drawTextCell` fallback | 89 (4.3%) | 115 (5.3%) |
  | 549 `CTFontGetGlyphsForCharacters` | 89 (4.3%) | 83 (3.8%) |
  | **365-366 CGColor cache** | **85** | **101** |

- Observation 1: **every hypothesis-bearing node reproduced.** H1's attributes
  share moved 18.3% → 19.3%; H2's tuple destroy 187 → 166; H3's blocked wait
  1,064 → 1,065 and its `CopyGlyphPath` 424 → 400. Nothing reordered, nothing
  vanished, nothing doubled.
- Observation 2: **the correction the repeat produced was not a sampling
  difference.** Re-running the extraction with a subtree sum rather than a single
  node showed run 1 had always said 1,064, not 720. See F1's correction note. The
  repeat's value here was procedural, not statistical -- it forced the analysis to
  be re-run, and the re-run caught a reading error.
- Observation 3: `planFrame` fell 362 → 307 while draw rose, consistent with H4's
  claim that the plan/draw ratio is workload-shaped and that this workload is
  draw-dominated. Both runs are far from doc 9's 35.4% / 27.7%.
- Inference: F1, F2 and F3 are no longer provisional on the one-sample ground,
  and the "no candidate may be implemented on a single unrepeated share" rule is
  satisfied. **Phase 2 is unblocked.**
- Competing interpretations: the contention caveat above is the live one. It
  cannot explain the share stability -- a contended CPU would perturb absolutes,
  which it did, not the relative composition of a subtree, which it did not.
- Uncertainty: low. Two captures, same process, same gesture, consistent shares.
  The residual uncertainty is workload shape (btop specifically), not sampling.
- Next action: Phase 2. R1+R1b and R2 are both unblocked.

### F7 -- R1+R1b landed: the attributes literal is gone from the live tree, and `benchmark-draw` moved roughly twice the predicted amount

- Status: **closed.** R1 and R1b implemented and committed together, as D1
  prescribed. H1 is confirmed.
- Source: commit `919838f`, against baseline `fcfff10`, which was resolved and
  benchmarked *before* any implementation edit -- not inferred from `HEAD`
  afterwards.
- Change made: the `[NSAttributedString.Key: Any]` literal moved inside
  `if fallbackCells.isEmpty == false`, at the fallback loop it feeds. D1 left
  hoist / lazy / build-in-loop open and named a `(fontVariant, colorKey)` cache
  as the refinement to hold back; **the guard was chosen and no cache was
  added**, so the change introduces no new state and no invalidation invariant.
  R1b became the explicit `if let cached` / `else` pair D1 asked for, which is
  what rules out the double-construct bug it flagged.

- Measurement 1 -- `just benchmark-draw`, 15 iterations, median
  `drawDurationNanoseconds`:

  | Scenario | Grid | Baseline | After | Delta |
  | --- | --- | ---: | ---: | ---: |
  | full-frame | 80x24 | 3,688,963 | 2,439,973 | **-33.9%** |
  | damage-clipped | 80x24 | 710,321 | 532,790 | -25.0% |
  | full-frame | 160x50 | 14,960,141 | 10,300,003 | **-31.2%** |
  | damage-clipped | 160x50 | 1,313,731 | 946,960 | -27.9% |

  The baseline column is a **same-session re-measurement** of `fcfff10` in a
  throwaway worktree, not the figures recorded when the plan was written
  (3,812,103 / 739,177 / 15,700,956 / 1,366,175, which give -36.0% / -27.9% /
  -34.4% / -30.7%). The re-measurement was taken because a result at double the
  prediction is exactly the shape a drifted baseline produces; the two baselines
  agree within run-to-run variance, so drift is excluded.

- Measurement 2 -- `just benchmark-quick fcfff10 content-churn`: **faster,
  -4.36%** (symmetric median of 2 pairs), plan time inconclusive at +1.08%.

- Measurement 3 -- **live capture run 3**, the re-post the ledger requires.
  Artifact `.build/manual-profiles/2026-07-28-145622-16337-btop-scroll-run3.txt`,
  pid 16337, launched 14:55:44 and sampled 14:56:22, same command and same
  held-down-arrow btop gesture as F1/F6. **Grid geometry was not recorded for
  this capture** -- F1/F6 are 179x66 and the request was for the window's normal
  size, but that is an assumption here, not a measurement, and it is the one
  provenance field this run is missing. Unlike F6 this is a **different process
  instance**, so the launch-time provenance trick does not apply; the binary is
  identified by mtime instead -- the installed `DanTerm Dev` (14:55:44) matches
  `.spm-build/release/DanTerm` (14:55:40), an **optimized** build made after
  `919838f` (14:52:27). Nothing else heavy was running. Node shares inside
  `drawTextRuns`, 1,670 node samples against run 1's 2,085:

  | What | Line, run 1 -> run 3 | Run 1 | Run 3 |
  | --- | --- | ---: | ---: |
  | **`attributes` dictionary literal (R1)** | 367-370 -> 589-593 | **382 (18.3%)** | **1 (0.1%)** |
  | **CGColor cache store (R1b)** | 366 -> 370 | **19 (0.9%)** | **7 (0.4%)** |
  | CGColor cache lookup, and miss-path construction | 365 -> 366, 369 | 66 | 25 + 42 |
  | `CTFontDrawGlyphs` | 575 | 372 (17.8%) | 353 (21.1%) |
  | `drawTextCell` fallback | 584 -> 595 | 89 (4.3%) | 67 (4.0%) |

  Whole-function: `drawTextRuns` inclusive on the main thread **1,537 of 3,768
  busy samples (40.8%)**, against run 1's 1,970 of 4,256 (46.3%).

- Observation 1: **the structural check R1b was given passes.** D1 said the only
  available test at that size is that the node shrinks in the re-posted tree, and
  it did, independently of R1's node. The joint benchmark verdict is therefore
  backed by two separate attributions, which is what the ledger's break-them-out
  requirement was for.
- Observation 2: **the prediction was beaten by roughly 2x** -- D1 said -13% to
  -18% on the full-frame rows and the measurement is -31% to -34%. F5 already
  established the fixture is R1's best case (one run per cell, zero fallback
  runs), so the direction of the surprise is the one F5 predicted; the size of it
  is not explained by anything recorded here. The honest reading is that the
  dictionary's cost in the fixture exceeds its 18.3% live share, and that the
  18.3% figure remains the one that transfers to real use.
- Observation 3: **the fallback path is not empty in real btop output.** Line 595
  carries 4.0%, so unlike the fixture (F5: zero fallback runs), live btop does
  reach `drawTextCell` -- and the dictionary is still built there, just only
  there. This is the first direct evidence on the live side of the open Phase 1
  task that asks for the fallback fraction against real btop output; it does not
  close that task, which wants a count, not a share.
- Observation 4, incidental: `CABackingStoreGetFrontTexture` reads 1,053 (run 1:
  1,079) and the `CA::CG::Queue` thread 1,273 (1,316). R3's stall is untouched,
  as the Phase 3 gate intends. **This does not discharge the F10 task**, which
  wants the re-capture *after* Phase 2 -- R4 has not landed.
- Inference: **H1 is confirmed and closed.** The largest removable cost on the
  draw path was removed, the removal is visible in both instruments, and the
  live tree's largest node inside `drawTextRuns` is now glyph drawing itself.
- Competing interpretation for the 2x overshoot: the two benchmarks disagree by
  an order of magnitude (-34% headless versus -4.36% on `content-churn`), which
  is AR2's predicted dilution but is also consistent with `benchmark-draw`
  measuring a fixture whose run density is unrepresentative in the *other*
  direction than F2 feared. Nothing here separates those, and no measurement is
  proposed -- the change is landed and the direction is not in doubt.
- Uncertainty: low on the mechanism (the node is gone from the tree). Medium on
  every magnitude: one live capture, a different process instance from F1/F6, and
  a headless figure whose fixture F5 already showed to be atypical.
- Next action: R4, now unblocked. Its measurement should be taken against
  `919838f`, not against `fcfff10`.

### F8 -- R2 landed: the tuple destroy is gone from the binary, and `terminal-feed` moved less than predicted

- Status: **closed.** R2 implemented and committed.
- Source: commits `c13abc3` (coverage) and `cd57fa7` (change), against baseline
  `20a6eaf`, which was resolved and recorded *before* any implementation edit --
  not inferred from `HEAD` afterwards.
- Change made: all thirty `inactivePrimaryScreen == nil` / `!= nil` sites now
  route through the existing `isAlternateScreenActive`, which matches the
  optional's tag in place (`if case .some`). D1 left the choice between in-place
  matching and a stored flag open; **in-place matching was chosen, so `Terminal`
  gains no field** and the growth risk D1 named as R2's way of backfiring cannot
  arise. The four remaining `inactivePrimaryScreen` references all genuinely
  read the payload.

- Measurement 1 -- **direct confirmation of the mechanism, not a benchmark.**
  Release-built `Terminal.swift.o` was compared at baseline and after:

  ```
  baseline: merged outlined destroy of (InactivePrimaryScreen?, InactivePrimaryScreen?)
            merged outlined init with copy of InactivePrimaryScreen?
  after:    merged outlined init with copy of InactivePrimaryScreen?
  ```

  The symbol F3 attributed 187 of 831 PTY-thread samples to is **absent from the
  binary**. Only the payload copy serving the legitimate `if let` / `if var`
  reads survives.

- Measurement 2 -- `benchmark-confirm baseline=20a6eaf`:

  | Workload | Verdict | Role per D1 |
  | --- | --- | --- |
  | `terminal-feed` | **faster, -6.61%** (2 pairs) | decider |
  | `scrollback-stream` | equivalent, -0.13% (4 pairs) | decider |
  | `content-churn` | inconclusive, -1.66% (4 pairs, 2 flagged outliers) | predicted null |
  | `style-churn` | equivalent, +0.06% (4 pairs, 1 flagged outlier) | predicted null |
  | `incremental-mixed` | inconclusive, -0.88% (6 pairs) | predicted null |

- Observation 1: **the mechanism transferred; the magnitude did not, fully.**
  D1 predicted `terminal-feed` **-8% to -15%** and got -6.61% -- outside the
  band, in the same direction. Recorded as measured.
- Observation 2: **doc 10/F9's boundary held exactly.** All three render-bound
  workloads landed in the null band D1 predicted for them. Per D1's own rule this
  is the expected result and is not read as the change doing nothing.
- Observation 3: `scrollback-stream` at -0.13% is the second decider passing in
  the weak sense -- no regression. D1 named it as where a stored flag's struct
  growth would have shown up; since no field was added, it had nothing to detect.
- Inference: **H2 is confirmed and closed.** The comparison was real, its cost
  was real, and removing it is worth a single-digit percentage on the one
  headless workload that can see feed work.
- Competing interpretation for the shortfall: the honest one is that F3 is a
  *live-app PTY-thread* attribution and `terminal-feed` is a headless harness
  with a different action mix, so 22.5% of that thread need not map onto 8-15%
  of this workload. A second, weaker possibility is under-sampling --
  `terminal-feed` resolved on **2 pairs, the fewest of any workload**, so its
  interval is the widest in the table and -6.61% should be read as directional,
  not as a point estimate.
- Deviation from the ledger, deliberate: the ledger prescribed
  `just benchmark-quick <base> terminal-feed`. **`benchmark-confirm` was run
  instead**, on doc 10's own single-workload rule and 12/F8's precedent of a
  change decided on one workload being blindsided by a second. The stricter
  instrument cost more time and changed no verdict.
- Uncertainty: low on the mechanism -- the symbol comparison is not statistical.
  Medium on the magnitude, for the two reasons above.
- Next action: none for R2. If -6.61% is ever cited as a figure rather than a
  direction, re-run `terminal-feed` to get it off two pairs first.

### F9 -- R4 landed: the per-run allocations are gone, and the paired app benchmark moved 3x the predicted band while the headless fixture moved less

- Status: **closed.** R4 implemented and committed. Phase 2 is complete and
  measured.
- Source: commit `07dd81f`, against baseline `919838f` (R1's commit), which was
  named in the plan *before* any implementation edit -- not inferred from `HEAD`
  afterwards, and deliberately not `fcfff10`.
- Change made: all thirteen collections hoisted above `for run in runs` and
  emptied at the **top** of each iteration keeping capacity. The reset sits at
  the top rather than the end so it survives a future `continue` in the loop
  body. D1 left `reserveCapacity` in the title and the plan's RI1 rejected it:
  no fixed guess was introduced, so capacity converges on the frame's own
  maximum. The two dictionaries whose values are arrays empty each bucket in
  place and retain their keys -- clearing the outer dictionary would have
  discarded the inner arrays and handed the allocation straight back through the
  `[key, default: []]` subscript, which is the trap the plan flagged.

- Measurement 1 -- `just benchmark-draw`, 15 iterations, median
  `drawDurationNanoseconds`. Baseline is a **same-session** measurement of
  `919838f` in a throwaway worktree, taken minutes before the after run:

  | Scenario | Grid | Baseline | After | Delta |
  | --- | --- | ---: | ---: | ---: |
  | full-frame | 80x24 | 2,481,383 | 2,372,147 | **-4.40%** |
  | damage-clipped | 80x24 | 530,935 | 515,059 | -2.99% |
  | full-frame | 160x50 | 10,490,107 | 9,546,994 | **-8.99%** |
  | damage-clipped | 160x50 | 954,650 | 899,866 | -5.74% |

- Measurement 2 -- `just benchmark-quick 919838f content-churn`, the
  decision-bearing instrument, run **twice**:

  | Run | Draw time | Plan time |
  | --- | --- | --- |
  | 1 | **faster, -15.68%** (2 pairs) | +0.98%, equivalent |
  | 2 (replicate) | **faster, -18.10%** (2 pairs) | +0.18%, equivalent |

  The replicate was run because a single 2-pair result at 3x the predicted band
  is exactly the shape a sampling artifact produces. It is a second, independent
  pair set, not a re-read of the first. Both arms build from immutable source
  snapshots; the candidate snapshot captured eight working-tree paths, all of
  them docs, notes, or `plans/wip/` files, so the candidate is code-identical to
  `07dd81f`. Artifacts:
  `.build/terminal-benchmark-comparisons/quick/bf69881b7b97-0000` and
  `-0001`; baseline tree `61c036dd`, candidate tree `bf69881b`.

- Observation 1: **the prediction was beaten, and by the instrument it was not
  written for.** D1's -3% to -6% band was a `benchmark-draw` full-frame
  prediction: 80x24 landed **inside** it at -4.40% and 160x50 **above** it at
  -8.99%. The paired app benchmark, which had no predicted band, moved -15.7% to
  -18.1%. Recorded as measured; the band is not restated after the fact.
- Observation 2: **AR1 was wrong, decisively.** The plan accepted a null result
  as the likely outcome -- this is the smallest candidate in D1's ranking, and
  doc 9 flagged its own version of the item as the one most likely to be absorbed
  by allocator noise. Two independent pair sets and all four headless scenarios
  moved in the same direction; three of the four clear `benchmark-draw`'s ±2.5%
  noise floor (11/F1) comfortably and the fourth, damage-clipped 80x24 at
  -2.99%, only just does.
- Observation 3: **the paired figure and the live share agree almost exactly,
  and that is worth reading carefully.** Run 3 put these lines at 18.1% of
  `drawTextRuns`' node samples, and `drawTextRuns` is ~93% of `drawRenderFrame`
  (9/F3), which predicts roughly -17% of draw if every sample removed were pure
  removable overhead. The measurement is -15.7%/-18.1%. The agreement is
  striking but should not be promoted to a law: `content-churn` and the btop
  capture are different workloads, and one coincidence across two instruments is
  not a calibration.
- Observation 4, as the plan required: **R4's headless-delta-to-live-share ratio
  is 0.24 (80x24) to 0.50 (160x50), against R1's ~1.9.** This is reported as
  descriptive evidence only, and the cause of the gap is left unresolved. The
  two candidates are not exposure-matched and their ratios cannot establish a
  calibration factor: F5 established that `benchmark-draw`'s fixture routes 100%
  of cells to sprites with zero font candidates and zero fallback cells, so it
  grows only the seven sprite accumulators and never touches `characters`,
  `candidateCells`, `glyphs`, `mappedGlyphs`, `positions`, or `fallbackCells` at
  all. That makes the fixture R1's best case and R4's worst -- which is the
  direction of both ratios -- but the *sizes* of the two gaps are not explained
  by anything measured here. Deriving a real calibration still needs the open
  Phase 1 run-density task plus the live route composition.
- Inference: the per-run allocation of scratch collections was a real cost on
  the draw path, roughly the size its live attribution said it was. Note which
  way round the two candidates come out: on `benchmark-draw` R1 is far the
  larger (-31%/-34% against R4's -4%/-9%), and on the paired app benchmark R4 is
  (-15.7%/-18.1% against R1's -4.36%). Ranked 1 and 4 by attributed size, they
  swap places depending on the instrument -- which is Observation 4's point
  stated as a result rather than as a ratio.
- Competing interpretation: `content-churn` resolved on **2 pairs each time**,
  the minimum, so each interval is wide. The replicate narrows the risk that one
  run was a fluke but does not turn -15.7%/-18.1% into a point estimate. If a
  single figure is ever cited rather than a direction, get it off two pairs
  first.
- Deviation from the ledger, deliberate: `benchmark-confirm` was **not** run.
  The plan reserved it for resolving an *inconclusive* paired result, and
  neither run was inconclusive. The change is confined to the draw path and both
  runs reported plan time equivalent, so the F8 concern that motivated the
  stricter instrument there -- a second workload being blindsided -- has no
  corresponding mechanism here.
- Uncertainty: low on the mechanism (the allocations are gone from the source
  and four headless scenarios moved). Low-to-medium on the magnitude: two
  independent pair sets agreeing, but on the minimum sample size each.
- Next action: the **F10 re-capture**, which R4 was the last blocker for. Phase 3's
  gate is now open.

## Decision log

### D1 -- how to rank and sequence the candidates

- Status: **recommendation recorded; no direction selected, no implementation
  authorized.** Phase 1's repeat capture is the gate.
- Evidence used: F1, F2, F3, F4; doc 9's H3 and its open unreserved-array item;
  doc 10's F9; doc 11's F1 and its Phase 2 gate.
- Ranking criterion: attributed size, multiplied by confidence in the
  attribution, divided by implementation and correctness risk -- then reordered
  where one candidate would confound another's measurement.

---

#### R1 -- make the `attributes` dictionary lazy. **Rank 1.**

**Landed 2026-07-28 (`919838f`); result in F7.** The guard form was chosen and
no `(fontVariant, colorKey)` cache was added.

**What.** `TerminalRenderExecution.swift:367-371` moves inside
`if fallbackCells.isEmpty == false`, or is replaced by a small cache outside the
run loop keyed by font variant and foreground colour.

**The mechanics, because "per run" is doing a lot of work in that sentence.**
The dictionary is built **once per run**, not once per cell -- but for the
workload in F1 that distinction is thinner than it sounds.
`FramePlanner.textRuns(row:cells:)` (`RenderFramePlanner.swift:395-426`) breaks a
run on any change of foreground, bold, or italic, and -- via the
`column == startColumn + width` term in `OpenTextRun.continues(at:style:)`
(`:106-111`) -- on any positional gap, since `padding`, `wideTail`, `spacerHead`,
`style.hidden`, and empty-scalar cells all `continue` without extending the
accumulator. Runs never span rows. So the count per full frame at 179x66 is
bounded by 66 (one uniform run per row) and 11,814 (one per cell), and btop's
colored gauges, per-column colorization, and blank panel gutters put it far from
the low end -- **an estimated 20-60 runs per row, so roughly 1,300-4,000
dictionaries per full frame**. That estimate is reasoned from the run-breaking
rule, not measured; measuring it is the Phase 1 fallback-fraction task's sibling
and should be recorded alongside it.

Each construction costs three `CFString` → `NSAttributedString.Key` bridges, a
heap allocation, three `String` hashes (`NSAttributedString.Key` forwards
`Hashable` to `String`, so this is byte-wise SipHash, not an integer hash), three
`Any` boxes, and a full teardown. That is what the 110 samples in
`Dictionary.init(dictionaryLiteral:)` and the 43 in `String.hash(into:)` are.

The consumer is empty in the common case for a specific and checkable reason:
`fallbackCells` is only appended to at `:502` (scalar above `UInt16.max`), `:506`
(more than one scalar), and `:561` (`CTFontGetGlyphsForCharacters` returned glyph
0). btop's box drawing, braille, ASCII, and Latin are all single-scalar, all BMP,
and all either sprite-classified before the font path or mapped by the font.

**Why first.** It is the largest single removable node on the largest single
subtree (F2: 18.3% of `drawTextRuns`, which is 99.2% of the draw call, which is
47% of main-thread busy), and it is the *cheapest* of the ranked candidates: the value
has exactly one consumer, textually 220 lines below its construction, guarded by
a loop that is usually empty. Drawn output is bit-identical by construction, so
the correctness risk is close to zero and the existing draw tests are the right
coverage without additions. It is also the only candidate measured by an
instrument with **±2.5% repeatability** (doc 11 F1), which means a 13% effect is
unambiguous rather than arguable.

**Predicted impact -- revised by F5, and the revision is upward.**
`just benchmark-draw` full-frame at 160x50: **15.6 ms → 9.4-11.7 ms (-25% to
-40%)**. Damage-clipped at 160x50: a proportionally similar move. On
`benchmark-quick content-churn`, much smaller and possibly non-verdict-crossing,
because draw is one term of that workload's total.

**Why the revision, and why `benchmark-draw` will overstate the real win.** The
original prediction (-13% to -18%) assumed the fixture might produce *fewer* runs
per row than real btop and so understate the effect. F5 measured it and the
opposite is true on both axes that matter:

1. The fixture is **exactly one run per cell** -- 8,000 runs at 160x50, the
   maximum possible. It changes color and bold on every cell by design.
2. The fixture **never reaches the font path**, so `fallbackCells` is always
   empty and `attributes` is read zero times. R1 removes 100% of the cost there,
   with no residual for the runs that legitimately need it.

Both push the fixture's dictionary share *above* F2's real-workload 18.3%.
Removing F2's glyph-path line items (575, 549, 547, 564-565, 499-500 ≈ 846 of
2,085 node samples), which are all zero in the fixture, leaves the dictionary at
roughly **31% of what remains** -- and the fixture's higher run density pushes it
higher still. Hence -25% to -40%.

**The number that transfers to real use is F2's 18.3%, not this one.**
`benchmark-draw` here is a mechanism confirmation and an upper bound, not a
sizing measurement. Do not quote its delta as R1's user-visible benefit.

**What would falsify it.** A move under 15% on `benchmark-draw`. Given F5's
counts -- 8,000 unconditional constructions per full frame, none of them read --
a small move would mean the dictionary is far cheaper per construction than the
profile suggests, i.e. F2's attribution is wrong rather than merely
workload-specific. That is a genuinely different failure from the one the
original criterion was watching for, and it would send the investigation back to
F2 rather than to the fixture.

**Risk.** Low. The one thing to check is that no future edit reads `attributes`
outside the fallback loop; a lazy binding is more robust against that than a
hoisted cache.

**Note on the two refinements, and when each earns its keep.** Hoisting just the
three *keys* above the run loop is free and correct regardless -- they are
loop-invariant constants and only the two values vary -- so do it whether or not
the sink happens. The `(fontVariant, colorKey)` cache is the one to hold back: it
only pays if fallback cells turn out to be common, which is exactly what the
Phase 1 fallback-fraction task measures. Do not build it speculatively.

---

#### R1b -- write the CGColor cache only on a miss. **Rides with R1.**

**Landed 2026-07-28 (`919838f`); result in F7.** Written as the
`if let cached` / `else` pair recommended below; the structural check passed --
the store node fell 19 -> 7 samples in live run 3.

**What.** `TerminalRenderExecution.swift:365-366` is currently:

```swift
let foreground = colors[colorKey] ?? run.foreground.cgColor(in: colorSpace)
colors[colorKey] = foreground
```

The store is unconditional, so a cache **hit** still pays a dictionary mutation
and its copy-on-write uniqueness check. Rewrite so the store happens only in the
miss branch.

**Why it rides with R1 rather than ranking on its own.** It is 19 samples (F2,
line 366) -- about 0.9% of `drawTextRuns` -- which is below what a single
`benchmark-draw` run can separate from R1's much larger effect, and it is three
lines above R1's edit in the same function. Giving it its own commit and its own
benchmark run would spend a measurement to resolve a sub-1% figure. Giving it its
own *rank* would imply it competes with R2 and R4 for attention, which it does
not.

This is a deliberate exception to the rule at the top of this file about not
landing two changes in the same function together. The rule exists so that two
*measurable* effects stay attributable; R1b is not independently measurable, so
there is no attribution to protect. What replaces the protection is the ledger
requirement to re-post the draw tree with both nodes broken out -- lines 367-370
and line 366 shrink independently there even when the benchmark reports one
number.

**Predicted impact.** Not separately predicted. Folded into R1's -13% to -18%,
of which it is expected to supply well under one percentage point.

**What would falsify it.** Nothing that a benchmark can show at this size. The
check is structural: line 366 should be absent from the re-posted tree. If it is
still present at 19 samples, the edit did not take.

**Risk.** Very low, with one thing to actually verify rather than assume: the
rewrite must store the *same* value the unconditional write stored, so the miss
branch has to bind the freshly-constructed color to the local **and** insert it,
not construct twice. Writing it as a `if let cached = colors[colorKey]` /`else`
pair makes that explicit; a `?? { ... }()` form invites the double-construct bug.

**Note on workload exposure, revised by F5.** R1b's benefit tracks the cache
*hit* rate, since only a hit pays a redundant write -- so unlike R1 it grows on
workloads with few distinct colors. In `benchmark-draw`'s fixture that rate is
near its ceiling despite the fixture cycling 216 foreground colors, because
`colors` is declared before the run loop (`:348`) and so persists for the whole
draw: at most 216 of the 8,000 runs at 160x50 can miss, putting the hit rate
above **97%**. R1b is therefore well-exercised there too, and both candidates
sit near their maximum exposure in the same instrument -- which is a further
reason the joint `benchmark-draw` number is an upper bound rather than a sizing
figure.

---

#### R2 -- replace `inactivePrimaryScreen == nil` with a non-copying test. **Rank 2.**

**What.** `Terminal.swift:553` and `:565` stop invoking
`Optional.==(Wrapped?, Wrapped?)`. Either pattern-match (`if case .some`) or add
a stored `isAlternateScreenActive: Bool` maintained at the single mutation site
(`Terminal.swift:4252`).

**Why second and not first.** It is nominally the *larger* share (F3: 22.5% of
its thread versus R1's 18.3%), but its thread carries 13% of process busy against
the main thread's 65%, so the absolute win is smaller. It also carries real
correctness surface that R1 does not: the getter's two nil tests drive
`cursorStreamRow`'s branch and `isAlternateScreenActive`, so a mis-spelled
replacement changes damage output rather than merely slowing it. That earns a
coverage audit before code.

It is placed second rather than deferred because it is **independent** -- a
different file, a different thread, a different instrument -- so it can be worked
in parallel with R1 without either confounding the other.

**Predicted impact.** `just benchmark-quick <base> terminal-feed`: **-8% to
-15%**, faster. `scrollback-stream`: similar direction, smaller. `content-churn`
and `style-churn`: **no move** -- and per doc 10's F9 that null is the *expected*
result, not a failed change. The felt effect is input-to-echo latency under a
firehose, which no current instrument scores.

**Why that range and not the raw 25% of `Terminal.feed`.** `benchmark-quick`
measures a feed workload end to end, not the getter in isolation, and doc 10
established that this harness dilutes node-level wins substantially -- it recorded
a quarter of the byte path removed for +0.03% and +0.63% on the render-bound
workloads (`10/F9`) and -14.55% / -23.66% on the feed-bound ones (`9/F4`). The
range above is scaled from the latter pair.

**What would falsify it.** `terminal-feed` failing to read faster, *and* the
tuple-destroy node still present in a re-post of the PTY tree. The second
condition matters: if the node is gone and the benchmark did not move, the
attribution was right and the harness cannot see it -- which is a doc 10 F9
result, not a refutation.

**Risk.** Low-medium. Behavioral, not structural: the tests must pin that
alternate-screen enter, exit, and resize produce the same
`isAlternateScreenActive` and the same `cursorStreamRow` projection as before.
Audit first; existing coverage may already suffice, and recording that it does is
a valid outcome.

---

#### R3 -- attribute and attack the CoreAnimation glyph-bounds thrash. **Rank 3, research only.**

**What.** Not a change yet. Establish (a) which glyphs actually reach
`CTFontDrawGlyphs` in a real capture, (b) whether the 64-entry outline cache
misses because of distinct-glyph volume or because of per-frame context churn,
and (c) whether batching runs that share font and colour into fewer
`CTFontDrawGlyphs` calls reduces the number of `DrawGlyphs` display-list ops and
therefore the number of dirty-of-drawing computations.

**Why third despite being the biggest number.** It is the largest attributed cost
in the profile -- 1,064 main-thread stall samples plus 424 outline-copy samples --
and the *least* actionable. Three reasons it must not be promoted:

1. **It is not all recoverable.** The 1,064 samples are a pipeline wait. Shortening
   the queue shortens the wait; it does not delete it, and this profile cannot
   bound the recoverable fraction.
2. **R1 and R4 change its input.** Both shrink the work `drawTextRuns` emits into
   the display list that this queue replays. The queue's cost may move without
   anyone touching it, and attacking it first would credit R3 with their effect.
   This is the Phase 3 gate.
3. **It is the door to doc 11's H3**, the renderer rewrite. Doc 11's whole
   discipline is not to walk through that door on a single sizing measurement of
   an unoptimized path. This file must hand F1 to doc 11 as evidence and let doc
   11's gate decide.

**Predicted impact.** Deliberately unstated. A prediction here would be a guess
dressed as a number, and the one honest statement is the bound: **at most** the
1,064 stall samples plus some fraction of the 1,316-sample queue, i.e. up to
**~25% of main-thread busy** and ~20% of process busy -- and plausibly much less.
The bound grew with F1's correction, which is a reason to keep R3 on the list,
not a reason to promote it past the Phase 3 gate.

**What would make it actionable.** The repeat capture is **done** (F6) and both
nodes held: `compute_dod_` 547 → 530, `CopyGlyphPath` 424 → 400, the blocked wait
1,064 → 1,065. What remains is the glyph-inventory answer. If the outline thrash
turns out to be a handful of glyph families, widening sprite coverage is a
targeted fix; if it is broad, it is an argument for doc 11's H3 and belongs in a
design doc, not here.

**Risk.** Not applicable -- nothing is proposed. The risk being managed is
*premature promotion*.

---

#### R4 -- scratch buffers and `reserveCapacity` in `drawTextRuns`. **Rank 4.**

**Landed 2026-07-28 (`07dd81f`); result in F9.** The hoist was taken and
`reserveCapacity` was not: a fixed per-run guess is wrong for both the 80x24 and
the 179x66 case, and hoisting removes the allocation outright, so capacity
converges on the frame's own maximum with no constant to choose. The predicted
band held on the instrument it was written for and was beaten 3x on the paired
app benchmark; "possibly nothing measurable" below did not happen.

**What.** Thirteen collections are allocated fresh per run: `characters`,
`candidateCells`, `fallbackCells` and the eight sprite accumulators declared at
`TerminalRenderExecution.swift:372-381` (`spriteRects`, `shadedSpriteRects`,
`geometricShapeTriangles`, `powerlinePaths`, `branchDrawingGeometries`,
`legacySpriteRects`, `boxDrawingStrokes`), plus `glyphs` (`:547`) and
`mappedGlyphs` / `positions` (`:556-557`). Hoist them above the loop and reset
with `removeAll(keepingCapacity: true)`.

**Why last.** It is the smallest *independently measurable* candidate (F2: ~190
samples across lines 547, 564-565, 500 and 499, plus the `memcpy` and
`_ArrayBuffer._consumeAndCreateNew` self-time), it is the most likely to be
absorbed by allocator noise -- doc 9 flagged exactly that about its own
unreserved-array item -- and it edits the same function as R1. Landing it with R1
destroys both attributions. It does not get R1b's exemption: at ~190 samples a
benchmark run *can* resolve it from R1's effect, so it owes its own measurement.

**Predicted impact.** `just benchmark-draw` full-frame: **-3% to -6%** on top of
R1. Possibly nothing measurable.

**Do not double-count.** Doc 9 already carries "unreserved array growth in
`drawTextRuns`, 14% of draw" as an open Phase 5 item. That item and R4 are the
same work seen in two profiles. Whoever picks it up should close doc 9's entry
and cross-link, not open a second one.

**Risk.** Low mechanically, but higher than R1 in one respect: hoisted mutable
state shared across loop iterations must be reset on **every** path, including
early `continue`s. A missed reset leaks the previous run's rects into the next
one, which is a visible rendering bug rather than a slowdown. Behavioral coverage
must include a run that produces sprites followed by a run that produces none.

---

- Tradeoffs and correctness risks: summarized per candidate above. The
  cross-cutting one is **sequencing**: R1+R1b before R4 (same function), Phase 2
  before R3 (R3's input changes), and each measured against an explicitly named
  pre-change revision rather than an inferred one.
- Recommendation: R1 with R1b, in parallel with R2; then R4; then re-capture;
  then hand R3 to doc 11.
- Direction review: **not yet given.**
- Selected direction: **none.** Phase 1's repeat capture gates everything.
- Behavioral verification: R1 and R1b need none beyond existing draw tests
  (output is bit-identical in both cases -- R1's value has one unchanged
  consumer, R1b stores what the unconditional write already stored). R2 needs an
  audit-first pass on alternate-screen state. R4 needs a sprite-then-no-sprite
  run sequence. All should protect observable behavior, not the chosen internal
  structure.
- Quantitative verification: per candidate above, against baseline `4ca27ee` or a
  later explicitly named revision.

## Rejected

Nothing rejected yet. When a candidate above fails to reproduce or fails its
benchmark, it moves here with the evidence against it rather than being deleted.

## Open questions and caveats

- **One profile.** Doc 9's two-profile rule is unsatisfied. Every share in this
  file is provisional and Phase 1's first task exists to fix that. A reader
  quoting a number from here without noting this is misusing it.
- **The workload is a human holding a key.** It is representative in shape and
  irreproducible in rate. This artifact attributes; it does not compare.
- **The binary is `4ca27ee`, not `HEAD`.** It predates `4de86b6`. Any A/B must
  name its own baseline explicitly rather than assuming this one.
- **The 4,256 main-thread "busy" figure includes 1,064 blocked samples.** Shares
  computed against it understate true CPU concentration by about a quarter.
  Stated where it matters; check it anywhere it is reused.
- **No instrument can see the compositing costs this file found.**
  `benchmark-draw` renders offscreen and never creates `CA::CG::Queue`;
  `benchmark-draw-app` goes through AppKit but is not sampled at the compositor;
  `benchmark-sample` runs fixture workloads, not real programs under real input.
  Phase 4 owns whether that gap is worth closing.
- **F4's plan/draw inversion is unexplained between two mechanisms** -- workload
  shape versus harness overhead -- and the distinction matters to doc 9's
  remaining ranking, not just to this file.
- **`FillRects` on the CG queue is plausibly DanTerm's own sprite output.** If
  the sprite families are ever revisited, this is the cost side of that decision
  and it has never been counted.
- **Doc 11's F1 needs a caveat it does not currently carry, and this file should
  not be the one to add it.** F5 establishes that `benchmark-draw`'s fixture
  never reaches the font path: `CTFontDrawGlyphs`, `CTFontGetGlyphsForCharacters`
  and `drawTextCell` are all uncalled. So doc 11's 15.6 ms at 160x50, and the
  ~23 ms extrapolation to 179x66 that its H1 rests on, measure a draw with **no
  glyph rasterization in it** -- while F2 measured `CTFontDrawGlyphs` at 17.8% of
  `drawTextRuns` on the real workload. Doc 11's existing caveat says the fixture
  is "btop-shaped and synthetic"; it does not say this.

  Why it matters beyond bookkeeping: doc 11's H3 is the claim that *CPU glyph
  rasterization has a floor no caching removes*, and it is the hypothesis that
  would justify a renderer rewrite. Its only sizing measurement never rasterizes
  a glyph. That does not refute H3 -- it may well understate the true cost and
  therefore *strengthen* it -- but it does mean the 23 ms figure cannot be read
  as "what a btop-shaped frame costs" in either direction without adjustment.

  **This file must not edit doc 11.** The finding is F5's; the decision about
  what it does to H1 and the H2/H3 gate belongs to doc 11's owner. Phase 3's
  hand-off task should carry F5 alongside F1 and F8.

## Outcome

Investigation in progress. **Phase 1 is closed. Phase 2 is two thirds landed:
R1+R1b (F7, H1 closed) and R2 (F8, H2 closed) are committed and measured; R4 is
the remainder.**

### Where a fresh agent should pick this up

1. Read D1. It carries the four candidates, each with a prediction, a
   falsification criterion, a named instrument, and a risk note. That is the
   whole actionable surface of this file.
2. ~~Start with R1+R1b.~~ **Landed 2026-07-28 (`919838f`), result in F7.**
3. ~~R2 is independent...~~ **Landed 2026-07-28 (`cd57fa7`), result in F8.**
4. **Start with R4.** It is the only unlanded Phase 2 item, and R1 -- the reason
   it was gated -- is now measured and committed. Baseline it against `919838f`.
5. R3 is research, not a change, and is gated behind Phase 2 for a reason stated
   in D1. Do not promote it.

Findings F1-F8 are recorded. The next free ID is **F9**, and the ledger already
reserves F9 for R4's result and F10 for the Phase 3 re-capture.

**One step needs the user and cannot be done by an agent:** a live `sample`
capture. It requires a person holding the down-arrow key in a focused DanTerm
window for 20 seconds. Phase 3 needs one; any re-measurement of H3 needs one.
When you reach it, pause and ask -- the exact command and gesture to hand over
are in "Re-capturing a live profile", and the standing rule against scripting the
input is in Investigation rules.

### What is already known and should not be re-derived

- **The evidence is three live captures.** F1 and F6 are the same process
  instance at commit `4ca27ee`; F7's run 3 is a *different* instance at
  `919838f`, so it is identified by binary mtime rather than by launch time. All
  optimized builds, all three artifacts in `.build/manual-profiles/` (disposable;
  every number is transcribed).
- **The analysis method, and its one trap**, are written out in "Reproducing the
  evidence". The trap already cost one wrong number: a function is printed as
  several sibling nodes at different offsets, so a per-node read understates it.
  That is how "720 blocked samples" should have been 1,064.
- **`benchmark-draw`'s fixture is not representative** and F5 says exactly how:
  one run per cell, and no cell reaches the font path. It is an upper bound on
  R1, not a conservative case. Do not quote its delta as a user-visible win --
  F2's 18.3% is the real-workload figure. F7 bears this out from the other side:
  the fixture reported -34% where the live share was 18.3%.
- **Two of D1's four predictions are now tested.** R1 beat its band by ~2x (F7),
  R2 fell short of its band in the right direction (F8). Both were measured
  against a baseline resolved *before* implementation. R3 and R4 remain
  unverified.

### What is owed to a neighbouring file

F5's second inference belongs to doc 11 and this file must not act on it: doc
11's F1 measures a draw containing **no glyph rasterization at all**, which bears
directly on its H2-versus-H3 gate. Phase 3's hand-off task carries it.
