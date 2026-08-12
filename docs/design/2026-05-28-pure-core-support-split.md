# Pure Core / Portable Support / Platform Runtime: a Purity-Enforced Three-Layer Split

`Status`: Accepted
`Date`: 2026-05-28

> **2026-08-06: naming superseded by the libghostty removal.** The three-layer
> split, the `CoreEnv` seams, and the worked example are unchanged and still
> normative -- this is the document `AGENTS.md` routes layer-placement questions
> to. Only the framework naming is stale: GhosttyKit is gone, so every "no
> AppKit/GhosttyKit" below now reads as "no AppKit". `core-purity-lint.sh` kept
> its Cocoa/AppKit/SwiftUI ban and lost the GhosttyKit one, which could no
> longer fire once no target declared the module. The body is unedited on
> purpose.

> **2026-08-12: support target and cross-process contracts.** The `danterm`
> CLI became a real second consumer of portable support when `doctor` needed
> filesystem, config, and CoreText probes without compiling the app core. The
> root package now exposes DanTermSupport as an importable target for the CLI;
> the app still compiles the same sources through `app/DanTermSupport`. The
> config schema moved to DanTermProtocol because the app and CLI read the same
> versioned file, widening that leaf from wire protocol to cross-process
> contracts generally. The current dependency graph is:
>
> ```
> DanTermProtocol  (leaf; wire protocol + CLI parsing + cross-process contracts)
>       ^                         ^
>       |                         |
> DanTermCore (pure)        DanTermSupport (portable effects)
>       \                         / ^
>        \                       /  |
>         app (same-module symlinks) CLI (imports support; no core dependency)
> ```
>
> The earlier "one public-surface addition" claim describes the original split,
> not the current tree. DanTermProtocol now also publishes the config schema,
> while the root-package doctor entry point uses `package` access so it does not
> create a durable external support API. The sibling invariant still holds:
> support names nothing in core.

## Context

DanTerm follows an Elm architecture: views dispatch `Msg`, the pure
`update(&model, msg, env:) -> [Command]` decides, and `AppRuntime.perform`
interprets each `Command` as a side effect. The intended invariant is "core
decides, runtime does": `DanTermCore` should be deterministic domain logic,
fully unit-testable without Cocoa, GhosttyKit, sockets, timers, processes, or
the filesystem.

That invariant was mostly real -- the decision logic is pure and exhaustively
tested, and `Command` is a data enum of effect descriptions with no closures --
but it was neither enforced nor entirely true. A handful of side-effecting
*utilities* had been filed in the core directory because they happened to need
no AppKit/GhosttyKit and were convenient to unit-test there:

- `IpcConnection` -- Unix-socket read/write (`Darwin.read/write`, `DispatchQueue`,
  `setsockopt`).
- `Debouncer` -- a `DispatchSourceTimer` wrapper.
- `CLIPathInstaller` -- `Process` (osascript) + `FileManager` symlink install.
- Recovery-path resolution + session-lock IO in the persistence file
  (`FileManager`, `Data(contentsOf:)`, `data.write(to:)`).
- Trivial file-load wrappers: `DanTermConfigParser.loadFromDisk()`,
  `ThemeColorParser.parse(themeFileAt:)`, and the `NSHomeDirectory()`-based
  `configFilePath()`.
- Ambient reads inside otherwise-pure code: `abbreviateHome`/`expandTilde`/
  `configFilePath` all called `NSHomeDirectory()`.

These slipped in because the only purity guard was `scripts/core-purity-lint.sh`,
which forbade `import Cocoa/AppKit/SwiftUI` and nothing else -- nothing stopped
`import Darwin`, `Process`, `FileManager`, `DispatchSource`, or `NSHomeDirectory`.
The nested test package (`lib/DanTermCore/Package.swift`) compiles the core
without GhosttyKit, so GhosttyKit creep *was* caught, but Foundation/Darwin IO
was invisible to both guards.

An earlier plan (`polish-this-into-a-vectorized-stearns.md`) addressed a
different axis: make `DanTermCore` a real importable SwiftPM target, delete the
`app/DanTermCore` symlink, and add `package` access annotations across the
model. That is mechanically viable, but it does not protect the purity invariant
(Foundation IO compiles in any target -- a module boundary only controls *who
can name a symbol*, not *what side effects it performs*), and it pays the
permanent per-field annotation tax that
[`2026-05-28-core-module-via-symlink.md`](2026-05-28-core-module-via-symlink.md)
deliberately rejected.

This ADR records the reframe: make the domain core *genuinely* pure, move
portable side effects to a sibling layer that stays fast-testable, keep the
proven symlink mechanism, and defer the real-target migration until a concrete
second consumer justifies it.

