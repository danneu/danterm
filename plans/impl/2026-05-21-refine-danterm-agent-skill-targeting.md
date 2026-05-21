# Refine DanTerm Agent Skill Targeting Rules

## Summary

Update the CLI/API and `integrations/danterm/SKILL.md` so agents can control
DanTerm without depending on mutable UI focus, while humans running commands
inside DanTerm can still use pane-context convenience forms.

Clean contract:

- `$DANTERM=1` only means the agent originated inside DanTerm.
- `$DANTERM_PANE` remains exported and is the only implicit context.
- Agents use `$DANTERM_PANE` only to derive live ids with `danterm pane info`,
  then mutate with explicit entity ids.
- Humans may omit explicit targets inside DanTerm; the CLI sends pane context
  from `$DANTERM_PANE`, and the server resolves live tab/group/pane targets
  from that pane.
- Do not export or document `DANTERM_TAB`; pane id is the only stable
  originating context.

## Key Changes

- Remove the tab env-context path completely:
  - Stop exporting `DANTERM_TAB` to new panes.
  - Remove `EnvVars.tab`.
  - Remove `tabId` from `IpcRequestContext`.
  - Remove CLI request-path parsing of tab env context.
  - Remove server-side tab-id context fallback.
  - Remove `DANTERM_TAB` from CLI help and from `integrations/danterm/SKILL.md`.
  - Keep pane context: `DANTERM_PANE` remains exported, the CLI still sends
    `IpcRequestContext.paneId`, and the server may derive the live tab/group
    from that pane for implicit human commands.

- Add explicit target flags for outside-safe and agent-safe commands:
  - `tab new --group` targets a group id:

    ```sh
    danterm tab new --group "$GROUP_ID"
    danterm tab new --group "$GROUP_ID" --cmd 'just test' --title tests
    ```

  - `tab rename --tab` targets a tab id:

    ```sh
    danterm tab rename --tab "$TAB_ID" "build"
    danterm tab rename --tab "$TAB_ID" --clear
    ```

  - `pane split --pane` targets a pane id:

    ```sh
    danterm pane split --pane "$PANE_ID" -h --cmd 'just test' --title tests
    ```

  - `pane input --pane` targets a pane id:

    ```sh
    danterm pane input --pane "$PANE_ID" --literal -- 'cargo test'
    ```

  - `theme set --pane` targets a pane id:

    ```sh
    danterm theme set --pane "$PANE_ID" TokyoNight
    danterm theme set --pane "$PANE_ID" --clear
    ```

  - Todo commands target a pane id with `--pane`:

    ```sh
    danterm todo list --pane "$PANE_ID"
    danterm todo add --pane "$PANE_ID" "write failing test"
    danterm todo edit --pane "$PANE_ID" "$TODO_ID" "write failing test, then implement"
    danterm todo done --pane "$PANE_ID" "$TODO_ID"
    danterm todo open --pane "$PANE_ID" "$TODO_ID"
    danterm todo delete --pane "$PANE_ID" "$TODO_ID"
    danterm todo clear-completed --pane "$PANE_ID"
    ```

- Add a focused pane discovery command:
  - CLI shape:

    ```sh
    danterm pane info --pane "$PANE_ID"
    danterm pane info
    ```

  - Output mode is JSON:

    ```json
    {
      "pane": { "id": "...", "title": "...", "cwd": "..." },
      "tab": { "id": "...", "title": "...", "groupId": "..." },
      "group": { "id": "...", "name": "dev" }
    }
    ```

  - `--pane` is the explicit target form agents should use.
  - Missing `--pane` uses `$DANTERM_PANE` context for human convenience inside
    DanTerm.
  - Outside DanTerm without `--pane` fails.
  - The command answers "which tab/group contains this pane?", not "what is
    currently focused?", so it does not reintroduce UI-focus drift.

