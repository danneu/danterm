# Per-pane agent session awareness (Claude / Codex)

## Context

DanTerm panes routinely host coding-agent CLIs (Claude Code, Codex). Today
DanTerm has no idea an agent is running inside a pane. Two things would make
the agent-centric workflow much better:

1. **Live toolbar state** -- show "Claude `<id>`" / "Codex `<id>`" in the pane
   toolbar while an agent session is active, so the user can see at a glance
   which pane is running what.
2. **Crash recovery hint** -- if DanTerm crashes or is killed, the restored
   pane prints a one-time line like
   `[DanTerm] You were inside Claude session <id> -- resume with: claude -r <id>`
   so the user can manually resume the agent conversation.

The agent's session id is **not** readable from the agent process's
environment from outside (it is generated at runtime and only exported to
*child* processes; `ps eww` on the live `claude` process shows nothing), and
libghostty exposes no child-pid getter. So the id must be **reported by the
agent itself** via a hook. DanTerm already has every transport piece for this:
per-pane env injection (`DANTERM_SOCK`/`DANTERM_PANE`), the `danterm` CLI over
the IPC socket, the Elm core + reconciler, the checkpoint codec, and the
env-var-triggered shell-integration pattern used for scrollback replay.

This is a cooperation-based design: the agent reports its session over the
existing `danterm` CLI; DanTerm stores it on the pane model, projects it to
the toolbar, persists it in the checkpoint, and surfaces a recovery line on
restore.

## Locked decisions (from clarification)

- **Recovery hint:** printed pty line (via env var + shell-integration snippet,
  exactly like scrollback replay), not a native banner or alert popover.
- **Resume behavior:** hint only -- DanTerm never auto-runs `claude -r`. Restore
  keeps its existing prefill/execute behavior; the user runs the resume command
  themselves.
- **Hook wiring:** ship the hook scripts + documented snippet; the user wires
  them into their (Nix-managed) Claude/Codex config. DanTerm does not edit the
  user's agent config files.
- **Detach (clearing the live indicator):** the existing `CMD_END`
  shell-integration signal plus process-exit. No `SessionEnd` hook -- `CMD_END`
  fires whenever the agent returns control to the prompt (even after a kill),
  and process-exit already removes the pane.

## Data model

`kind` is a **raw `String`**, not a closed enum, so a future agent can report
without a code change and old/new snapshots round-trip even with an unknown
kind. A small catalog supplies the nice-to-haves for *known* kinds.

New file `lib/DanTermCore/Sources/DanTermCore/AgentSession.swift`:

```swift
/// An agent (Claude Code, Codex, ...) session reported as running inside a pane.
/// `kind` is a raw string for forward-compat; AgentCatalog maps known kinds to
/// display text + a resume command. Persisted (as the raw `AgentSessionSnapshot`
/// DTO below, not this type) in the checkpoint so a crash can surface a recovery
/// hint, but NOT rehydrated as live state on restore -- a restored session is
/// dead. This live type is intentionally not `Codable`.
struct AgentSession: Equatable {
    var kind: String       // validated identifier; "claude", "codex", ...
    var sessionId: String

    /// The ONLY validated constructor -- used by BOTH the IPC attach path and the
    /// restore-time recovery-line build, so it is the single validation gate.
    /// `kind` and `sessionId` are UNTRUSTED -- any pane process can send them (and
    /// a tampered on-disk snapshot can carry them), and they are later printed
    /// into the terminal (the recovery line, via `printf`) and shown in the
    /// toolbar/tooltip. So they are validated/normalized here and the initializer
    /// returns nil (-> IPC rejected with invalid-params, or recovery hint
    /// dropped) on violation:
    ///   - kind: lowercased, must match `^[a-z0-9][a-z0-9_-]{0,31}$`, else nil.
    ///   - sessionId: must match `^[A-Za-z0-9][A-Za-z0-9._:@+-]{0,127}$` -- a
    ///     shell-token-safe id charset that excludes control/ESC/CR/LF
    ///     (terminal-escape injection) AND shell metacharacters (`;` `&` `|` space
    ///     quote backtick `$`). The first char is forced alphanumeric so an id
    ///     can never be parsed as a CLI flag: a malicious `--dangerously-skip-
    ///     permissions` must not turn the copied `claude -r <id>` /
    ///     `codex resume <id>` line into `claude -r --dangerously-...`. Real
    ///     Claude/Codex ids are UUIDs (start with hex) and fit. Else nil.
    init?(kind: String, sessionId: String)
}

