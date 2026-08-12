<!-- Imported verbatim from docs/scratch/2026-08-12-ios-app.md on 2026-08-12: the brainstorm
dump that triggered doc 35. Its portability table and line counts come from an import census
and file skim, not from builds -- treat every claim as unverified until a ledger task in
README.md confirms it and records a finding. -->

# DanTerm iOS Remote Client — Context & Brainstorm Briefing

**Purpose of this document.** I want to add an iOS app to the DanTerm project that acts as a
client for a DanTerm instance running remotely on my MacBook, so I can continue work from my
iPhone while away from the machine. This document is a context dump plus the brainstorming done
so far. It is deliberately **not** a plan — I want you to produce the specifics. Where this
document proposes directions, treat them as candidate starting points to evaluate, revise, or
reject, not as decisions already made.

---

## 1. What DanTerm is

DanTerm (`github.com/danneu/danterm`, branch `master`) is a native macOS terminal emulator
written in Swift with no web runtime. It originally used libghostty as its engine; that was
removed and replaced with a hand-written terminal engine.

Distinctive features relevant here:

- Vertical tabs with collapsible tab groups; split panes that inherit CWD.
- Persistent pane alerts + macOS notifications (click to focus the originating pane).
- A `danterm` CLI (`ls`, `tab new`, `pane split`, `pane read`, etc.) that drives the running app
  over IPC.
- A bundled agent skill so Claude Code / Codex can drive tabs and panes programmatically. A major
  real-world use case is supervising coding agents running in panes.
- Config at `~/.config/danterm/config.json`; local and remote themes; session restore via shell
  integration.
- Distributed as a `.dmg` from GitHub Releases, plus a Nix flake with a Home Manager module.

Scale: **523 Swift files, ~159,600 lines.**

---

## 2. Repository layout and module sizes

```
lib/TerminalCore/        220 files   74,339 lines   terminal engine
lib/DanTermCore/          88 files   35,642 lines   Elm-architecture app model
lib/TerminalPTY/          39 files   12,932 lines   PTY host, pane session controllers
lib/DanTermSupport/       23 files    3,551 lines   portable side-effecting utilities
lib/DanTermProtocol/      32 files    3,416 lines   IPC/JSON-RPC types
app/                      52 files   16,006 lines   AppKit layer
```

Also present: `cli/`, `cli-tests/`, `app-tests/`, `tests-ui/`, `benchmarks/`, `integrations/danterm/`
(the agent skill), `themes/`, `tools/`, `docs/`, `plans/`, `impl-notes/`, `agent-docs/`,
`plan-terminal-engine/`, `justfile`, `flake.nix`, `hm-module.nix`, `build-app.sh`.

Notable individual files:

| File                                                                             | Lines                                               |
| -------------------------------------------------------------------------------- | --------------------------------------------------- |
| `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`                           | 7,894                                               |
| `lib/DanTermCore/Sources/DanTermCore/Update.swift`                               | 2,529                                               |
| `app/SwiftTerminalSessionView.swift`                                             | 1,525                                               |
| `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift` | 1,395                                               |
| `app/IpcServer.swift`                                                            | 91 (thin; dispatch lives in `app/AppRuntime.swift`) |

Project conventions: `AGENTS.md` / `CLAUDE.md` at root; design docs in `docs/design/`;
implementation plans in `plans/impl/` named `YYYY-MM-DD-HHMM-topic.md`. Code comments frequently
reference research/plan document IDs (e.g. "research/33 T25") and encode invariants rather than
merely describing mechanics — **these comments are load-bearing and should be read before
modifying the code they annotate.** Test-to-source ratio is high; there is a benchmark suite used
to verify performance work.

---

## 3. The existing IPC surface (this is the foundation for the whole project)

### Transport

`lib/DanTermSupport/.../ControlSocketListener.swift` + `IpcConnection.swift` serve a Unix domain
socket. Path resolution (`DanTermProtocol/SocketPath.swift`):

```swift
public func controlSocketPath(identity: DanTermInstanceIdentity = DanTermInstanceIdentity()) -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(identity.bundleIdentifier, isDirectory: true)
        .appendingPathComponent("control.sock", isDirectory: false)
}
```

Framing is JSON-RPC 2.0 over newline-delimited frames. `DanTermProtocol/IpcLineFramer.swift` is
**pure** — `Data` in, frames out, no socket assumptions — so it is directly reusable over any
byte transport.