## Decision

The codebase is split into three layers plus the existing protocol leaf, with a
single acyclic dependency invariant.

```
DanTermProtocol  (leaf; CLI parser + JSON-RPC envelope + IPC line framer)
      ^                         ^
      |                         |
DanTermCore (pure)        DanTermSupport (portable effects)   <- siblings; neither imports the other
      \                         /
       \                       /
        app  (compiles core + support same-module via symlinks; real `import DanTermProtocol`;
              links AppKit + GhosttyKit; interprets Commands)
```

- **`DanTermCore`** -- pure, deterministic domain logic. `Model`, `Msg`,
  `Command` (data), `update`, `ModelOperations`, `Projections`, the
  snapshot/restore/merge/validation codec, parsers/validators, classifiers, and
  `CoreEnv`. No sockets, files, timers, processes, AppKit, or GhosttyKit.
- **`DanTermSupport`** (new) -- portable side effects: `IpcConnection` (socket
  lifecycle), `Debouncer` (timer), `CLIPathInstaller` (Process/FileManager), and
  `RecoveryStore` (recovery-path helpers + session-lock IO + the `SessionLock`
  type). It performs real IO but needs no AppKit/GhosttyKit, so it gets the same
  fast unit tests the core enjoys.
- **`app/`** -- the runtime: `AppRuntime` (the `Command` interpreter), `IpcServer`
  (accept loop), checkpoint scheduling/writing, notifications, terminal session
  creation, all AppKit, plus the trivial file-IO wrappers (`loadFromDisk`,
  `parse(themeFileAt:)`, `DanTermConfigPaths.configFilePath()`).
- **`DanTermProtocol`** -- unchanged role (CLI parser + IPC envelope), and it
  gained the IPC line framer (see below).

### The dependency invariant

> **Core depends on nothing impure; support depends on nothing in core.**

`DanTermSupport` depends only on `DanTermProtocol` + Foundation/Darwin -- *not*
on `DanTermCore`. Keeping the sibling modules dependency-free is what keeps the
whole split annotation-free: `app -> core` and `app -> support` are same-module
(via the tracked symlinks `app/DanTermCore` and `app/DanTermSupport`), so every
moved symbol stays `internal` with zero new `package`/`public` annotations, and
`core <-> support` simply has no edge to annotate.

Two consequences of the invariant shaped *where* code moved:

- **The framer moved to `DanTermProtocol`.** `IpcLineFramer`/`IpcFrameEvent`
  (newline-delimited JSON-RPC framing) is a transport-protocol concern. Putting
  it in the protocol leaf is what lets `IpcConnection` depend on protocol, not
  core. This is the **one public-surface addition the entire split made**:
  `public enum IpcFrameEvent`, `public struct IpcLineFramer`, `public init()`,
  `public static let maxLineBytes`, and `public mutating func append(_:)`. The
  module that gained the `public`s was already public by design.
- **`SessionLock` moved to `DanTermSupport`.** Its only consumers are the
  recovery IO helpers (now in support) and the relocated round-trip test, so it
  travels to support rather than forcing a `support -> core` edge.

If a future change ever makes support genuinely need a core type, prefer moving
that type to the protocol leaf (if it is protocol-shaped) or duplicating a tiny
value over introducing a core-facing `public` surface in support.

### Purity is enforced by lint + nested package

Purity is proven *structurally* and guarded *heuristically*:

- **Structural proof (the real guarantee).** The nested test packages
  (`lib/DanTermCore/Package.swift`, `lib/DanTermSupport/Package.swift`) compile
  each layer standalone. A core file that reaches for a moved symbol, gains
  `import GhosttyKit`, or takes a `DanTermSupport` dependency fails to resolve
  under `swift test --package-path lib/DanTermCore`. Support proves the mirror:
  it compiles and tests with no AppKit/GhosttyKit and no dependency on core.
- **Heuristic regression guard (`scripts/core-purity-lint.sh`, two profiles).**
  A separate module would *not* catch Foundation/Darwin IO -- the compiler
  enforces IO-freeness in no design -- so the lint closes that gap with a token
  denylist over comment/string-stripped lines:
  - **`pure`** (target `lib/DanTermCore/Sources/DanTermCore`): the Cocoa import
    rule, plus **hard bans** (no allowlist) on `import Darwin`/`Network`,
    `FileManager`, `Process(`, `DispatchSource`, `DispatchQueue(`, `.asyncAfter`,
    `Timer(`, `URLSession`, `NSWorkspace`, `setsockopt`, `Data(contentsOf:`,
    `.write(to:`, `ProcessInfo` -- this code belongs in `app/` or
    `DanTermSupport`, never the pure core. Plus **banned-with-allowlist** tokens:
    `NSHomeDirectory`, bare `UUID()`, bare `Date()` (empty parens only, so the
    deterministic `UUID(uuidString:)`/`Date(timeIntervalSince1970:)` parses never
    trip).
  - **`portable`** (target `lib/DanTermSupport/Sources/DanTermSupport`): the
    Cocoa rule plus a `GhosttyKit` import rule and nothing else -- support
    legitimately performs portable IO, so the pure-tier IO bans do not apply.