- Preserve implicit pane-context forms for human use inside DanTerm:
  - `danterm pane info` uses `$DANTERM_PANE` context as the info target.
  - `danterm tab new` uses `$DANTERM_PANE` context to derive the caller pane's
    live group.
  - `danterm tab rename <name>|--clear` uses `$DANTERM_PANE` context to derive
    the caller pane's live tab.
  - `danterm pane split -h|-v ...` uses `$DANTERM_PANE` context as the split
    target.
  - `danterm pane input ...` uses `$DANTERM_PANE` context as the input target.
  - `danterm theme set <name>|--clear` uses `$DANTERM_PANE` context as the
    theme target.
  - `danterm todo ...` uses `$DANTERM_PANE` context as the todo pane.
  - Outside DanTerm, these forms fail because no pane context is available.

- Use group ids for new tabs:
  - Change `tab new --group` to mean group id, not group name.
  - Do not add name-based group targeting in this plan. It can be a separate
    explicit feature later if needed.
  - Explicit group ids always win. Malformed or unknown group ids fail before
    creating a tab or group.
  - Missing `--group` falls back only to pane context and creates the tab in
    the caller pane's live group.

- Update parser and IPC handling:
  - Update `CLIParser.swift` and `cli/main.swift` usage text for explicit
    target flags and pane-context convenience forms.
  - Explicit `--tab`, `--pane`, and `--group` targets always win over pane
    context.
  - Malformed or unknown explicit targets fail instead of falling back.
  - Missing explicit targets fall back to `IpcRequestContext.paneId` only for
    commands that support implicit human use.
  - Missing explicit targets with no pane context fail before mutation.

- Replace the skill's current hard gate:
  - Remove: "If none of these are set, the user is not inside DanTerm; do not
    use this skill."
  - Add: `$DANTERM=1` means the agent originated inside a DanTerm pane.
    `danterm` may still work outside DanTerm if DanTerm is running, but
    agents must use explicit ids for mutation commands.

- Add a short "Targeting rule" near the top of the skill:
  - Assume the user may keep using DanTerm while the agent runs commands.
  - Do not rely on the app's currently focused group, tab, or pane.
  - Use `$DANTERM_PANE` only as the input to `danterm pane info --pane` when
    deriving current ids.
  - If `$DANTERM_PANE` is absent, the agent is outside DanTerm. Run
    `danterm ls`, select pane/tab/group ids only from explicit user-provided
    criteria visible in the JSON: id, exact group name, exact tab
    `customTitle`, exact pane title, or cwd. If the criteria do not produce one
    unique target, ask the user instead of using `selectedTabId`, current
    focus, list order, display title, or a guessed target.
  - For `tab new`, always pass `--group <group-id>`.
  - For `tab rename`, always pass `--tab <tab-id>`.
  - For `pane split`, `pane input`, `theme set`, and todos, always pass
    `--pane <pane-id>`.
  - `pane focus` and `pane read` already require explicit pane ids; keep those
    examples explicit.

- Add a concise "derive targets" recipe:
  - Inside DanTerm, derive the originating pane, tab, and group:

    ```sh
    INFO=$(danterm pane info --pane "$DANTERM_PANE")
    PANE_ID=$(jq -r '.pane.id' <<<"$INFO")
    TAB_ID=$(jq -r '.tab.id' <<<"$INFO")
    GROUP_ID=$(jq -r '.group.id' <<<"$INFO")
    ```

  - Outside DanTerm, do not use implicit app state. Start with `danterm ls`,
    filter only by explicit user-provided criteria visible in the JSON, and
    require exactly one matching pane/tab/group before running any mutation
    command.

- Update examples so copyable forms model the rule:
  - Remove bare mutation forms from agent-facing examples, even though the CLI
    still supports them for humans inside DanTerm.
  - Keep examples like:

    ```sh
    danterm tab new --group "$GROUP_ID"
    danterm tab rename --tab "$TAB_ID" "build"
    danterm pane split --pane "$PANE_ID" -h --cmd 'just test' --title tests
    danterm theme set --pane "$PANE_ID" TokyoNight
    danterm todo list --pane "$PANE_ID"
    danterm todo add --pane "$PANE_ID" "write failing test"
    ```