### Method surface (`DanTermProtocol/Methods.swift`, verbatim)

```
hello, doctor.permissions, ls,
tab.new, tab.rename, tab.close,
pane.focus, pane.info, pane.split, pane.close, pane.input, pane.read, pane.rows, pane.zoom,
pane.tape, pane.tape.event,
theme.set,
agent.attach, agent.activity, agent.detach,
todo.list, todo.add, todo.edit, todo.done, todo.open, todo.delete, todo.clearCompleted
```

Supporting arg/type files: `CLIParser`, `Envelope`, `JSONValue`, `KeyTokens`, `InputEvent`,
`LaunchSpec`, `PaneSplitArgs`, `ReadPaneArgs`, `SendKeysArgs`, `TabNewArgs`, `TapePaneArgs`,
`IpcRequestContext`, `InstanceIdentity`, `EnvVars`, `DoctorFacts`, `DoctorPermissionsJSON`.

### The streaming primitive

`pane.tape --follow` emits `pane.tape.event` notifications carrying
`NeutralTerminalRecordingEvent` (`lib/TerminalCore/Sources/TerminalCoreRecording/`):

```swift
public enum NeutralTerminalRecordingEvent: Equatable, Sendable {
    case feed([UInt8])                                   // raw PTY output bytes
    case input(key: TerminalInputKey, modifiers: TerminalKeyModifiers)
    case paste(String)
    case focus(Bool)
    case mouse(NeutralTerminalMouseEvent)
    case resize(columns: Int, rows: Int)
    case viewport(NeutralTerminalViewportNavigation)
    case checkpoint
}
```

It is `Codable` (base64 for `feed`). **This is already a remote terminal wire format**, and it is
already exercised by the recording/corpus test infrastructure. The session-side entry points are
`paneTapeFollowStart`, `paneTapeFollowBatch`, and `addPaneTapeFollowNotice` on the session view,
with `DanTermSupport/PaneTapeFollow.swift` and `PaneTapeDumpPreparation.swift` alongside.

Key limitation: tape subscriptions are bound to the connection lifetime and torn down on
`ipcConnectionClosed`. There is no resume, no sequence numbering, and no server-side buffering.

---

## 4. Portability findings (import census, verified against source)

Every `Package.swift` currently declares `platforms: [.macOS(.v26)]` and nothing else. But the
actual platform coupling is far lighter than those pins suggest:

| Module                    | Imports                                                                        | Assessment                 |
| ------------------------- | ------------------------------------------------------------------------------ | -------------------------- |
| `DanTermCore`             | Foundation, DanTermProtocol **only**                                           | fully portable             |
| `DanTermProtocol`         | Foundation                                                                     | fully portable             |
| `DanTermSupport`          | Foundation, DanTermProtocol, Darwin ×2, CoreText ×1 (`FontAvailability.swift`) | all available on iOS       |
| `TerminalRenderPlanning`  | TerminalCore **only** (not even Foundation)                                    | fully portable             |
| `TerminalSpriteGeometry`  | Foundation **only**                                                            | fully portable             |
| `TerminalCore` (engine)   | no AppKit                                                                      | portable                   |
| `TerminalRenderExecution` | CoreGraphics, CoreText, IOSurface, + **AppKit in exactly one file**            | mostly portable; see below |

### The render seam is unusually clean

`TerminalRenderPlanning` (1,825 lines) states its own contract in its header: pixel geometry and
Apple framework types stay app-side. It emits `RenderFramePlan`, which is grid-space and fully
resolved — columns/rows, `defaultBackground`, `backgroundRuns`, `overlayRuns`, `textRuns`,
`decorationRuns`, optional `cursor`, canonical row-major order, all `Equatable & Sendable`.
`RenderColor` is three raw `UInt8`s, so theme resolution completes before anything
platform-specific begins.

`TerminalSpriteGeometry` (1,908 lines: box drawing, Braille, Powerline, block elements, legacy
computing) imports only Foundation.

In `TerminalRenderExecution` (2,600 lines total), the AppKit coupling is essentially:

- `NSFont.monospacedSystemFont(ofSize:weight:).fontName` — one call (`UIFont` equivalent exists).
- `NSAttributedString` (~10 uses) — this is Foundation, not AppKit; compiles on iOS as-is.

