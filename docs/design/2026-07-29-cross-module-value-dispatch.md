# 2026-07-29: Cross-Module Dispatch on Hot Value Types

- Status: Accepted
- Date: 2026-07-29

## Context

`lib/TerminalCore` is not one module. It is a package of many SwiftPM targets, and the render
path crosses their boundaries on every frame: `TerminalCore` owns the grid and
the cell payload, `TerminalRenderPlanning` builds the frame plan from it, and
`TerminalRenderExecution` draws that plan. No target sets a
cross-module-optimization flag; every target carries only
`.swiftLanguageMode(.v6)`.

That layout has a performance consequence that is invisible in the source:

**Swift will not inline a function across a module boundary unless it is
`@inlinable`, and SwiftPM will not specialize a library's generics for another
module.** Inside the defining module, a small accessor on a value type compiles
to a couple of instructions. Reached from another target, the same accessor is
an opaque call; and a `Collection`/`Sequence` conformance consumed from another
target goes through **witness tables**, so each element access is a dynamic
dispatch that also blocks the optimizer from seeing the type's storage.

The cost is real and it is large. It has now been measured twice, in unrelated
code, and neither time did anything in the source hint at it:

- **`TerminalBenchmarkMarkerScanner`.** Handing the scanner its runs as a lazy
  generic sequence replaced the `String` cost it was built to remove with
  type-metadata and unspecialized-iterator cost *of the same size*. The fix was
  to make the entry point concrete over `RenderFramePlan`. Recorded in the "Keep
  the observer out of the profile" section of
  [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md).
- **`TerminalScalars`.** Its `RandomAccessCollection` surface carried no
  annotations at all, so every `endIndex`, `subscript` and `distance(from:to:)`
  from the render path was a cross-module call or a witness-table dispatch. An
  on-CPU profile put that traffic at **20.6% of the draw region** and **8.3% of
  the plan region**. Annotating it measured **-19.98% / -20.41% / -12.94%** on
  the three draw workloads at `benchmark-confirm`.

The first was rediscovered from scratch. This note exists so the second is the
last one that has to be.

It has already been used prospectively once. When `research/14/D3` needed a row-scoped
read on `Terminal` for the render planner, the obvious shape -- return a row
view and let the planner index it -- would have put a per-cell accessor across
this same boundary, and made it fast only by promoting the private `GridCell` to
`@usableFromInline`. The shape chosen instead (`forEachViewportCell(row:_:)`,
one cross-module call per row with the per-cell work kept inside the module)
avoids the mechanism rather than paying to annotate around it. That is the
cheapest way to apply this note: at design time, not after the profile.

The full investigation is
[docs/research/14-live-scroll-workload-profile.md](../research/14-live-scroll-workload-profile.md)
(F8, F9, D2).

## Decision

**A value type that crosses a SwiftPM target boundary on a hot path gets an
inlinable surface, and hot entry points stay concrete.**

Concretely, when a type in one target is consumed per-cell or per-element by
another:

1. **Annotate the collection surface `@inlinable`** -- `startIndex`, `endIndex`,
   `subscript`, and the index arithmetic. Accept the `@usableFromInline internal`
   this forces on the private storage; it is the price of the annotation, not a
   separate design choice.
2. **Spell out index arithmetic rather than inheriting it.** The stdlib's
   defaults for an `Int` index are correct but arrive through conformance
   witnesses the consuming module cannot inline. `count`,
   `underestimatedCount`, `index(after:)`, `index(before:)`,
   `index(_:offsetBy:)` and `distance(from:to:)` are one line each and were each
   visible in the profile.
3. **Keep cross-boundary entry points concrete, not generic.** A generic
   parameter that is not specialized costs type metadata and unspecialized
   iteration -- often as much as whatever it was introduced to avoid.

**What this does not say.** It is not "annotate everything `@inlinable`". The
gate is a *measured* hot path crossing a *target* boundary. Annotating a cold
type buys nothing and permanently widens what the module has to keep stable.

