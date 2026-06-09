# Agent-session recovery hint: deliver via scrollback replay, reword message

## Context

When DanTerm restores panes after a crash, panes that had a Claude/Codex
session are supposed to print a one-time hint telling the user the session id
and how to resume it (e.g. `claude --resume <id>`). The feature shipped in
v0.0.71 (`feat(agent): track pane agent sessions`) and works end-to-end *in the
app*: the SessionStart hook attaches the session, it's persisted in the
checkpoint, and on restore `AgentSession.recoveryMessage` is computed and set as
the `DANTERM_AGENT_RECOVERY` env var on the restored pane (`AppRuntime.swift:1141`).

But the user never saw it. Root cause: the hint is *printed* by a shell-rc
snippet block that reads `DANTERM_AGENT_RECOVERY`, and that block was never
added to the user's nix-managed shell integration (`~/world/scripts/danterm-integration.{zsh,fish}`)
— it has the scrollback-restore and command-reporting blocks, but not the
recovery block. So DanTerm set the env var; nothing printed it.

The C API offers no way to write a system line directly into a Ghostty surface
(verified: every `ghostty_surface_*` entry point is input or read; Ghostty's own
"Process exited" banner uses internal `renderer_state.terminal.printString`,
which is not exposed). So short of a native overlay (deferred — see Non-goals),
the hint must ride an existing shell-integration path.

**Decision:** fold the hint into the **scrollback replay** text instead of its
own env var. The scrollback `cat` block *is* present in the user's config, so
this rides the integration point that already works, collapses two snippet
blocks into one, and deletes the drift-prone block that broke. Also reword the
message to be copy-friendly.

## Outcome

- On restore, the recovery hint is appended as the last line(s) of the pane's
  restored scrollback, so it prints right above the fresh prompt.
- `DANTERM_AGENT_RECOVERY` env var is retired; the user's existing `~/world`
  snippet needs **no change** (scrollback block already delivers it).
- New wording (copy-optimized, id stated once, `--resume`):
  ```
  [DanTerm] Restored Claude session. Resume with:
    claude --resume 4f3a2b1c-0000-4000-9000-abcdef123456
  ```

## Changes

### 1. Reword + `--resume` — `lib/DanTermCore/Sources/DanTermCore/AgentSession.swift`

`recoveryMessage` (currently `:37`):
```swift
var recoveryMessage: String {
    let displayName = AgentCatalog.displayName(for: kind)
    if let command = AgentCatalog.resumeCommand(for: self) {
        return "[DanTerm] Restored \(displayName) session. Resume with:\n  \(command)"
    }
    return "[DanTerm] Restored a \(displayName) session: \(sessionId)"
}
```
`AgentCatalog.resumeCommand` (`:104`): change Claude `"claude -r \(id)"` →
`"claude --resume \(id)"`. Codex `"codex resume \(id)"` unchanged.

Renderings: Claude → `[DanTerm] Restored Claude session. Resume with:\n  claude --resume <id>`;
Codex → `[DanTerm] Restored Codex session. Resume with:\n  codex resume <id>`;
unknown agent (no resume command) → `[DanTerm] Restored a Future_Agent session: <id>`.

### 2. Pure compositor — same file, `AgentSession.swift`

Add a pure top-level function (needs a `///` doc comment per code-style gate)
that centralizes hint validation, the append, and the no-scrollback fallback:

```swift
/// Compose the scrollback-replay text for a restored pane: captured scrollback
/// with a one-time agent-recovery hint appended as the last line(s). Returns nil
/// when there's nothing to replay, so the caller writes no replay file. Validates
/// the untrusted snapshot through `AgentSession` and silently drops a bad hint,
/// keeping malicious saved ids out of the restored pane.
func recoveryReplayText(scrollback: String?, agentSession: AgentSessionSnapshot?) -> String? {
    let hint = agentSession
        .flatMap { AgentSession(kind: $0.kind, sessionId: $0.sessionId) }?
        .recoveryMessage
    let history = (scrollback?.isEmpty == false) ? scrollback : nil
    switch (history, hint) {
    case let (history?, hint?):
        // Newline-aware: real saved scrollback is already newline-terminated
        // (`truncateScrollback`, Persistence.swift:270), so collapse to exactly
        // one blank-line separator instead of emitting a stray extra blank line.
        let separator = history.hasSuffix("\n") ? "\n" : "\n\n"
        return "\(history)\(separator)\(hint)\n"
    case let (history?, nil):
        return history
    case let (nil, hint?):
        return "\(hint)\n"
    case (nil, nil):
        return nil
    }
}
```