Everything else is CoreText/CoreGraphics, available on iOS.

### The one genuine porting problem: IOSurface

- `TerminalFrameBackingStore.swift` — 286 lines
- `TerminalFrameSwapchain.swift` — 172 lines

`app/SwiftTerminalSessionView.swift:304` does `layer?.contents = store.ioSurface`. IOSurface
exists on iOS, but assigning one to `CALayer.contents` is a macOS-supported path, not an iOS one.
Candidate approaches (cheapest first, all unevaluated):

1. `CGContext` → `CGImage` → `layer.contents` — correct, extra copy per frame, likely fine at
   phone grid sizes.
2. `CVPixelBuffer` + `CAMetalLayer` — closer analogue to the existing N-buffer rotation.
3. A real Metal glyph-atlas renderer — the plan's run structure is already atlas-shaped, but this
   is almost certainly not a prerequisite.

---

## 5. Anatomy of `SwiftTerminalSessionView.swift` (1,525 lines)

Declared as:

```swift
final class SwiftTerminalSessionView: NSView, NSTextInputClient, NSMenuItemValidation, TerminalSession
```

It is largely a **façade over `TerminalPaneSessionController`** — 77 call sites delegate outward.
It holds little terminal state of its own (mostly AppKit bookkeeping: tracking areas, marked text,
hovered link, pointer location). Rough breakdown:

- **~150 lines, non-portable but trivial.** The AppKit event surface is a wall of 4–6 line
  forwarders (`mouseDown`, `mouseUp`, `rightMouseDown`, `otherMouseDragged`, `mouseEntered`, …),
  each normalizing an `NSEvent` to a cell. The real logic lives in `normalizedCell` (14 lines) and
  `forwardPointerDown/Up/Move` (~50 lines), which are grid-space and reusable.
- **~250 lines, non-portable and probably unwanted on iOS.** `NSTextInputClient` (marked
  text/IME), `NSMenuItemValidation`, `resetCursorRects`, `updateTrackingAreas`, drag-and-drop, and
  `ensureLinkPreview` (171 lines — the largest method in the file, pure macOS hover chrome; iOS has
  no hover).
- **~400 lines, portable logic worth keeping.** `synchronizeGeometry` (38), `resolvedMetrics` (20),
  `publish(_ frame:)` (37), `publish(_ events:)` (26), `emitStateIfNeeded`, `renderedRowBounds`,
  plus the whole read/search/tape block: `readViewportText`, `readRowStructure`,
  `readPrimaryHistoryTail`, `primaryHistoryTailReader`, `paneTapeFollowStart/Batch`, `startSearch`,
  `setSearchNeedle`, `navigateSearch`, `endSearch`.
- **~200 lines, the actual rewrite.** `surfaceSwapchain`, `attach`, `present`, `presentAttempt`,
  `armPresentationRetryIfPending`, `retryPendingPresentation`, `rerenderIfSurfaceInputsChanged`.
  `SurfaceInputs` keys on `NSColorSpace`; `wantsUpdateLayer`/`updateLayer` is a macOS contract
  (`updateLayer()` deliberately does nothing but count, to enforce that the pane owns its pixels
  and AppKit never gets a second render path); `displayRefreshIntervalNanoseconds()` reads
  `window?.screen?.maximumFramesPerSecond` (iOS: `UIScreen` / `CADisplayLink`).