## Test Plan

- Run protocol parser tests and the pure app test harness:

  ```sh
  just test
  ```

- Add parser tests for valid explicit forms:
  - `danterm pane info --pane <pane-id>` emits the explicit pane param and JSON
    output mode.
  - `danterm tab new --group <group-id>` emits an explicit group id param.
  - `danterm tab rename --tab <tab-id> <name>` emits `Methods.tabRename`,
    `title`, and the explicit tab id param.
  - `danterm tab rename --tab <tab-id> --clear` emits a null title and the
    explicit tab id param.
  - `danterm pane split --pane <pane-id> -h|-v ...` emits the explicit pane
    param.
  - `danterm pane input --pane <pane-id> ...` emits the explicit pane param.
  - `danterm theme set --pane <pane-id> <name>` and `--clear` emit explicit
    pane params.
  - Every todo subcommand accepts `--pane <pane-id>` and emits the explicit
    pane param.

- Add parser tests for valid implicit human forms:
  - `danterm pane info` emits no explicit pane param and JSON output mode.
  - `danterm tab new` emits no explicit group param.
  - `danterm tab rename <name>` and `danterm tab rename --clear` emit no
    explicit tab param.
  - `danterm pane split -h|-v ...` emits no explicit pane param.
  - `danterm pane input ...` emits no explicit pane param.
  - `danterm theme set <name>` and `danterm theme set --clear` emit no
    explicit pane param.
  - Every bare todo subcommand still parses with no explicit pane param and
    the same output modes/params as today.

- Add parser tests that malformed explicit target syntax fails:
  - Missing values after `--group`, `--tab`, or `--pane` fail with usage
    errors.
  - Extra args around explicit `--clear` forms fail with usage errors.

- Add IPC update tests:
  - `pane info --pane <pane-id>` returns that pane plus the containing tab and
    group, even when another tab is selected.
  - `pane info --pane <pane-id>` returns that pane plus the containing tab and
    group when `IpcRequestContext.paneId` points to a different pane.
  - Missing `--pane` for `pane info` uses pane context.
  - Missing `--pane` for `pane info` with no pane context fails.
  - Unknown or malformed explicit pane ids for `pane info` fail and do not fall
    back to pane context.
  - Explicit tab id renames that tab even when another tab is selected.
  - Explicit tab id renames that tab when `IpcRequestContext.paneId` points to
    a different tab.
  - Unknown or malformed explicit tab ids fail and do not mutate any tab or
    fall back to pane context.
  - Missing `--tab` uses pane context to derive the caller pane's live tab.
  - Missing `--tab` with no pane context fails before mutation.
  - `tab new --group <group-id>` creates the tab in that exact group.
  - `tab new --group <group-id>` creates the tab in that group when
    `IpcRequestContext.paneId` points to a pane in a different group.
  - Unknown or malformed explicit group ids fail and do not create a group or
    tab or fall back to pane context.
  - Missing `--group` uses pane context to create the tab in the caller pane's
    live group.
  - Missing `--group` with no pane context fails before mutation.
  - `pane split --pane <pane-id>` splits that exact pane.
  - `pane split --pane <pane-id>` splits that pane when `IpcRequestContext.paneId`
    points to a different pane.
  - Unknown or malformed explicit pane ids fail for `pane split`,
    `pane input`, `theme set`, and todo commands before mutation and do not
    fall back to pane context.
  - Missing `--pane` uses pane context for `pane split`, `pane input`,
    `theme set`, and todo commands.
  - Missing `--pane` with no pane context fails before mutation.
  - `theme set --pane <pane-id>` mutates that exact pane.
  - `theme set --pane <pane-id>` mutates that pane when
    `IpcRequestContext.paneId` points to a different pane.
  - All todo commands with `--pane <pane-id>` mutate or list that pane's todos.
  - Each todo command with `--pane <pane-id>` uses that pane when
    `IpcRequestContext.paneId` points to a different pane.