enum AgentCatalog {
    static func displayName(for kind: String) -> String   // "claude"->"Claude", else kind.capitalized
    static func resumeCommand(for s: AgentSession) -> String?  // claude->"claude -r <id>", codex->"codex resume <id>", else nil
}

extension AgentSession {
    var toolbarLabel: String   // "Claude 4f3a2b1c"  (displayName + sessionId.prefix(8))
    var recoveryMessage: String  // "[DanTerm] You were inside Claude session <full id> -- resume with: claude -r <full id>"
                                 // unknown kind -> "...You were inside a Foo session <id>" (no resume clause)
}
```

These are pure and the natural unit-test surface (label/message/resume-command
for claude, codex, and an unknown kind). The resume command is built **by
DanTerm from the catalog**, never taken from the caller -- the printed line must
not be an attacker-shaped command string.

## Implementation

### 1. Pane model + projection (pure core)

- `Model.swift` (~line 84): add `var agentSession: AgentSession? = nil` to
  `PaneModel`, mirroring the existing `remoteSession` field. This is the **live**
  slot: set on attach, cleared on detach, drives the toolbar.
- `Projections.swift` (~line 207 `PaneToolbarRender`, ~line 222
  `desiredPaneToolbar`): add `let agentSession: AgentSession?` and pass
  `pane.agentSession`. The struct is `Equatable`, so the reconciler diff already
  re-renders the toolbar on change -- no new reconcile pass.

### 2. Attach over IPC (pure core)

- `lib/DanTermProtocol/.../Methods.swift`: add
  `public static let agentAttach = "agent.attach"`.
- `Update.swift` `handleIpcRequest` (~line 1468): add
  `case Methods.agentAttach:` mirroring `Methods.todoAdd` (~line 1746) --
  parse `kind` + `id` strings from `params`, build the session via the
  validating `AgentSession(kind:sessionId:)` and `return ipcInvalidParams(reqId,
  ...)` if it is nil (untrusted input -- see data model), resolve the pane via
  the existing `resolveTargetPane(params:context:in:)` (~line 1955), then
  `model.updatePane(paneId) { $0.agentSession = session }` and return
  `[.scheduleCheckpoint, .ipcReply(reqId:, result: <ok>)]`. The reply is still
  sent so the CLI knows it succeeded; `outputMode: .none` (step 4) keeps the CLI
  silent. Overwrite semantics: a re-fire on resume/compact just updates the id.

### 3. Detach (pure core)

- `Update.swift` `.commandEnded` handler (~line 511): clear `agentSession` and
  schedule a checkpoint only when one was present (avoid churn on every command).
  **Trap:** the existing handler has an early
  `guard pane.remoteThemeOverride != nil else { return [] }` between the
  field-clear and the end -- that returns `[]` for every NON-remote pane, i.e. the
  common local-`claude` case. Naively adding the clear to the first block + a
  conditional checkpoint at the end lets that guard swallow the checkpoint, so a
  later crash resurfaces a stale `claude -r <old-id>` hint. Restructure to capture
  presence up front and compute the return once, instead of leaning on the early
  return:

  ```swift
  case .commandEnded(let paneId):
      guard let pane = model.pane(paneId) else { return [] }
      let hadAgentSession = pane.agentSession != nil
      model.updatePane(paneId) { p in
          p.isRemote = false; p.remoteSession = nil; p.agentSession = nil
      }
      if pane.remoteThemeOverride != nil {
          model.updatePane(paneId) { $0.remoteThemeOverride = nil }
      }
      return hadAgentSession ? [.scheduleCheckpoint] : []
  ```

  Process-exit needs no change: `.surfaceClosed` -> `.closePane`
  (Update.swift:788) removes the pane and its `agentSession` with it.

### 4. CLI verb

- `CLIParser.swift`: add top-level `case "agent":` dispatching subcommand
  `attach` with `--kind` and `--id` flags (mirror `TabNewArgs.swift` /
  `PaneSplitArgs.swift`), returning
  `CLICommand(method: Methods.agentAttach, params: ["kind":, "id":], outputMode: .none)`.
  `.none` matches the other side-effect verbs (`pane.focus`, `tab.rename`,
  `theme.set`) so the CLI prints **nothing** on success -- critical because
  Claude adds `SessionStart` hook stdout to its context (step 9). The `_ctx`
  paneId is added automatically by `cli/main.swift`.
- `cli/main.swift`: add `agent attach` to the hand-maintained `usageText`
  (~line 22, kept in sync with `parseCLI`).
- `integrations/danterm/SKILL.md`: document **both** CLI-surface changes
  (AGENTS.md requires SKILL.md updates for new commands *and* stdout-shape
  changes):
  - the new `danterm agent attach` verb; and
  - the new optional pane `.agentSession` object (`{kind, sessionId}`) now
    embedded at each `ls` leaf `.pane`. Adding `agentSession` to `PaneSnapshot`
    (step 5) flows through `toSnapshot`, which `Methods.ls` encodes verbatim
    (`Update.swift:1477-1482`), so `ls` output gains the field. Update the
    pane-shape prose (SKILL.md ~:244-246) and the `ls` row of the "CLI stdout
    shapes" table (~:296).

### 5. Persistence: persist, but do not rehydrate as live (pure core)

- `Model.swift`: add a plain-`Codable` DTO
  `struct AgentSessionSnapshot: Codable { let kind: String; let sessionId: String }`
  (mirrors the existing `TodoSnapshot` / `PaneLaunchSnapshot` nested-DTO pattern),
  and add `var agentSession: AgentSessionSnapshot? = nil` to `PaneSnapshot`
  (~line 364). Using a separate raw DTO -- **not** the live `AgentSession` --
  keeps `PaneSnapshot`'s synthesized `Codable` and its **memberwise initializer**
  intact: there are many positional
  `PaneSnapshot(id:title:cwd:launch:scrollback:theme:)` call sites that omit
  defaulted trailing fields (e.g. `Model.swift:328`, the snapshot tests), so
  introducing a custom `PaneSnapshot.init(from:)` would suppress the memberwise
  init and break them. A defaulted optional adds a trailing memberwise parameter,
  so those call sites keep compiling; backward compatible, no schema-version bump.
- **Validate at the single consumption site, through the one validated
  constructor.** `AgentSessionSnapshot` holds raw, unvalidated strings; the only
  safe way to use it is to build an `AgentSession` via `init?(kind:sessionId:)`.
  The sole consumer is `stageValidatedRestore` building the recovery line
  (step 7), which does exactly that and drops the hint if validation fails -- so a
  tampered/corrupted/imported snapshot can never push an unvalidated id to the
  terminal, and one bad hint never fails the rest of the restore. (The live model
  is not rehydrated from it -- see below -- so the toolbar never reads snapshot
  data.) Validation thus lives in exactly one place (`init?`), not duplicated in a
  decoder.
- `Persistence.swift` `toPaneSnapshot` (~line 137): set
  `agentSession: pane.agentSession.map { AgentSessionSnapshot(kind: $0.kind, sessionId: $0.sessionId) }`,
  exactly like the adjacent `TodoSnapshot` mapping (~line 145).
- `validateAndBuild`: **deliberately do not** read `agentSession` back into the
  live `PaneModel` -- it stays `nil`. A restored session is dead; showing it as
  live in the toolbar would be a lie. The persisted value is consumed only to
  build the recovery line (step 7).

### 6. Restore env gap fix via a pure helper (core + app) -- prerequisite

`stageValidatedRestore` (`AppRuntime.swift` ~line 1128) currently injects only
`[("DANTERM_TOKEN", token)]`. The `danterm` CLI itself still reaches the running
app -- it falls back to `controlSocketPath()` when `DANTERM_SOCK` is unset
(`cli/main.swift:95`), so global verbs like `tab new` work in restored panes. The
precise, load-bearing breakage is narrower: with no `DANTERM_PANE` the CLI builds
an empty `_ctx.paneId`, so **pane-scoped** commands -- including the new
`agent attach` -- have no pane to resolve against, and the re-launched agent
cannot report. Restored panes also lack `DANTERM_SOCK` (forcing the fallback
above) and `DANTERM` (the in-DanTerm marker agent skills read -- it is *not* a
shell-integration gate; the README command-reporting snippet keys off
`DANTERM_TOKEN`, which restore already sets). Fix by routing restore through a
new pure core helper beside `terminalLaunchEnvironment`, which supplies all of
SOCK/PANE/flag/token for parity with `createSurface` (`AppRuntime.swift:368`) and
is unit-testable (the assembly currently has zero coverage):

```swift
// TerminalLaunchEnvironment.swift -- pure, deterministic
func restoreLaunchEnvironment(
    ipcSocketPath: String, paneId: PaneId, token: String,
    scrollbackFilePath: String?,    // nil = no replay file
    agentRecoveryMessage: String?   // nil = no recovery hint
) -> [(String, String)]
// == terminalLaunchEnvironment(...) (sock/pane/token/flag)
//    + (DANTERM_RESTORE_SCROLLBACK_FILE, path)  iff scrollbackFilePath != nil
//    + (DANTERM_AGENT_RECOVERY, message)         iff agentRecoveryMessage != nil
```

`stageValidatedRestore` writes the replay file as today, computes the recovery
message by re-validating the raw DTO through the one validated constructor
(`ps?.agentSession.flatMap { AgentSession(kind: $0.kind, sessionId: $0.sessionId) }?.recoveryMessage`
-- see step 7), and calls the helper -- no inline env
literal. This is a real pre-existing bug fix the feature depends on (it also
restores `danterm` CLI usability in recovered panes generally), and the helper
is the test seam for the restore-env coverage in Tests.

### 7. Recovery printed line (app + documented shell snippet)

Reuse the scrollback-replay mechanism verbatim: an env var consumed by the
user's shell-integration snippet.

- `lib/DanTermProtocol/.../EnvVars.swift`: add
  `public static let agentRecovery = "DANTERM_AGENT_RECOVERY"` (used by the
  `restoreLaunchEnvironment` helper in step 6).
- `stageValidatedRestore` re-validates the raw snapshot DTO through the one
  validated constructor and passes the result as the `agentRecoveryMessage`
  argument to `restoreLaunchEnvironment` (step 6):
  `ps?.agentSession.flatMap { AgentSession(kind: $0.kind, sessionId: $0.sessionId) }?.recoveryMessage`.
  The helper emits `DANTERM_AGENT_RECOVERY` only when non-nil; an invalid stored
  id validates to nil and simply prints no hint. DanTerm builds the full message
  (catalog resume command) so the shell prints it verbatim.
- `README.md`: add the one-time print snippet next to the existing scrollback
  block (zsh + fish), e.g. zsh:

  ```zsh
  # One-time agent-session recovery hint from a previous DanTerm session
  if [[ -n "$DANTERM_AGENT_RECOVERY" ]]; then
    printf '%s\n' "$DANTERM_AGENT_RECOVERY"
    unset DANTERM_AGENT_RECOVERY
  fi
  ```

  Place it after scrollback replay so the hint is the last thing printed before
  the first prompt.

### 8. Toolbar accessory (app)

- `PaneWrapperView.swift` (~line 253 `updateToolbar`): add an `agentSession`
  parameter and an `agentAccessory` chip (label = `agentSession.toolbarLabel`),
  mirroring the `remoteAccessory` chip exactly (visibility toggle +
  compact/expanded constraint sets). Use a distinct accent from the purple
  remote chip; full id available via tooltip.
- `Reconcile.swift` `reconcilePaneChrome`: pass the projection's `agentSession`
  into the `updateToolbar(...)` call.

### 9. Claude hook script (ship Claude end-to-end; Codex deferred)

Mirror the existing `integrations/claude-code/claude-notify-osc777.sh` pattern
(reads stdin JSON via `jq`). Per Claude's hooks reference, the `SessionStart`
payload carries `session_id`, `source` (`startup`/`resume`/`clear`/`compact`),
`cwd`, `hook_event_name`, and optionally `agent_type` -- it has **no**
`agent_id`, and subagents do **not** fire `SessionStart` (they fire
`SubagentStart`). So there is no subagent clobbering to filter; just report
`session_id` on every `SessionStart`.

Critically, **`SessionStart` hook stdout is injected into Claude's context**
before the first prompt. So the hook must be **silent on success** and
**best-effort** (never fail or stall the session):

- New `integrations/claude-code/danterm-agent-session.sh` -- `SessionStart`
  hook: read `session_id` from stdin; guard and `exit 0` **silently** if any of
  `DANTERM_SOCK` / `DANTERM_PANE` is unset, `session_id` is empty, or the
  `danterm` CLI is not on PATH; otherwise run the attach **synchronously**:
  `danterm agent attach --kind claude --id "$session_id" >/dev/null 2>&1 || true`
  then `exit 0`. Synchronous (not backgrounded) is load-bearing for **ordering**:
  `SessionStart` is a *blocking* hook -- Claude waits for it and injects its
  stdout as context before the first prompt (verified, Claude hooks reference) --
  so a synchronous attach is guaranteed to land `pane.agentSession` before
  `claude` runs, hence strictly before the `CMD_END` that fires when `claude`
  later exits and clears it (the `.commandEnded` handler, Update.swift:511).
  Backgrounding with `&` was tried and **rejected**: it forfeits that guarantee --
  a fast-exiting `claude` plus a delayed background attach can clear-then-set,
  stranding a stale toolbar chip and persisting a stale recovery hint.
  The stall this reintroduces is bounded two ways, so synchronous still satisfies
  the "never stall the session" requirement: the CLI self-bounds at its **5s
  socket timeout** (`cli/main.swift:17`), and the hook wiring sets Claude's
  **native per-hook `timeout`** field as a hard ceiling (see the wiring bullet
  below) -- no GNU `timeout(1)` needed (it is absent on stock macOS, and with
  `|| true` would silently swallow into never attaching). The `>/dev/null 2>&1`
  keeps stdout empty so the hook never adds context; `|| true` keeps a
  failed/timed-out attach from failing the hook. Fires on start/resume/compact --
  all correct (re-)attaches, each synchronous. (Inherits
  `DANTERM_SOCK`/`DANTERM_PANE` from the pane env, which the shell snippet does
  not unset.)
- New `integrations/claude-code/danterm-agent-session.test.sh` -- assert: (a)
  the success path produces EMPTY stdout; (b) each guarded no-op path (missing
  env, empty session id, missing CLI) produces EMPTY stdout and exit 0; (c) the
  emitted CLI invocation shape (`--kind claude --id <session_id>`) via a stub
  `danterm` on PATH. Mirror the notify `.test.sh`. (No backgrounding/no-stall
  test: the script is plainly synchronous now, and the stall ceiling is the
  native hook `timeout` -- a wiring-layer property set in `common/claude-code.nix`
  and confirmed by verification step 2, not something this script controls or can
  assert.)
- Wire both into `flake.nix` exactly like the notify hook: a
  `writeShellApplication` package (mirror `flake.nix:44`
  `danterm-claude-notify-osc777`) and a `checks` entry (mirror `flake.nix:113`)
  that runs `danterm-agent-session.test.sh` under bash+jq with `HOOK_UNDER_TEST`
  pointing at the packaged script -- so it is gated in the same path as the
  existing hook test.
- Document the Nix wiring (Claude `SessionStart` -> the packaged script) in the
  world repo's `common/claude-code.nix` as a manual follow-up -- out of scope for
  the danterm repo diff. The wiring **must set the native per-hook `timeout`** on
  this `SessionStart` entry (exactly as the existing notify hooks there set
  `timeout = 10`). Use a value **>= the CLI's 5s socket timeout (e.g.
  `timeout = 6`)** so the synchronous attach always resolves *inside* the hook,
  before `claude` proceeds -- this is what keeps the attach-before-`CMD_END`
  ordering (and the no-orphan invariant) intact. A tighter value (the reviewer's
  illustrative 2s) caps session-start latency lower but can cancel the hook while
  the CLI is still mid-connect on a wedged socket, leaving an orphaned attach that
  may land *after* a later `CMD_END` -- reintroducing the very clear-then-set race
  this synchronous design closes. The 6s ceiling only ever bites when DanTerm's
  socket is already wedged (rare/degraded); the common case completes in
  milliseconds.

Codex is **deferred** (see Out of scope): no Codex hook script ships in this
change, but the model/CLI/catalog already support it.

## Tests

All behavioral and structure-insensitive:

- **Core (Swift Testing, `lib/DanTermCore/Tests`):**
  - Attach via the IPC entry: `update(&model, .ipcRequest(method: Methods.agentAttach, params: {kind,id}, context: paneCtx), env:)` sets `pane.agentSession`; returns `.scheduleCheckpoint`.
  - Input validation: `AgentSession(kind:sessionId:)` rejects (returns nil) empty / >128-char session ids, session ids containing a control byte OR a shell metacharacter (`;`, space, `'`, `` ` ``, `$`, `&`, `|`), session ids beginning with `-` (e.g. `-x`, `--dangerously-skip-permissions` -- must not parse as a CLI flag), and a non-identifier `kind`; accepts valid UUID-shaped ids and lowercases `kind`. The attach IPC path returns invalid-params and leaves the model unchanged on rejected input (guards both the printed recovery line and the toolbar against escape/command/flag injection).
  - Snapshot validation at consumption: given a `PaneSnapshot` whose `AgentSessionSnapshot` carries an invalid kind/sessionId, the recovery build (`AgentSession(kind:sessionId:)?.recoveryMessage`) returns nil so `restoreLaunchEnvironment` emits NO `DANTERM_AGENT_RECOVERY`; a valid one yields the var. Plus a `toPaneSnapshot` round-trip (live `agentSession` -> `AgentSessionSnapshot` and back through validation). Pins that on-disk data cannot bypass validation to reach the recovery line.
  - `.commandEnded` clears `agentSession` (and still clears `remoteSession`/`remoteThemeOverride`). Explicit scenario for the guard trap: a pane with `agentSession` set and `remoteThemeOverride == nil` (the common local case) must still return `.scheduleCheckpoint`; a pane with neither returns `[]`.
  - Persistence round-trip: a model with `agentSession` -> `toSnapshot` carries it in `PaneSnapshot`; `validateAndBuild` rebuilds the pane with `agentSession == nil` (dead-on-restore invariant). This pins the live-vs-persisted distinction.
  - `restoreLaunchEnvironment` (step 6): always emits `DANTERM_SOCK` / `DANTERM_PANE` / `DANTERM_TOKEN`; emits `DANTERM_RESTORE_SCROLLBACK_FILE` iff a path is passed and `DANTERM_AGENT_RECOVERY` iff a message is passed (F4 -- the restore env fix gets a failing test if a var goes missing).
  - Catalog/projection: `toolbarLabel`, `recoveryMessage`, and `resumeCommand` for `claude`, `codex`, and an unknown kind (resume nil + no resume clause).
