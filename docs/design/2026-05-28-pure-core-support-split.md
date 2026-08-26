# Pure Core / Portable Support / Platform Runtime: a Purity-Enforced Three-Layer Split

- Status: Accepted
- Date: 2026-05-28
- Amended: 2026-08-06 -- GhosttyKit naming dropped; 2026-08-12 -- support target
  and cross-process contracts. See the banners.

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
- **Strict concurrency (a second structural proof).** No target in any manifest
  is below `.swiftLanguageMode(.v6)` -- not the nested packages, and not the
  root ones the shipping app and CLI are built from. A new global mutable value
  or an unsafe capture in the pure layers therefore fails every build, not just
  the nested package suites: because `app/DanTermCore` and `app/DanTermSupport`
  are symlinks, a root build at `.v5` used to recompile those same files with no
  strict checking at all. Do not lower any target to `.v5` to silence a new
  error: the error is the point, and in the pure layers the value it names
  belongs in `app/`.
- **Heuristic regression guard (`scripts/core-purity-lint.sh`, three profiles).**
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
  - **`portable`**: the Cocoa rule and nothing else -- support legitimately
    performs portable IO, so the pure-tier IO bans do not apply.
  - **`ui`**: no check. A module that legitimately draws with a platform toolkit
    declares this, so an exemption is a written decision rather than an absence.

**Coverage is the lint's own responsibility, not the gate's.** Run with no
target, the lint discovers every first-party package through
`scripts/manifest_targets.py`, then checks every non-test target those
manifests declare, at the path each declares -- `app`, `cli`, a `TestSupport/`
helper, and the `Sources/*/` modules alike. It reads
`scripts/core-purity-policy.conf` for the modules whose contract deviates. The
floor for a module the policy never names is `portable`, so a new module is
covered the day its manifest declares it, and a module that may draw with a
platform toolkit is exempt only by a written `ui` line, never by sitting at a
path the sweep does not look at. The gate used to name its targets by hand --
eleven of them against a tree of thirty-five modules -- which made "nobody
remembered this module" and "this module is exempt" the same observation. A
policy entry naming a module that no longer exists fails the sweep, and so does
a declared target with no directory, because an entry that checks nothing still
reads as coverage.

The lint's denylist is a regression guard, not the proof; the structural compile
is the proof. The lint exists to keep it that way, and its failure message is the
teaching surface an implementer actually hits (see the next subsection).

### The determinism seam (home, ids, time)

The core's nondeterminism came from three ambient inputs -- home directory,
fresh ids, and wall-clock time -- which `CoreEnv` now seams behind explicit
call-site closures (`homeDirectory`, `newId`, `now`), with `static let live`
binding the real ambient values. A fourth input, `instanceIdentity`, joined
later on a different rationale -- see "The identity seam" below. `update()` and
the restore builders default their `env: CoreEnv` parameter to `.live`, so the
entire existing pure-test corpus and every app call site compile unchanged.

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

### The identity seam (authorization, not determinism)

`CoreEnv` carries a fourth closure, `instanceIdentity`, and it does not belong to
the save/send/assert rule above. The other three exist so two executions
reproduce; this one exists so pure dispatch can answer a question about
privilege: **which instance am I?** The `quit` IPC method ends the answering app
the way Cmd-Q does, and dispatch admits it only for an identity holding a
launcher pool slot (`DanTermInstanceIdentity.isLauncherPoolSlot`, slots 1
through 8). Production, the canonical `DanTerm Dev.app` at slot 0, and any bundle
identifier the scheme does not recognize are all refused.

Two consequences follow, and they are the reason this seam is called out rather
than folded into the list:

- **Never re-derived at a leaf.** There is no "SHOWN live and
  discarded" case for a privilege check, so no `DanTermInstanceIdentity(bundle:)`
  may appear inside a dispatch arm. `CoreEnv.live` is the only ambient read for
  privilege.