Why the no-scrollback case matters: restore is `mergeCheckpoints` (`Persistence.swift:235`)
— the latest *light* checkpoint is authoritative for model/structure, and
scrollback is grafted in by pane id from the last *enriched* checkpoint. Light
runs on a 2s debounce (`AppRuntime.swift:72`); enriched only on a 10-min timer +
clean termination (`:78`, `:60`). So a pane has **no** scrollback whenever no
enriched checkpoint covers it yet — the session crashed before the first
enriched tick (< 10 min) or the agent pane was created after the last one. Both
are common. The fallback (`nil, hint?` → hint-only) preserves the hint there;
the old env-var path survived this case, so this keeps parity.

Pure (no IO/ambient) — stays within the core-purity lint's pure profile.

### 3. Restore path — `app/AppRuntime.swift` (~`:1135`-`1150`)

Replace the scrollback gate + the `recoveryMessage`/`agentRecoveryMessage` block
with a single call to the compositor:
```swift
var scrollbackFilePath: String?
if let replayText = recoveryReplayText(scrollback: ps?.scrollback, agentSession: ps?.agentSession),
   let replayURL = writeReplayFile(scrollback: replayText) {
    stagedReplayFiles[paneId] = replayURL
    scrollbackFilePath = replayURL.path
}
let envVars = restoreLaunchEnvironment(
    ipcSocketPath: ipcSocketPath.path,
    paneId: paneId,
    token: token,
    scrollbackFilePath: scrollbackFilePath
)
```
(`writeReplayFile` at `:799` is reused unchanged.)

### 4. Retire the env var

- `lib/DanTermProtocol/Sources/DanTermProtocol/EnvVars.swift:8` — remove
  `agentRecovery`.
- `lib/DanTermCore/Sources/DanTermCore/TerminalLaunchEnvironment.swift` — drop
  the `agentRecoveryMessage` param and the `env.append((EnvVars.agentRecovery, …))`
  block (`:25`,`:35`-`37`); update the doc comment (scrollback is the only
  optional restore hint now).
- At impl time, `grep -rn "agentRecovery\|DANTERM_AGENT_RECOVERY"` to confirm no
  caller is missed (known callers: `AppRuntime`, the two `SnapshotTests`,
  `TerminalLaunchEnvironmentTests`).

### 5. Docs — `README.md`

Remove the two `# One-time agent-session recovery hint …` blocks (zsh ~`:369`,
fish ~`:433`). Add a one-line note in the scrollback-restore block that it now
also replays DanTerm's agent-recovery hint. (No `integrations/danterm/SKILL.md`
change — it never referenced the env var. Leave `plans/impl/*` historical docs
as-is.) Existing user rc copies of the recovery block become harmless no-ops
(the var is simply never set).

## Tests

TDD: write/adjust the failing tests first.

**Add** (`AgentSessionTests.swift`) — `recoveryReplayText` cases. Use
**newline-terminated** scrollback inputs to model real saved data
(`truncateScrollback` always appends `"\n"`, Persistence.swift:270):
- scrollback + valid claude → `recoveryReplayText("old output\n", <claude abc123>)`
  == `"old output\n\n[DanTerm] Restored Claude session. Resume with:\n  claude --resume abc123\n"`
  (exactly one blank line, not two)
- newline-awareness pin (non-terminated input still gets one blank line):
  `recoveryReplayText("no newline", <claude abc123>)`
  == `"no newline\n\n[DanTerm] Restored Claude session. Resume with:\n  claude --resume abc123\n"`
- scrollback + invalid id (`"bad;id"`) → `recoveryReplayText("old output\n", <bad>)`
  == `"old output\n"` (hint dropped, history intact) — the security guarantee
