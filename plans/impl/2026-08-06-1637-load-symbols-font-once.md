# Load the packaged symbols font once per process

## Context

A live `DanTerm Dev` instance with 31 panes held a 775 MB footprint. `heap`
attributed 90.8 MB to 36 copies of one file: the packaged Nerd Font symbols
`.ttf` (2,507,556 bytes on disk; 2,523,136 in its malloc bucket).

`NerdFontSymbolsResource.face(at:pointSize:)` reads the file and builds a font
descriptor from its bytes on every call. CoreText retains that byte buffer for
the descriptor's lifetime. The call sits inside `TerminalFontSet.init`, which
runs once per `TerminalRenderMetrics`, which is built per pane -- and rebuilt on
every geometry, scale, and font event. So each pane holds a private copy of the
whole font.

Ablation, three arms at n=36, measured directly:

| Arm | Footprint |
|---|---:|
| Fresh load per font (current) | 87.8 MB |
| One shared buffer, bridged per font | ~3.1 MB |
| One shared parsed resource, N fonts | ~2.9 MB |

The fresh-load arm scales linearly at ~2.56 MB per font and predicts 92.1 MB at
n=36 against the 90.8 MB observed live -- within 1.4%. Sharing recovers ~85 MB.
Sharing holds even across 36 *distinct* point sizes, so no per-size font cache
is needed.

Two premises the design rests on, both measured rather than assumed: bridging a
shared byte buffer per pane does not copy it (19.5 KB per pane, not 2.4 MB), and
one parsed resource serving many sizes stays flat.

Outcome: N panes retain one copy of the font, and the resource is read once per
process.

## Decision

The defect is a parameter type, not a missing cache. `TerminalFontSet` takes a
*reference* to the resource (a URL), so every construction site is a load site --
N construction sites, one resource. A cache would patch that mismatch at runtime;
changing what is passed removes it.

**Pass the loaded resource, not a path to it.** Font-set construction receives an
already-loaded, already-parsed symbols resource and only projects it to a point
size. The single load site is one immutable process-wide constant, initialized
lazily on first use.

Decisive properties of this direction:

- "Loaded once" is a property of the call graph, not a runtime invariant held up
  by cache discipline. No mutable global, no lock, no key, no eviction.
- It matches how this module already holds shared state: every existing instance
  is an immutable constant table. A cache would introduce the module's first
  mutable global.
- The resource handed to font-set construction is parsed, so constructing a font
  set decodes nothing.
- The test seam improves. Tests currently inject a deliberately-bogus path as a
  proxy for "resource unavailable"; they can instead inject the real condition.
  A URL-taking load path remains for that, uncached, so a failed load allocates
  nothing.

## Invariants

- **I1** N terminal panes retain one copy of the packaged font's bytes.
- **I2** The packaged resource is read at most once per process, and only if
  something needs it -- a run that builds no terminal never reads it. The single
  load site is a `static let`, so both halves are Swift's once-initialized
  static-storage semantics rather than a runtime property to be policed; the only
  way to lose laziness is a reference from startup code, which is read off the
  call graph.
- **I3** An absent or unreadable symbols resource disables the symbols face
  rather than letting an installed font of the same name stand in for it.
- **I4** The symbols face draws at one-cell em size and does not take over the
  sprite, base-face private-use, or supplementary private-use routes.
- **I5** Font sets compare by the properties that affect drawing, not by object
  identity -- so sharing a resource between two font sets does not change whether
  they are equal.

## Proof obligations

- **PO1** (I1, I2) A test pins that repeated resolution of the packaged resource
  yields the same loaded object. Assert reference identity: attribute-based
  equality on these CoreText values is an observed behavior rather than a
  contract, and would pass with the sharing removed.
- **PO2** (I3) The existing coverage for a nil resource and for an unreadable one
  stays green, restated against the loaded-resource seam.
- **PO3** (I4) The existing byte-for-byte render comparisons for icon rendering,
  route precedence, and scratch-buffer isolation stay green unmodified. These are
  the regression surface for the whole change; they must not be edited to pass.