- **The default fails closed.** `.live` resolves `Bundle.main`, which inside a
  test harness is the harness bundle -- not a pool slot. A test that forgets to
  inject an identity therefore gets no privilege, which is the safe direction.
  This inverts the home seam's rationale, where the ambient default is the
  *correct* production value.

#### The same identity keys the paths, and it is resolved once

Privilege is not the only thing the identity answers. It also namespaces every
filesystem path the process owns: the control socket, the recovery directory
with both checkpoint tiers, the session lock and the IPC audit log, and the
scrollback replay directory. Those used to be six leaves, each re-deriving the
identity and each turning it into a path on its own. The lock, the checkpoints,
and the audit log then shared a directory only because every leaf happened to
take the same default -- and no test could redirect the checkpoint tiers at all,
so the real recovery flow could not be exercised.

One value now owns all of them: `DanTermSupport.DanTermInstancePaths` stores an
identity plus the three roots (Application Support, Caches, temporary) and
derives every path from them. It defaults nothing, and neither does anything in
the chain that carries it. `app/LaunchInstancePaths.swift` builds it once from
`Bundle.main` and the user-domain directories, `app/main.swift` hands it to the
delegate, which hands it to the runtime, which composes what the IPC server
needs. A test builds the same value on a temporary root and drives the whole
flow without touching the user's real Application Support tree.

`scripts/ambient-identity-lint.sh` holds that shape: resolving the running
process into an identity or into a user-domain root is allowed in the launch
resolver, in `CoreEnv.live`, and in `DanTermProtocol.userControlSocketPath` --
which serves the bare executables (the `danterm` CLI and the identity tool) that
own no launch-resolved value, and takes its identity as an explicit input. The
lint names those three files and rejects the pattern everywhere else in `app/`,
`lib/`, `cli/`, and `tools/`.

#### The config file is launch-resolved too, beside the paths value

The identity does not key the config file. Production and the canonical dev app
are two identities that deliberately read one file, so folding it into
`DanTermInstancePaths` would make that type's name false. It is instead a second
launch-resolved value, handed down the same chain: `app/main.swift` resolves a
`--config <path>` argument, or the standard per-user file when there is none,
before anything reads config, and a `DanTermConfigStore` that was not told which
file it means cannot be built.

The same lint holds that shape, with two more rules. Each carries its own
allowlist, never an extension of the identity list -- appending would license the
config seam to resolve user-domain roots and the launch resolver to spell config
strings. One rejects the `DanTermConfigPaths` symbol outside the file that
declares it, the app's launch resolver, `cli/main.swift`, and the bundled
launch-facts tool; the CLI and the tool are bare executables that own no
launch-resolved value, the same carve-out `userControlSocketPath` has. The CLI
resolves the home its doctor probes share and derives the config file from it
once. The tool only reports the standard path, for the one caller the lint cannot
sweep: the development slot launcher is a Python process, and a path spelled there
would be a resolution no rule reaches. The other rule rejects the
`.config/danterm` path fragment spelled by hand, even where the symbol is allowed:
a literal is a second answer no rename reaches.

The launcher is the reason the config file has to be an argument at all. It gives
each pool slot a file of its own under the slot root, clears it on every launch,
and passes it as `--config`, so no slot operation -- launch, reload, a Preferences
save, `Open Config` -- can reach `~/.config/danterm/config.json`. A `--tailnet`
launch is the one thing copied across, and it is a copy into a regular file, never
a link back to the user's.

Because a slot and the user's app read different files, `danterm doctor` asks the
instance which file it read: the `doctor.appFacts` reply carries that path beside
the permissions, and doctor probes and names it. The instance is the only
authority on the answer -- a flag or a second derivation in the CLI would be a
third one. With no instance answering, doctor falls back to the standard file
under the same home its other probes read.

#### The same owner answers what mode the path is created with