**Important:** porting this means re-establishing the _invariant_ ("the pane owns its pixels;
there is no second render path") against `CADisplayLink`, not translating code line by line.

---

## 6. The `TerminalSession` protocol — the key existing abstraction

`app/TerminalSession.swift:106`. Platform leakage is confined to two properties:

```swift
var hostView: NSView { get }
var paneWrapper: PaneWrapperView? { get set }
```

Everything else is platform-neutral: `state`, `stateObserver`, `onEvent`,
`onPrimaryHistoryMutation`, `hasSelection`, `sendText`, `sendInputText`, `sendInputKey`,
`setFocused`, `setVisible`, `setRenderingAvailable`, `refreshBackingProperties`, `applyTheme`,
`clearTheme`, `setFontSize`, `setFontFamily`, `setCopyOnSelect`, search methods, read methods,
tape methods, clipboard, `requestClose`, `tearDown`.

Related: `TerminalSessionStateObserver`, `TerminalSessionCallbackGate` (gates both callback
channels at teardown), `TerminalSessionRequest`.

---

## 7. Existing architectural context worth knowing

DanTerm follows an **Elm architecture**: views dispatch `Msg`; the pure
`update(&model, msg) -> [Command]` decides; `AppRuntime.perform` interprets `Command`s as side
effects. `Command` is a data enum of effect descriptions with no closures.

There is an existing plan document — `plans/impl/2026-05-29-pure-core-portable-support.md` —
that established the purity policy: `DanTermCore` = deterministic domain logic testable without
Cocoa/sockets/timers/filesystem; `DanTermSupport` = portable side effects that stay fast-testable.
It moved `IpcConnection`, `Debouncer`, `CLIPathInstaller`, and parts of `Persistence` out of core.
`scripts/core-purity-lint.sh` enforces only "no `import Cocoa/AppKit/SwiftUI`" — it does not catch
`Darwin`, `Process`, `FileManager`, `DispatchSource`, or `NSHomeDirectory`.

**Two points from that document bear directly on this project:**

1. It explicitly **deferred** migrating `DanTermCore` to a real SwiftPM target "until a concrete
   second consumer justifies it." An iOS app is arguably that consumer.
2. It rejected the real-target migration partly on the grounds of a _permanent per-field `package`
   access annotation tax_ across the model (citing
   `docs/design/2026-05-28-core-module-via-symlink.md`). **That objection has not been invalidated
   and should be re-examined rather than assumed away.**

Current mechanism: `app/DanTermCore` and `app/DanTermSupport` are **symlinks** into
`lib/*/Sources/*`, compiling core into the app as loose source rather than as a linked target.

There is also a known latent issue documented there: `abbreviateHome` / `NSHomeDirectory()` reads
taint _snapshot payloads_ (`.exportState`, the `ls` reply, `tabSnapshotJSON`) though not the model
itself. Since `ls` is a method a remote client will call constantly, this may matter more once
there are cross-machine consumers.

---

## 8. Brainstormed directions so far (candidates, not decisions)

### 8.1 Framing

The strongest framing found so far: **the iOS app is not a new application, it is a second
frontend to an app that already has a session abstraction and a complete command protocol.** The
CLI already drives the app remotely-in-spirit; the iOS app is a GUI for that same surface, plus a
transport that crosses machines.

A corollary worth weighing: if `TerminalSession` is split into a neutral control protocol and a
thin view-owning protocol, then a `RemoteTerminalSession` (driven by the tape stream instead of a
local PTY) becomes a peer of `SwiftTerminalSessionView`. That would make **Mac-to-Mac remote
attach** work through the identical code path — meaning the entire remote stack could be developed
and tested without ever building for iOS.

### 8.2 Transport (unresolved)

Options considered:

- **SSH tunnel to the Unix socket.** Works immediately, no new auth surface, no new infrastructure.
  Awkward on iOS (needs NIO SSH / Citadel), fragile across network changes.
- **Tailscale / WireGuard mesh + TLS listener bound to the tailnet interface.** NAT traversal,
  stable identity, survives cell↔wifi. Currently seems like the sweet spot but unvalidated.
- **Relay/broker service.** Handles the hardest reachability cases; requires running infrastructure.

Structural idea: rather than teaching `IpcServer` about TLS, add a **separate bridge process**
(`danterm-bridge`, or a `danterm serve` subcommand) that listens on the network, authenticates, and
proxies frames into the existing Unix socket. Keeps the app's security model untouched; runs under
launchd; independently killable; a natural home for rate limits, method allowlists, and an audit
log. `IpcLineFramer` drops in unchanged.

Also floated: extract an `IpcTransport` protocol (`open`/`send`/`receive`/`close`) so Unix socket,
TCP+TLS, and an in-memory test pipe are interchangeable — which would let reconnect/resume logic be
tested entirely in-process.

### 8.3 Session durability (identified as a hard problem)

Mobile connections drop constantly (backgrounding, network transitions). Today a tape subscription
dies with its connection and `writePaneTapeFollowRecords` writes straight to an `IpcConnection`.
Sketched direction: interpose a **tape broker** owning per-pane bounded ring buffers, subscriber
cursors, and monotonic sequence numbers, with something like
`pane.tape.resume(subscription, fromSeq)` so a reconnect backfills the gap rather than restarting.
A `pane.snapshot` (serialize grid state so a client can join mid-stream) is probably needed
regardless.

### 8.4 Geometry conflict (unresolved)

The pane's size is driven by the Mac window; an iPhone is ~40 columns. Blindly resizing would
destroy a tmux/vim layout waiting on the Mac. Sketched options: an _observe_ mode (read-only, local
reflow via `LogicalLineStore`) vs a _claim_ mode (mobile owns the size, restores on detach),
selectable per pane. Not investigated in depth.

### 8.5 Input and notifications

- `pane.input` + `KeyTokens` already exist; the missing piece is an iOS accessory key row
  (Esc, Ctrl, Tab, arrows, `|`, `~`, `/`).
- The socket dies when the app backgrounds, so "an agent is waiting on you" requires **APNs**. The
  Mac can talk to APNs over HTTP/2 directly with an auth key, so the bridge process could be the
  push sender with no third-party relay. Trigger plumbing largely exists already (OSC 777 alerts,
  `agent.activity`).
- Highest-value feature identified: **notification tap → pane, with quick-reply buttons for agent
  permission prompts.** This is reachable long before any renderer work — it needs only `ls`,
  `pane.read`, `pane.input`, and push.

### 8.6 Refactors that might make the iOS app simpler to build

Ranked by apparent leverage; all need evaluation:

1. **Make `DanTermCore` a real target (retire the symlink).** An iOS target cannot cleanly share
   loose source via `app/DanTermCore`. Payoff: `DanTermCore` imports only Foundation +
   `DanTermProtocol`, so the _entire_ app model — `Model`, `Update`, `ModelOperations`,
   `Projections`, `Persistence`, `TabTodo`, `SidebarItemStore`, `ScrollbarMath`, `DropZone`,
   `AlertPresentation` — plus its large pure test suite could be reused on iOS unchanged. Cost: the
   `package` annotation tax the May plan rejected.
2. **Split `TerminalSession`** into `TerminalSessionControl` (neutral) + a view-owning protocol;
   then implement `RemoteTerminalSession` as a peer. See 8.1.
3. **Extract a platform-neutral `PaneSurfaceCoordinator`** from the ~400 portable lines of
   `SwiftTerminalSessionView` plus the pointer-forwarding bodies, leaving a thin AppKit shell and
   allowing a parallel UIKit shell. Secondary benefit: presentation invariants become headlessly
   testable instead of only via `tests-ui`.
4. **Add platform pins and let the compiler find the truth.** Extend
   `scripts/core-purity-lint.sh` into a platform-layering lint so boundary violations fail at the
   seam rather than as downstream link errors.
5. **Headless mode** (`danterm serve --headless`): model + PTY host, no AppKit. Makes the server
   side independently runnable/testable, gives the tape broker a clean home, and turns any residual
   AppKit dependency into a compile error.

### 8.7 Rough phasing sketched so far

1. Bridge + read-only client (`ls` sidebar, `pane.read` snapshot, `pane.tape --follow` rendered as text).
2. Input (`pane.input` + accessory key row).
3. Push notifications + quick replies.
4. Real terminal on device (platform pins, then a UIKit/Metal execution layer over
   `TerminalRenderPlanning`).

**Open question flagged during brainstorming:** because the render seam is so clean and the tape
stream feeds `TerminalCore` directly, it may be better to link the real engine _early_ rather than
ship a text-only renderer that gets thrown away — you would get correct wide-character handling,
reflow, and mouse-mode behavior on day one. Estimated iOS shell size if done that way: ~500–700
lines, mostly new gesture/keyboard handling rather than ported logic. This tradeoff is unresolved.

---

## 9. Some additional details to think about

- Interrogate the assumptions above; several are inferences from an import census and file
  skim rather than from building anything.
- Decide and justify a transport, and an authentication/pairing model.
- Design the durable-subscription / resume / snapshot protocol concretely, including what changes
  in `AppRuntime` and where the broker lives.
- Resolve the geometry-conflict question with actual semantics.
- Take a position on the refactor sequencing in 8.6 — especially whether the `DanTermCore`
  real-target migration is worth its annotation cost _now_, given the May plan's explicit objection.
- Take a position on the early-vs-late engine linking question in 8.7.
- Identify what I have not thought of: security review of exposing a terminal to the network,
  App Store / signing implications, background execution limits, battery, offline behavior,
  multi-client conflicts, and what happens when the Mac sleeps.
