# Flip `danterm` CLI defaults to agent-safe behavior

## Context

`danterm tab new` and `danterm pane split` are, in practice, an **agent-only
surface**: humans create tabs via `Cmd-T` (New Tab), `Cmd-Shift-T` (New Tab at
End of Group), and the `+` button (`AppDelegate.swift:265-269`,
`WindowChromeView.swift`), none of which touch the CLI. Yet the CLI inherits
*interactive* defaults that fight the way agents must use it:

1. **Position** defaults to `.afterSelected`, which resolves against
   `selectedTabId` -- live focus state. The skill's own targeting rule says
   "Treat `selectedTabId` as display state, not as a targeting source. Never
   target by `selectedTabId`, current focus, list order." So the default
   position *directly contradicts the discipline the skill teaches*: an agent
   that omits the flag drops its tab wherever the user's cursor happens to be.
   This is closer to a latent defect than an ergonomics nit.
2. **Focus** defaults to foreground (focus-stealing), disruptive for autonomous
   work the user did not just ask for.

Today the skill papers over both with repeated "prefer `--background`" /
"choose a position mode" nagging that agents routinely forget. Soft guidance
only helps when remembered; it cannot be enforced.

**Outcome:** make the safe, deterministic behavior the CLI default so agents do
the right thing even when they forget, and add explicit inverse flags for the
minority cases. The interactive UI keeps its current defaults untouched.

## Decisions (locked)

- **Position:** CLI defaults to `atGroupEnd` (deterministic, focus-independent).
  Keep `--after-selected` / `--after-tab` as explicit opt-ins.
- **Focus:** CLI defaults to background. Add `--foreground` for the "user asked
  me to switch to it" case.
- Keep `--background` as a valid (now redundant) explicit flag for
  back-compat with existing scripts and skill recipes.
- Passing both `--background` and `--foreground` is a parse error.

### Focus semantics differ by command (important)

`--foreground` does NOT mean the same thing for the two commands, and the
docs/wording must reflect that:

- **`tab new --foreground`**: focuses *and selects* the new tab (this is exactly
  the old foreground default we are renaming the trigger for). Safe to describe
  as "switch to it."
- **`pane split --foreground`**: only sets `tab.focusedPaneId` on the target tab
  (`Update.swift:179-185`); it does **not** navigate/select that tab. If the
  split target is in another tab, the user keeps looking at their current tab
  (`UpdateIpcTests.swift:211` pins `selectedTabId` unchanged). So describe it as
  "focus the new pane *within its tab*", never "switch to it." For cross-tab
  navigation, the recipe is: split, read the returned `pane.id`, then
  `danterm pane focus <new-pane-id>`. We are NOT changing `splitPane`'s update
  path -- this is a documentation/wording correction only.

## Design / layering

Encode the new defaults in the **CLI parser layer** (`CLIParser.swift`), not in
the arg-parser structs and not in the IPC handler:

- The arg parsers (`parseTabNewArgs`, `parsePaneSplitArgs`) stay faithful
  reflectors of *which flags were typed*. `position: nil` still means "no
  position flag"; we add a `foreground: Bool` flag-presence field. This keeps
  the struct-equality arg tests meaningful.
- `parseTabNewCommand` / `parsePaneSplitCommand` apply the agent-surface
  *policy*: absent position -> emit `atGroupEnd`; not-foreground -> emit
  `background: true`.
- The IPC handler in `Update.swift` (defaults `.afterSelected` / `false`) and
  the UI path (`Msg.createTab` defaults) are **left unchanged**. Only the CLI
  surface flips.

The CLI will always emit an explicit `background` bool (`true` by default,
`false` on `--foreground`) so the wire shape is unambiguous and independent of
the handler's fallback.

## Files to change

### Arg parsers (add `--foreground` + conflict detection)

- `lib/DanTermProtocol/Sources/DanTermProtocol/TabNewArgs.swift`
  - `ParsedTabNew`: add `foreground: Bool` (default `false` in init, so existing
    test constructions still compile).
  - `TabNewParseError`: add `case conflictingFocusFlags`.
  - `parseTabNewArgs`: parse `--foreground`; throw `conflictingFocusFlags` if
    both `--background` and `--foreground` are seen.
