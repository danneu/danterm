# Codex agent-session SessionStart integration (parity with Claude)

## Context

The `agent-session-awareness` branch adds per-pane agent tracking: a `SessionStart`
hook calls `danterm agent attach --kind <kind> --id <session-id>` over IPC, and
DanTerm shows a toolbar chip + persists a crash-recovery hint for the pane. Today
only the **Claude** side ships (`integrations/claude-code/danterm-agent-session.sh`,
packaged in `flake.nix`, documented in `README.md`). The model layer is already
agent-generic and Codex-aware.

This session we empirically verified (via throwaway harnesses
`~/claude-session-hook-test/` and `~/codex-session-hook-test/`) that Codex CLI
0.137 can drive the exact same flow. Goal: add the Codex hook so a pane running
`codex` gets the same chip + recovery hint as one running `claude`.

### Empirical findings to bake in (Codex 0.137)

- Codex has a **native hooks system** (`~/.codex/hooks.json`, same JSON shape as
  Claude). Its `SessionStart` payload **matches Claude's**: `session_id`,
  `transcript_path`, `cwd`, `hook_event_name`, `source` as JSON on stdin. So the
  hook script is a near-verbatim clone -- only `--kind claude` -> `--kind codex`.
- `SessionStart` fires **only in the interactive TUI** (never in `codex exec`),
  and **lazily -- on the first prompt submission**, not at launch. Consequence:
  the chip appears after the user's first message, a beat later than Claude.
- Codex has **no `SessionEnd` hook**, and Ctrl-C emits nothing. This is fine and
  needs no Codex-specific code: DanTerm detach is **agent-agnostic** -- the design
  clears the chip via the existing `CMD_END` shell-integration signal + process
  exit (`plans/impl/2026-06-04-per-pane-agent-session-awareness.md`, lines 41-44),
  not via any agent's end hook. Claude's `SessionEnd` is ignored too.