- nil scrollback + valid claude → `"[DanTerm] Restored Claude session. Resume with:\n  claude --resume abc123\n"` (no-scrollback fallback)
- nil scrollback + nil session → `nil`; empty scrollback (`""`) + nil session → `nil`

**Reword** existing expectations:
- `AgentSessionTests.swift:21` → `claude --resume 4f3a2b1c-…`; `:22`,`:31`,`:41` →
  new `recoveryMessage` strings above. (`:30` codex resumeCommand unchanged.)

**Rewrite** (`SnapshotTests.swift`) — retarget the two env-var tests to the
compositor:
- `agentSessionSnapshotValidatesAtRecoveryConsumption` (~`:811`): assert
  `recoveryReplayText(scrollback: nil, agentSession: <valid>)` contains the hint
  and `recoveryReplayText(scrollback: "old output\n", agentSession: <"bad;id">)
  == "old output\n"` (was: `EnvVars.agentRecovery` present/nil).
- `malformedAgentSessionSnapshotDoesNotRejectRestore` (~`:835`): keep the JSON
  load + `allPaneIds.count == 1`. Note the real decode boundary:
  `AgentSessionSnapshot.init(from:)` (Model.swift:376) is lenient — malformed
  `{kind:42}` decodes to a **non-nil** raw snapshot with empty-string fields
  (`pane.agentSession?.kind == ""`), *not* to nil. It's `AgentSession`
  validation that then rejects it. So assert: `pane.agentSession != nil`, and
  `recoveryReplayText(scrollback: pane.scrollback, agentSession: pane.agentSession) == nil`
  (no scrollback in this JSON; the invalid snapshot fails validation → hint nil
  → nil). This pins *validation* — the security seam — as the drop mechanism,
  not a decode-to-nil shortcut.

**Trim** (`TerminalLaunchEnvironmentTests.swift:37`-`67`): drop the
`agentRecoveryMessage:` arg and the `EnvVars.agentRecovery` assertions; the
"full" case keeps only the scrollback var.

## Verification

- `just test` — core Swift Testing + protocol + DanTermSupport + core-purity
  lint (pure profile must still pass for the new helper) + shell self-tests.
  Targeted: `swift test --package-path lib/DanTermCore --filter AgentSession`
  and `--filter Snapshot`.
- Manual end-to-end (needs the scrollback `cat` block active in the pane's shell
  — present in `~/world`). Checkpoint timing matters: light = 2s debounce,
  enriched = 10-min timer + clean termination only (`AppRuntime.swift:72`,`:78`).
  - **No-scrollback path (primary — reliable, fast).** This is also the common
    real case (crash before the first enriched tick). `just build-run`; open a
    pane, run `claude`; **wait until the agent chip is visible and ~2s have
    elapsed** (so a light checkpoint with `agentSession` is on disk), then
    `kill -9` the `DanTerm Dev` process **before the 10-min enriched tick**
    (leaves the recovery lock → next launch offers Restore). Relaunch; click
    **Restore** → the restored pane shows the hint with no prior history:
    `[DanTerm] Restored Claude session. Resume with:` / `  claude --resume <id>`.
    Confirms the full retired-env-var → replay-file → shell-`cat` delivery.
  - **With-scrollback append (secondary).** The composition is fully covered by
    the `recoveryReplayText` unit tests. To check it live, the pane needs an
    enriched checkpoint: either let the session run past a 10-min enriched tick
    (then `kill -9`), or temporarily lower `enrichedCheckpointInterval` for the
    test build. On Restore the hint appends after the replayed history, separated
    by one blank line.

## Non-goals / follow-ups

- **Native AppKit overlay** (rc-independent, survives the agent's alt-screen
  redraw, click-to-copy). The robust end-state; deferred. This plan deliberately
  keeps the terminal-text model.
- This stays **rc-dependent** (needs the scrollback block) and the printed line
  **scrolls into history** the moment the user re-runs the agent TUI — same as
  the old snippet, not a regression. Only the overlay fixes those.
- Deploying to the user's machine is the normal danterm release + `package.nix`
  bump; the shell snippet needs no change.