- **Protocol (XCTest, `lib/DanTermProtocol/Tests` / `CLIParserTests.swift`):**
  `CLIParser` parses `agent attach --kind claude --id X` to `agent.attach` with
  the right params **and `outputMode == .none`**; error cases for missing
  `--kind`/`--id`. Extend the CLI help smoke check
  (`scripts/tests/danterm-cli_test.sh` -- run via `just test-cli`, NOT part of
  `just test` -- or `CLIParserTests`) to assert `agent attach` appears in
  `usageText`.
- **Shell self-test:** `integrations/claude-code/danterm-agent-session.test.sh`
  (success + no-op paths are stdout-silent; emitted command shape), gated via
  the new `flake.nix` `checks` entry (step 9). The README recovery-line shell
  snippet is exercised by the world repo's
  `~/world/scripts/tests/danterm-integration_test.sh` (that file is **not** in
  this repo); covering it there is a world-repo follow-up, otherwise it relies on
  manual verification step 5.

## Verification (end to end)

1. Gates: `just test` (core + protocol + shell self-tests), **plus** two gates
   it does NOT include:
   - `nix flake check` -- builds the packaged hook `writeShellApplication` and
     runs `danterm-agent-session.test.sh` (same path as the existing notify hook
     test; or targeted `nix build .#checks.<system>.danterm-agent-session`).
   - `DANTERM_CLI_TEST_ALLOW_APP_CONTROL=1 just test-cli`
     (`scripts/tests/danterm-cli_test.sh`) -- the CLI help-text / packaged-helper
     smoke that covers `agent attach` appearing in the hand-synced `usageText`.
     Needs GUI access + the opt-in env var; not in `just test`.