- `lib/DanTermProtocol/Sources/DanTermProtocol/PaneSplitArgs.swift`
  - `ParsedPaneSplit`: add `foreground: Bool` (default `false`).
  - `PaneSplitParseError`: add `case conflictingFocusFlags`.
  - `parsePaneSplitArgs`: parse `--foreground`; same conflict throw.

### CLI parser (apply agent-surface policy)

- `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift`
  - `parseTabNewCommand`:
    - When `parsed.position == nil`, emit `params["position"] = .string("atGroupEnd")`.
      Explicit position flags map as today.
    - Emit `params["background"] = .bool(parsed.foreground ? false : true)`.
    - Add `.conflictingFocusFlags` to the `do/catch` switch (Swift exhaustive)
      -> usage message naming the `--background`/`--foreground` conflict.
    - Add `[--foreground]` to the `usage` string.
  - `parsePaneSplitCommand`:
    - Emit `params["background"] = .bool(parsed.foreground ? false : true)`.
    - Add `.conflictingFocusFlags` to the `do/catch` switch.
    - Add `[--foreground]` to the usage string.

### Help text

- `cli/main.swift` `usageText`: add `[--foreground]` to the `tab new` and
  `pane split` synopsis lines; add a short note that the CLI defaults to
  background + at-group-end (and that the UI is unaffected). Per the focus
  semantics above, the note must NOT promise that `pane split --foreground`
  switches tabs.

### CLI help smoke test

- `scripts/tests/danterm-cli_test.sh`: this already greps stable help tokens in
  both the stderr (bare invocation, lines ~42-49) and stdout (help, ~58-65)
  paths. The existing `pane split [--pane <pane-id>] -h|-v` substring grep keeps
  passing (it is a prefix of the longer line). Add, in BOTH paths:
  - a stable full-synopsis substring for each command's `[--foreground]` (e.g.
    grep the `tab new ... [--foreground]` line tail and the `pane split ...
    [--foreground]` line tail separately) so the two commands cannot drift
    independently -- a bare `grep -qF '[--foreground]'` would pass if only one
    advertised it.
  - a grep for a stable default-note phrase.
  - Note: the script is env-gated -- it exits 2 unless
    `DANTERM_CLI_TEST_ALLOW_APP_CONTROL=1` (lines 10-12). Run it via
    `DANTERM_CLI_TEST_ALLOW_APP_CONTROL=1 just test-cli`.

### Skill docs (ship in the same change -- AGENTS.md CLI-doc rule)

- `integrations/danterm/SKILL.md`
  - CLI API synopsis: add `[--foreground]` to `tab new` / `pane split`; note
    the agent-safe defaults (background, at-group-end).
  - Delete the repeated "prefer `--background`" / "choose a position mode"
    nagging in "Targeting rule" and "Rules for agents". Replace with: defaults
    are agent-safe; pass `--foreground` only when the user asked to switch;
    pass `--after-tab <tab-id>` / `--after-selected` for an explicit anchor.
  - Update recipes that sprinkle `--background` everywhere (lines ~131-133,
    ~157-159) -- drop the now-default flag. For `tab new`, show `--foreground`
    in the "switch to it" example. For `pane split`, describe `--foreground` as
    "focus the new pane within its tab" and add the cross-tab recipe (split ->
    read `pane.id` -> `danterm pane focus <new-pane-id>`); do not imply a tab
    switch.

## TDD approach

Write and run the failing tests first (`just test` / the lib XCTest suite),
confirm they fail for the expected reason, then implement. New tests get the
Intent / Why it exists / Scenario preamble (the existing neighbors predate that
convention; new ones follow it).

### Arg-parser tests