- Codex docs list `source` values `startup`/`resume`/`clear`/`compact`, but the
  Codex 0.137 harness observed `source=startup` **even on `resume`/`fork`** (likely
  version-specific or a bug, cf. openai/codex#15266). Either way this integration
  **ignores `source`** and attaches on any `SessionStart` -- do not add a `source`
  matcher. resume/fork mint a new `session_id`, which is exactly the current id we
  want to report.
- **No Swift changes:** `AgentCatalog` already maps `codex` -> "Codex" with
  resume command `codex resume <id>`, and `isValidKind` accepts `codex`
  (`lib/DanTermCore/Sources/DanTermCore/AgentSession.swift`).

## Scope -- this PR (danterm repo, branch `agent-session-awareness`)

Mirror the Claude integration for Codex. Pattern is a near-exact clone.

1. **New `integrations/codex/danterm-agent-session.sh`** -- clone of
   `integrations/claude-code/danterm-agent-session.sh`, with:
   - header rewritten for Codex; keep it **stdout-silent**. The Codex hooks docs
     state SessionStart `stdout` is "added as extra developer context", so any
     output would be injected into the model's context (same hazard as Claude).
     The header comment should cite this so future edits don't relax it.
   - same guards: `DANTERM_SOCK`/`DANTERM_PANE` set, `jq` + `danterm` on PATH.
   - same extraction `jq -r '.session_id // empty'` (Codex uses the same field).
   - final call: `danterm agent attach --kind codex --id "$SESSION_ID"`.

2. **New `integrations/codex/danterm-agent-session.test.sh`** -- clone of the
   Claude test (`check_case` harness: stubs `danterm` on PATH, feeds JSON on
   stdin, asserts stdout silence + exact invocation). Change the expected
   invocation to `agent attach --kind codex --id ...`. Keep the no-op cases
   (missing sock/pane, empty id, missing cli).

3. **`flake.nix`** -- three additions mirroring the Claude entries:
   - `overlays.default`: add `danterm-codex-agent-session = final.writeShellApplication { name = "danterm-codex-agent-session"; runtimeInputs = [ final.jq ]; bashOptions = [ ]; text = builtins.readFile ./integrations/codex/danterm-agent-session.sh; };` (next to `danterm-claude-agent-session`, ~line 50).
   - `packages`: add `codex-agent-session = pkgs.danterm-codex-agent-session;` (next to `claude-agent-session`, ~line 79).
   - `checks`: add a `codex-agent-session` `runCommand` cloning the
     `claude-agent-session` check (~lines 136-151): copy `${./integrations/codex}`,
     set `HOOK_UNDER_TEST=${self.packages.${system}.codex-agent-session}/bin/danterm-codex-agent-session`,
     run `integrations/codex/danterm-agent-session.test.sh`.

4. **`README.md`** -- add a "Codex session recovery hook" section mirroring the
   "Claude session recovery hook" section (~lines 207-241): the `pkgs.danterm-codex-agent-session`
   nix snippet, a raw Codex `hooks.json` `SessionStart` snippet, and the no-Nix
   copy instructions pointing at `integrations/codex/danterm-agent-session.sh`.
   Add a one-line caveat: the chip appears on the first prompt (Codex fires
   SessionStart lazily), and there is no end hook (detach is handled by DanTerm).
   Note the hook is intentionally stdout-silent because Codex adds SessionStart
   stdout to developer context.

5. **Design record** -- update `plans/impl/2026-06-04-per-pane-agent-session-awareness.md`
   by **replacing** its now-stale "Codex deferred" guidance, not appending beside it
   (appending would leave contradictory text). Three loci, all assuming the schema is
   unconfirmed and the id arrives via `$CODEX_THREAD_ID`/`<thread-id>`:
   - the "Codex hook is deferred until ... payload schema ... confirmed" bullet (~lines 415-419);
   - the "Confirm the Codex hook event and payload schema ... `--id <thread-id>`" follow-up (~lines 447-448);
   - the "once its hook event is confirmed" clause in the verification step (~line 411).
   Replace with a version-scoped Codex 0.137 note recording: the schema **is**
   confirmed and matches Claude's -- the id is the **stdin `session_id` field**, not
   an env var, so the hook is a near-clone of the Claude script; SessionStart fires
   interactively + lazily (first prompt); no SessionEnd (detach via `CMD_END`,
   agent-agnostic); and the integration **ignores `source`** and adds no `source`
   matcher (0.137 observed `startup` even on resume/fork; docs list
   `startup`/`resume`/`clear`/`compact`).

### Reuse (do not reinvent)

- Script + test harness: copy `integrations/claude-code/danterm-agent-session.sh`
  and `...test.sh` verbatim, change `--kind`.
- flake packaging/checks: copy the `claude-agent-session` package/packages/checks
  trio in `flake.nix`.
- CLI surface (`danterm agent attach --kind <kind> --id`) and the Swift model are
  already generic -- no changes.

## Follow-up -- NOT in this PR (`~/world` repo, gated on merge)

Wire `SessionStart` for **both** agents (parity), once this branch is on master
and `~/world` picks it up via `nix flake update danterm`:

- `common/codex.nix`: add a `SessionStart` entry to the `hooksJson` attrset
  (alongside the existing `PostToolUse`) ->
  `command = "${pkgs.danterm-codex-agent-session}/bin/danterm-codex-agent-session"; timeout = 10;`.
- `common/claude-code.nix`: add a new `SessionStart` key to the `settings.hooks`
  attrset (~line 135, new key so no PostToolUse-style clobbering) ->
  `command = "${pkgs.danterm-claude-agent-session}/bin/danterm-claude-agent-session"; timeout = 6;`.
  (The danterm overlay packages are already in scope here -- `claude-code.nix`
  already references `pkgs.danterm-claude-notify-osc777`.)
- Both modules load on both hosts; the script's `DANTERM_SOCK`/`DANTERM_PANE`
  guards make it a silent no-op on caja.
- Pre-merge testing: `--override-input danterm path:/Users/dan/world/my-apps/danterm`.

## Risks / things to verify

- **ENV inheritance (the real risk).** The hook no-ops unless `DANTERM_SOCK` and
  `DANTERM_PANE` are visible to the hook subprocess. Codex has a
  `shell_environment_policy` that can sanitize the environment; if it strips these,
  the chip never appears. Must confirm end-to-end (below). Mitigation if stripped:
  set `shell_environment_policy.inherit`/passthrough for these vars.
- **Hook trust.** Codex requires per-hook trust (hashes in `[hooks.state]`). The
  Nix-deployed `hooks.json` will need a one-time trust accept on first run (or
  `--dangerously-bypass-hook-trust`). No nix change required; note it in README.
- **Stdout.** Keep the script stdout-silent -- the Codex hooks docs state
  SessionStart `stdout` is "added as extra developer context", so any output is
  injected into the model's context (same as Claude). Documented, not a guess.

## Verification

1. **Unit (this PR):** `nix flake check` (or with `--override-input danterm
   path:.`) runs the new `codex-agent-session` check. Or run directly:
   `HOOK_UNDER_TEST=integrations/codex/danterm-agent-session.sh bash integrations/codex/danterm-agent-session.test.sh`
   (needs `jq`).
2. **Mechanism already proven:** `~/codex-session-hook-test/` confirmed
   SessionStart fires interactively with `.session_id` on stdin.
3. **End-to-end (after follow-up wiring, macbook):** open a DanTerm pane, run
   `codex`, submit a first prompt -> toolbar chip shows `Codex <id8>`. Exit codex
   to the shell prompt -> chip clears (CMD_END detach). Kill DanTerm mid-session
   and reopen -> the recovery line `... resume with: codex resume <id>` prints.
4. **Env check (do this first if the chip never appears):** temporarily point the
   Codex `SessionStart` hook at a script that writes `env | grep DANTERM` to a
   file, run `codex` in a pane, submit a prompt, inspect the file for
   `DANTERM_SOCK`/`DANTERM_PANE`.

## Files

- new: `integrations/codex/danterm-agent-session.sh`
- new: `integrations/codex/danterm-agent-session.test.sh`
- edit: `flake.nix` (overlay package + packages export + checks)
- edit: `README.md` (Codex section)
- edit: `plans/impl/2026-06-04-per-pane-agent-session-awareness.md` (replace stale Codex-deferred guidance at ~411/415-419/447-448 with the version-scoped 0.137 note)
- follow-up, separate `~/world` commit: `common/codex.nix`, `common/claude-code.nix`