- **PO4** (I5) The existing equality coverage stays green, and the source URL
  remains observable on a font set.
- **PO5** (I1, magnitude) The ~85 MB is confirmed outside the test suite, by a
  live measurement on a running instance. Deliberately
  not a unit test: heap readings cover the whole process and suites run in
  parallel, so a heap assertion in a test measures its neighbours.

## Non-goals

- The eagerly-materialized scrollback arenas (~500 MB of the same footprint).
  Owned by another agent.
- The unconditional metrics rebuild in the pane view, which constructs metrics on
  every geometry event before comparing them to the current value. This change
  drops that cost by roughly two orders of magnitude, removing its memory
  consequence; the remaining CPU churn is a separate follow-up.
- Caching font sets or render metrics themselves.

## Accepted risks

- **AR1** The loaded resource is held for the process lifetime. Intended: every
  pane needs it, and it is a small fraction of the app's footprint. Eviction
  would reintroduce repeated multi-megabyte reads and a window where duplicate
  buffers coexist.
- **AR2** A missing packaged resource is remembered for the process lifetime.
  Sound because the resource ships inside the app bundle and cannot appear
  mid-run.
- **AR3** The three-arm ablation in Context is a design experiment, not a
  committed artifact, so its numbers are not re-derivable from the repo. The live
  `heap` reading is the reproducible magnitude check, and the design question the
  ablation settled -- shared buffer versus shared parsed resource -- is closed by
  RI2 rather than re-opened per implementation.

## Rejected ideas

- **RI1** A URL-keyed memo around the existing load. Same memory result, but
  keeps the reference-typed parameter, adds the module's first mutable global
  plus a lock, and needs a "the bytes behind a URL never change" assumption that
  the structural version never has to make.
- **RI2** Sharing the raw bytes instead of the parsed resource. Measured to work,
  but it leaves font decoding inside font-set construction and re-parses per
  pane.
- **RI3** Additionally caching the per-size faces. Measured headroom is ~10 KB
  per font, ~0.4% of the win, against a second cache key and an eviction
  question.

## Critical files

- `lib/TerminalCore/Sources/TerminalRenderExecution/NerdFontSymbolsResource.swift`
  -- the load path and the new process-wide constant.
- `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`
  -- `TerminalFontSet` and the internal `TerminalRenderMetrics` test seam take the
  loaded resource; font-set equality and the observable source URL are preserved
  here.
- `lib/TerminalCore/Tests/TerminalRenderExecutionTests/NerdFontSymbolsExecutionTests.swift`
  -- holds all of PO2/PO3/PO4; adds PO1.
- `lib/TerminalCore/Sources/GlyphPreview/main.swift` -- second consumer of the
  resource; today it loads the font a second time within a single run.

`lib/TerminalPTY/Sources/TerminalPTYHost/ResizeCoalescer.swift` is the house
idiom for module-level shared state if any synchronization turns out to be
needed; the direction above is chosen so that it is not.

## Verification

1. TDD order per `AGENTS.md`: write PO1 first and confirm it fails against the
   current per-call load before changing anything.
2. `swift test --package-path lib/TerminalCore --filter TerminalRenderExecutionTests`
   for PO1-PO4, then `just test` as the gate.
3. PO5, magnitude: build with `just launch-slot-optimized`, open a comparable
   number of panes, and confirm with `heap` that the packaged font appears once
   rather than per pane. Read the live instance the same way the original finding
   was taken: `heap <pid>` sorted by total bytes.

Note that `scripts/terminal-fixed-cost-probe.py` is blind to this change:
`TerminalMemoryProbe` is headless with no renderer and never builds a font set.
It measures the arena work only.

## Implementation discretion

- How the loaded resource is spelled as a value, and how it satisfies `Sendable`
  given CoreText's types -- the module already makes this assertion twice in this
  file, with its rationale written out.
- Whether the source URL is stored on the font set or forwarded from the loaded
  resource, provided it stays observable and equality is unchanged.