2. `just build-run`. Wire the `SessionStart` hook locally (point it at
   `integrations/claude-code/danterm-agent-session.sh`, and set its native
   `timeout` to `6` per step 9) and add the README recovery + scrollback snippets
   to the shell rc.
3. In a pane, run `claude`. Toolbar shows "Claude `<short id>`". Confirm
   `danterm agent attach ...` reached the socket (toolbar updates).
4. Exit `claude` (clean) -> indicator clears (CMD_END). Re-run and `kill -9`
   the claude pid -> indicator still clears when the shell regains the prompt.
5. Simulate a crash: with `claude` running, `kill -9` the DanTerm app (leaves
   the recovery session lock). Relaunch -> the restored pane prints
   `[DanTerm] You were inside Claude session <id> -- resume with: claude -r <id>`
   exactly once. Run that command -> the conversation resumes.
6. Repeat (4)-(5) for Codex once its hook event is confirmed.

## Out of scope / follow-ups / risks

- **Codex hook is deferred** until its session-start hook event + payload schema
  are confirmed (and that `$CODEX_THREAD_ID` is in the hook env). The model, CLI
  verb, and catalog already support `codex` (incl. `codex resume <id>`), so
  enabling Codex later is purely additive: a hook script + wiring, no core
  change. Shipping Claude end-to-end first removes the schema uncertainty.