- Add pure launch-environment coverage:
  - Extract terminal launch env construction into a small testable helper if
    needed.
  - Assert new panes include `DANTERM`, `DANTERM_SOCK`, `DANTERM_PANE`, and
    `DANTERM_TOKEN`.
  - Assert new panes do not include the old tab env var.

- Update and run the CLI helper smoke test:
  - Update `scripts/tests/danterm-cli_test.sh` help assertions for the new
    syntax:
    - `pane info [--pane <pane-id>]`.
    - `tab new --group <group-id>`.
    - `tab rename [--tab <tab-id>] <name>|--clear`.
    - `pane split [--pane <pane-id>] -h|-v`.
    - `theme set [--pane <pane-id>] <name>|--clear`.
    - `todo ... [--pane <pane-id>]`.
  - Assert CLI help documents `DANTERM_PANE` as pane context and does not
    mention the old tab env var.
  - Remove the script's `DANTERM_TAB` export and any `env -u DANTERM_TAB`
    cleanup.
  - Update the script's command smoke coverage to use the new command names and
    explicit forms where appropriate, while still covering at least one
    pane-context human form from inside DanTerm.
  - Add smoke coverage that `pane info --pane "$PANE_ID"` returns matching
    `pane.id`, `tab.id`, and `group.id` fields.
  - Run:

    ```sh
    DANTERM_CLI_TEST_ALLOW_APP_CONTROL=1 just test-cli
    ```

- Run the Codex skill validator with PyYAML available:

  ```sh
  nix shell nixpkgs#python3Packages.pyyaml --command python /Users/dan/.codex/skills/.system/skill-creator/scripts/quick_validate.py integrations/danterm
  ```

- Inspect the final skill text:
  - No mention of the old tab env var.
  - No bare mutation command forms in agent-facing examples.
  - All agent-facing mutation examples use explicit ids.
  - Target derivation uses `$DANTERM_PANE` and `danterm pane info --pane`.
  - Outside-DanTerm targeting says to use `danterm ls` only with explicit
    user-provided criteria visible in the JSON and to ask when no unique target
    exists.
  - Outside-DanTerm targeting does not use `selectedTabId`, current focus, list
    order, display title, or guessed targets.
  - CLI help documents `DANTERM_PANE` as pane context and does not mention the
    old tab env var.

- Manual smoke later from DanTerm:
  - Ask an agent to open a tab in the current group; confirm it derives
    `GROUP_ID` via `pane info --pane "$DANTERM_PANE"` and runs
    `tab new --group "$GROUP_ID" ...`.
  - Ask it to split the originating pane; confirm it derives/uses `PANE_ID`
    via `pane info --pane "$DANTERM_PANE"` and runs
    `pane split --pane "$PANE_ID" ...`.
  - Ask it to rename the originating tab; confirm it derives `TAB_ID` from
    `pane info --pane "$DANTERM_PANE"` and runs
    `tab rename --tab "$TAB_ID" ...`.
  - Ask it to change theme or manage todos; confirm it includes
    `--pane "$PANE_ID"`.
  - From outside DanTerm, ask an agent to target a tab/pane without enough
    identifying detail; confirm it asks for clarification instead of using
    focus, `selectedTabId`, or the first result from `danterm ls`.

## Assumptions

- DanTerm has no compatibility requirement for the old tab env var or tab-id
  context path.
- Pane-context convenience forms are intentional human UX inside DanTerm and
  should remain.
- Scope includes the CLI/API and skill changes needed to make the skill's
  targeting guidance accurate.
- Name-based group targeting is out of scope for this plan; new tabs use group
  ids only.