The lint's denylist is a regression guard, not the proof; the structural compile
is the proof. The lint exists to keep it that way, and its failure message is the
teaching surface an implementer actually hits (see the next subsection).

### The determinism seam (home, ids, time)

The core's nondeterminism came from three ambient inputs -- home directory,
fresh ids, and wall-clock time -- which `CoreEnv` now seams behind explicit
call-site closures (`homeDirectory`, `newId`, `now`), with `static let live`
binding the real ambient values. `update()` and the restore builders default
their `env: CoreEnv` parameter to `.live`, so the entire existing pure-test
corpus and every app call site compile unchanged.

- **Ids** are made compiler-forced. The no-arg `TypedId.init()` (which minted a
  fresh `UUID()`) is **removed**, so the only way to mint an id in core is through
  `env.newId()`; off-seam id minting is now a compile error. The four restore
  builders that minted bare ids thread `env.newId()`; the test units re-add a
  no-arg `extension TypedId` so fixtures are unaffected.
- **Time** routes through `env.now()`; no bare `Date()` remains in core.
- **Home** is handled by a *narrow* seam, because `update()`'s model evolution is
  already home-clean: HOME never enters the `AppModel`, only the snapshot/IPC
  payloads `update()` hands back. So the leaf helpers `abbreviateHome`/
  `expandTilde` keep a defaulted `home: String = NSHomeDirectory()` (carrying
  every render caller for free), the save/send/restore paths take an injectable
  home, and the SHOWN render path (`TabModel` chrome, `deriveTabChrome`,
  `formatToolbarLabel`, the close-tab confirmation title) stays ambient and
  untouched.

The structural payoff is enforceability: confining `NSHomeDirectory()`/`UUID()`/
`Date()` to a small set of designated, marker-gated sites is what lets the lint
ban them everywhere else in core. Those sites are the **three designated ambient
seams** -- `CoreEnv.live` and the `abbreviateHome`/`expandTilde` leaf defaults --
each marked with a trailing `// core-purity: ambient-seam` comment that travels
with the code and survives edits. The marker relaxes only the three
banned-with-allowlist tokens; it never exempts a hard-ban token.

#### When to inject an ambient input: save/send/assert vs. show

This is the canonical rule the seam encodes. It generalizes to any ambient input
(home, ids, time, and anything similar a future change adds):

> Inject an explicit value when the result will be **SAVED** (to disk), **SENT**
> (over IPC), or **ASSERTED** (in a test) -- anything a second execution will
> compare against. Leave it **AMBIENT** (read the real value via a default) when
> the result is only **SHOWN** live and discarded (sidebar/toolbar titles, alert
> text).