A path this process owns is not fully specified by its name. A security audit
found fifteen creation sites across the product, of which only two set a mode at
creation, and the three that set one at all disagreed on how -- so the recovery
directory holding every pane's scrollback reached 0700 only because the IPC audit
writer happened to `chmod` it on the first `danterm` invocation, and the enriched
checkpoint beside it stayed 0644. Nothing was wrong at any one site; nothing
owned the question.

So the mode is the second half of the same invariant. `PrivateFile` is the sole
creator of a file or a directory in either shipped product -- the Mac app with
its CLI, and the phone app -- and it creates them 0600 and 0700 by stating
the mode rather than inheriting the process umask. Every create goes `open`/`mkdir`
with the mode and then `fchmod`/`chmod`: the umask can only narrow the syscall's
argument, so the second step is what states the mode exactly. Its atomic write
modes the temp sibling before the rename, so no world-readable name for the
content exists at any instant, and `bindSocket` returns a descriptor that is
already bound and already 0600 -- the caller does the `listen()`, and cannot
reach the fd before the mode is on the node.

Privacy is what a caller gets by default, so there is nothing for the next writer
to omit. Which process a create runs in is not the test: the phone app has its
own container and its own launch, and its pane-replica checkpoint holds a pane's
terminal state exactly as the Mac app's does. It is `lib/PrivateFile`, a package that depends on nothing and declares
both macOS and iOS, rather than a file beside `DanTermInstancePaths` in
`DanTermSupport`. The seam has to be reachable from every tree that creates
anything, and `DanTermSupport` is the Mac host's own side-effect layer -- pinned
to macOS, carrying sockets and CoreText -- so a consumer there would take a host
role along with the seam.

Wanting the umask default is the thing that has to be said out loud, and exactly
two classes of artifact say it. The **config artifacts** are the config file at
`~/.config/danterm/config.json` and its directory, which the user edits by hand.
The **CLI installation artifacts** are the `danterm` symlink the user inspects on
their PATH, and any destination parent the privileged install branch creates by
shelling out under `osascript` -- a shelled-out `mkdir` cannot route through the
seam, while the unprivileged branch's parent does. None of them carry terminal
content. Path is not the test -- the state export the user picks a destination for
with `NSSavePanel` is private, because it holds every pane's scrollback.

`scripts/private-file-mode-lint.sh` holds that shape the way the identity lint
holds the other half: it rejects creating a file or a directory anywhere in
`app/`, `lib/`, `cli/`, and `ios/` outside the seam and the files its allowlist
names. Those four roots are the trees that compile into a shipped first-party
product, which is why the seam is `lib/PrivateFile` and depends on nothing --
every one of them has to be able to reach it. `tools/` is out of the sweep
because source-maintenance tools rewrite git-tracked files and preserve the modes
they find; `Tests/` and `TestSupport/` are out because a fixture that stages a
0644 file is how the seam's narrowing is proven at all. Being a text search, it catches the creation spellings this codebase uses
and is a regression guard, not a proof.

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
  in `DanTermSupport.IpcConnection`; the accept loop in `app/IpcServer.swift`.
  Persistence: the pure codec in core; path resolution + file IO + session lock
  in `DanTermSupport.RecoveryStore`; checkpoint scheduling and the
  snapshot-to-disk write in `app`.
- **Save/send output is machine-independent.** With the home seam closed, the
  recorded snapshot/export fixtures no longer embed the recording machine's HOME,
  removing a latent cross-machine fragility. The tests that assert on the model
  rather than on its saved output were already home-clean and needed no change.
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
- `scripts/core-purity-lint.sh` -- the purity lint (and its self-test
  `scripts/tests/core-purity-lint_test.sh`) that enforces the core/support
  boundary and whose failure message points back at this ADR. Its per-module
  policy is `scripts/core-purity-policy.conf`.
- The parked real-target plan: `plans/wip/polish-this-into-a-vectorized-stearns.md`.