- **Nix hook wiring** (Claude `SessionStart` -> packaged script) lives in the
  world repo (`common/claude-code.nix`); documented here, applied separately.
- **Nested agents** (agent A spawns a shell that runs agent B in the same pane)
  are not modeled -- single "current" slot; the latest attach wins. Acceptable.
- **Early clear edges:** `Ctrl-Z` suspend or an agent spawning its *own*
  DanTerm-integrated interactive subshell would fire `CMD_END` and clear the
  indicator early. Rare and acceptable per the detach decision.
- **Subagents / `--agent`:** no filtering needed -- `SessionStart` carries no
  `agent_id` and subagents fire `SubagentStart`, not `SessionStart`, so a
  subagent cannot clobber the toolbar via this hook. An `--agent` main session
  legitimately reports its own id (`agent_type` may be present; it is not a
  reason to skip).

## Implementation notes

- `agent.attach` replies with `{"ok": true}` on success. The CLI uses
  `outputMode: .none`, so the Claude hook remains stdout-silent, while callers
  still get a concrete success result from IPC.

## Follow Up

- `~/world/common/claude-code.nix`: wire Claude Code `SessionStart` to the
  packaged `danterm-claude-agent-session` hook and set the native hook
  `timeout = 6`.
- `~/world/scripts/tests/danterm-integration_test.sh`: exercise the README
  `DANTERM_AGENT_RECOVERY` shell snippet so the one-time recovery hint print is
  covered outside this repo.
- Confirm the Codex hook event and payload schema, then add a Codex hook script
  and wiring that calls `danterm agent attach --kind codex --id <thread-id>`.