**Cross-module optimization as a build flag was considered and not adopted.** It
needs no source edit, but it is build-wide rather than confined to the hot path,
it lengthens builds, and it makes the win invisible in the source -- a future
reader has no way to see why these accessors are fast, and would strip the
reason along with the annotations. It stays available as a fallback if a
targeted annotation ever underdelivers.

## How to recognize it in a profile

Two symbol shapes distinguish this cost from its neighbours, and confusing them
sends the fix in the wrong direction:

| Frame | Meaning | Fix |
| --- | --- | --- |
| `protocol witness for X in conformance Y` | Conformance consumed through a witness table, unspecialized | `@inlinable` / concrete entry point |
| `Y.someAccessor.getter` as a standalone frame | Cross-module call that did not inline | `@inlinable` |
| `outlined copy of Y.Storage` / `outlined consume of Y.Storage` | **Value-witness traffic** -- copy/destroy of a non-trivial type | Not this. A layout question. |

The third row is a different problem with a different answer, and in this repo
it has already been investigated to a conclusion: see
[docs/research/12-cell-representation.md](../research/12-cell-representation.md),
whose POD-cell change was implemented, measured **+6.74% slower** on
`scrollback-stream`, and reverted in `94a1528`. Do not reach for a
representation change on the strength of an `outlined` frame without reading
that file first.

`TerminalScalars` carried **both** costs under one set of symbol names -- 4.95%
of main-thread on-CPU in witness/call frames and 6.26% in value-witness frames.
Only the first half was addressable here. Splitting a hot type's profile into
these two classes before proposing anything is the practical form of this note.

## Consequences

- **`Storage` and `storage` on `TerminalScalars` are `@usableFromInline
  internal`.** Source-level encapsulation is unchanged: the render modules could
  not name `Storage` when it was `private` and still cannot. What changed is
  that its shape is now ABI-visible, so changing the enum's cases is a
  wider-reaching edit than it was.
- **The annotations are load-bearing and must not be tidied away.**
  `TerminalScalars.swift` carries a header block saying why they exist. Any
  future edit that removes them is a ~20% draw-path regression that no test will
  catch -- which is precisely why the reason lives next to the code rather than
  only in a research file.
- **This is a performance invariant with no automated cover.** No test asserts
  that these accessors inline, and none should: that is a statement about the
  optimizer, not about behavior, and pinning it would be a structure-coupled
  test. The cover is this note plus the recorded benchmark identities in
  `1323a6d`.
- **Measure against the region's own denominator.** A profile share of the whole
  main thread is not comparable to a benchmark verdict that brackets only
  `draw(_:)`. The `TerminalScalars` work looked like a 4.95% opportunity against
  the thread and delivered ~20% against the draw region; both numbers were
  right. Convert before predicting, or the result will look implausible and
  invite a wrong correction.
- **Expect the grid path not to move.** Calls that were already same-module were
  already inline. On `TerminalScalars` this produced a null result on
  `terminal-feed` and `scrollback-stream`, which is what identified the win as
  cross-module dispatch rather than something incidental to the edit. A change
  under this note that moves *every* workload deserves a second look.

## References

- [docs/research/14-live-scroll-workload-profile.md](../research/14-live-scroll-workload-profile.md)
  -- F8 (the attribution and its split), F9 (the benchmark), D2 (the decision).
  D1 records a candidate rejected from the same trace for being too small to
  measure.
- [docs/research/12-cell-representation.md](../research/12-cell-representation.md)
  -- the value-witness half, investigated to a conclusion and rejected.
- [agent-docs/terminal-performance.md](../../agent-docs/terminal-performance.md)
  -- "Keep the observer out of the profile" for the first instance; "Choose a
  profiler" for `benchmark-trace` versus `benchmark-sample`.
- `1323a6d` -- the `TerminalScalars` change and its recorded benchmark
  identities.