Rationale: determinism only earns its keep where two executions are compared --
a restore round-trip, a test re-run, a CLI client parsing a response. A title
painted into one `NSAlert` is never compared against anything, so reading the
real `NSHomeDirectory()` there is both cheaper and more correct (it renders the
user's *current* home).

Worked example -- HOME:

- **SAVED/SENT.** `toSnapshot`/`toInitFile` (checkpoint to disk) and the
  snapshot-embedding IPC builders (`.exportState`, the `ls` reply, the per-tab
  snapshot JSON) take an injected home; the `update()`-internal builders pass
  `env.homeDirectory()`. This is why the recorded snapshot/export fixtures stop
  depending on the author/CI machine's HOME.
- **ASSERTED.** Restore (`loadValidatedInitFile` and friends) threads home down
  to `expandTilde`. In production it *defaults to ambient* -- a saved `~/foo`
  expands to the user's current home, which is the whole point of storing `~/`.
  The injectable home exists so a test can assert machine-independent expansion
  against a fixed home, not for production reproduction.
- **SHOWN.** Tab/toolbar chrome and alert text read the ambient default and are
  deliberately left alone.

The same rule is why **ids and time are injected but render text is not**: a
minted id or timestamp ends up SAVED in a snapshot and ASSERTED in a test, so it
must be reproducible; a path abbreviated for a sidebar row is only SHOWN, so it
stays ambient. Because the default is the *real* ambient value (not a fake), a
save/send/restore caller that forgets to inject still behaves correctly in
production -- it reads the user's real HOME; only a test or an internal builder
that *should* pin a value and forgets would be caught, by the
machine-independence behavioral tests.

This subsection is the canonical statement that the lint failure message
(`scripts/core-purity-lint.sh`) and `AGENTS.md` point back to, and that the
`CoreEnv.homeDirectory`/`abbreviateHome`/`expandTilde` doc comments restate at
the seam.

### Typed paths: stay `String` until path algebra arrives

Recorded so it is not re-litigated: pane/cwd path fields stay `String`. Adopt a
typed path only when path *algebra* actually arrives -- a file picker,
project-root detection, path completion, or directory-identity comparison -- and
at that point prefer absolute-vs-display *representation* types
(`AbsolutePath`/`DisplayPath`) over a bare `FilePath`. The bug class that bites
DanTerm is representation confusion (mixing a `~`-abbreviated display string with
a real absolute path), not path-component matching, so a representation-typed
distinction buys more than `FilePath`'s component algebra would.

### The deferred real-target migration

The real importable-target migration is deferred indefinitely, not abandoned.
Its plan (`polish-this-into-a-vectorized-stearns.md`) is parked as superseded
with the recorded trigger condition:

> Promote `DanTermCore` to a real importable target (with the `package`
> annotation tax and the symlink removal) only when a real second consumer must
> `import` the domain model -- e.g. the `danterm` CLI grows model logic beyond
> IPC, or a separate menu-bar app or XPC/privileged helper needs
> `AppModel`/`update`.

Today no such consumer exists: the CLI speaks IPC through `DanTermProtocol`,
which is already a real importable target. If the trigger fires, this
purity-first split makes that migration strictly cheaper and safer -- the core
will be smaller (no IO utilities to drag across the boundary), and the
annotations would then buy a real compiler-enforced boundary for a real client.
(`DanTermSupport` is the *cheaper* promotion candidate of the two, since its API
surface is a handful of entry points rather than a wide value-type model, so it
does not carry the model's per-field tax.)

## Consequences

- **Zero annotation tax.** The app reads every core and support symbol as
  `internal`, same-module via the two symlinks. The split added exactly two
  small `public` types in `DanTermProtocol` (the framer) and nothing else.
- **Purity is now a maintained property, not an accident.** The pure profile of
  the lint fails CI the moment `FileManager`/`Process`/`import Darwin`/an
  off-seam `NSHomeDirectory()`/a bare `UUID()`/`Date()` re-enters core; the
  nested packages prove the structural boundary on every test run.
- **Portable effects are fast-testable.** `IpcConnection`, `Debouncer`,
  `CLIPathInstaller`, and `RecoveryStore` test in a display-free,
  GhosttyKit-free package, the same ~1-2s loop the core enjoys.
- **The IPC and persistence layerings are explicit.** IPC: method semantics live
  in core `update()`; envelope + framing in `DanTermProtocol`; socket lifecycle
  in `DanTermSupport.IpcConnection`; the accept loop in `app/IpcServer`.
  Persistence: the pure codec in core; path resolution + file IO + session lock
  in `DanTermSupport.RecoveryStore`; checkpoint scheduling and the
  snapshot-to-disk write in `app`.
- **Save/send output is machine-independent.** With the home seam closed, the
  recorded snapshot/export fixtures no longer embed the recording machine's HOME,
  removing a latent cross-machine fragility. `GoldenMasterTests` was already
  home-clean (it asserts on the model) and needed no change.
- **The lint message is the enforcement point.** Because an implementer adding a
  new ambient read hits the lint failure before they hit any doc, the
  inject-vs-ambient rule is restated there and forward-references the
  "When to inject an ambient input" subsection above.
- **The real-target migration stays a one-decision pivot.** It is parked, not
  lost, behind a written trigger; revisiting it is a deliberate choice the day a
  real second consumer appears.

## References

- The master implementation plan that drove this design:
  `plans/impl/2026-05-29-pure-core-portable-support.md` (the pivot rationale, the
  determinism-seam derivation, and the phase-by-phase migration notes).
- [`2026-05-28-core-module-via-symlink.md`](2026-05-28-core-module-via-symlink.md)
  -- the same-module-via-symlink mechanism this split extends (reaffirmed, not
  superseded): the symlink + nested-package pattern is reused verbatim for
  `DanTermSupport`, and the access-control tax it rejected is what keeps this
  split annotation-free.
- `scripts/core-purity-lint.sh` -- the two-profile purity lint (and its self-test
  `scripts/tests/core-purity-lint_test.sh`) that enforces the core/support
  boundary and whose failure message points back at this ADR.
- The parked real-target plan: `plans/wip/polish-this-into-a-vectorized-stearns.md`.