- `lib/.../Tests/DanTermProtocolTests/TabNewArgsTests.swift`
  - `--foreground` parses to `ParsedTabNew(..., foreground: true)`.
  - `--background --foreground` throws `TabNewParseError.conflictingFocusFlags`.
  - Existing `--background` test still asserts `background: true, foreground: false`.
- `lib/.../Tests/DanTermProtocolTests/PaneSplitArgsTests.swift`
  - `-h --foreground` parses to `ParsedPaneSplit(..., foreground: true)`.
  - `-h --background --foreground` throws `conflictingFocusFlags`.

### CLI-parser tests (the behavior contract)

- `lib/.../Tests/DanTermProtocolTests/CLIParserTests.swift` -- TWO existing tests
  encode the OLD contract and must be revised (they will fail otherwise):
  - **Revise** `testTabNewWithoutPositionFlagOmitsPositionParams:40` (asserts
    bare `tab new` ⇒ position `nil`): now ⇒ `params["position"] ==
    .string("atGroupEnd")` and `params["background"] == .bool(true)`. Rename if
    the "omits" name no longer fits.
  - **Revise** `testImplicitHumanMutationFormsStillParseWithoutExplicitTargets:111`:
    keep the implicit-target assertions (`group`/`pane`/`tab` stay `nil`) but
    change the `tab new` and `pane split -h` background expectations from `nil`
    to `.bool(true)`.
  - If the `[--foreground]` addition changes the `tab new` usage string, keep the
    test-side mirror constant `tabNewUsageWithPositionFlags` in sync so
    `testTabNewConflictingPositionFlagsThrowUsageError:46` still matches.
  - New cases:
    - `tab new --after-selected` ⇒ `position == afterSelected`, `background ==
      true` (default focus preserved).
    - `tab new --foreground` ⇒ `background == .bool(false)`, position still
      `atGroupEnd`.
    - `tab new --at-group-end` ⇒ `atGroupEnd` (explicit form of new default).
    - `tab new --background --foreground` ⇒ `parseCLI` throws (usage error).
    - `pane split -h` ⇒ `background == .bool(true)`.
    - `pane split -h --foreground` ⇒ `background == .bool(false)`.
    - `pane split -h --background --foreground` ⇒ throws.
  - Position-flag mutual exclusion test is unaffected (explicit flags unchanged).

### CLI help smoke test

- `scripts/tests/danterm-cli_test.sh`: add `[--foreground]` and default-note
  assertions in both the stderr and stdout help blocks (see "Files to change").

## Back-compat

- Existing `--background` invocations: unchanged (now redundant, still valid).
- Existing explicit position flags: unchanged.
- The only behavior change is for calls that *omitted* flags and relied on the
  old foreground / after-selected defaults -- exactly the calls the skill
  already discouraged.
- IPC handler and UI defaults are untouched, so no in-app behavior changes.

## Verification

1. `just test` (and the lib XCTest target) -- all new/updated parser tests pass;
   full suite green.
2. `just build` -- app + CLI compile.
3. Manual smoke (`just build-run`, then in a DanTerm pane):
   - `danterm tab new --group "$GROUP_ID"` -> tab appears at group end, focus
     stays on current tab.
   - `danterm tab new --group "$GROUP_ID" --foreground` -> new tab is focused.
   - `danterm pane split --pane "$PANE_ID" -h` -> split appears, caller's pane
     keeps focus; `... --foreground` focuses the new pane *within its tab*
     (does NOT switch the app to that tab).
   - `danterm tab new --background --foreground` -> exits non-zero with the
     conflict usage message on stderr (and the same for `pane split`).
4. `danterm help` shows `[--foreground]` on both commands and the default note;
   `DANTERM_CLI_TEST_ALLOW_APP_CONTROL=1 just test-cli` passes (the script is
   env-gated and exits 2 otherwise); SKILL.md synopsis matches.

## Implementation notes

- Updated `scripts/tests/danterm-cli_test.sh` target discovery to read the
  selected tab's `focusedPaneId` because the current `danterm ls` shape nests
  panes under `groups[].tabs[].rootNode` and does not expose a top-level
  `.panes[0]`.
