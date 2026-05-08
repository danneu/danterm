# danterm CLI: top-level help text

## Context

`danterm` (the CLI helper at `cli/main.swift`) currently has no
discoverable help. Bare `danterm` exits 1 with `danterm: missing
command` to stderr; `danterm --help` / `-h` / `help` are unknown
commands and print `danterm: unknown command: <name>`. The only
hints about what the tool can do are the inline `usage: danterm
<sub> ...` strings thrown when individual subcommands are misused
(`cli/main.swift:53-127`).

We want bare invocation and explicit help flags to print a usage
summary listing the top-level commands. This is the standard CLI
affordance (`git`, `gh`, `cargo`, `kubectl`) and removes the only
way to learn the command surface today (reading the source).

## Approach

Add a single `usageText` constant to `cli/main.swift` and intercept
help cases in `DanTermCLI.main()` *before* `parseCommand` runs --
help is pure local arg handling and must not touch the IPC socket.

### Behavior

| Invocation                              | stdout | stderr      | exit |
| --------------------------------------- | ------ | ----------- | ---- |
| `danterm` (no args)                     | -      | usage text  | 1    |
| `danterm help`                          | usage  | -           | 0    |
| `danterm --help`                        | usage  | -           | 0    |
| `danterm -h`                            | usage  | -           | 0    |
| `danterm <unknown>` / misused subcommand | -     | (unchanged) | 1    |

Bare `danterm` keeps the "you invoked me wrong" signal (exit 1,
stderr) -- matches the existing `missing command` contract and
git's convention. Explicit `help` is a real request and goes to
stdout/exit 0 so it pipes cleanly into `less`/`grep`.

Per-subcommand help (`danterm tab --help`) is **out of scope** --
the existing `usage: danterm tab ...` error strings already cover
misuse, and threading `--help` through every subcommand parser
multiplies surface area for no current need.

### Help text

Single string constant at the top of `DanTermCLI`. Structured as
synopsis + commands + environment. Drawn directly from the
`parseCommand` switch (`cli/main.swift:53-127`) and the `EnvVars`
constants used in `request(...)` (`cli/main.swift:175-180`).

```
danterm -- control DanTerm from the shell

Usage:
  danterm <command> [args]

Commands:
  ls                          Print the full app snapshot as JSON
  tab title [text]            Get or set the current tab title
  tab rename <name>           Rename the current tab
  pane focus <pane-id>        Focus a pane by id
  pane split -h|-v            Split the current pane (horizontal/vertical)
  new-tab [--group <name>]    Open a new tab, optionally in a named group
  send-keys <text>            Send keystrokes to the current pane
  theme set <name>|--clear    Set or clear the current theme
  todo list                   List todos as JSON
  todo add <text>             Add a todo
  todo edit <id> <text>       Edit a todo's text
  todo done <id>              Mark a todo done
  todo open <id>              Reopen a completed todo
  todo delete <id>            Delete a todo
  todo clear-completed        Remove all completed todos
  help, --help, -h            Print this message

Environment:
  DANTERM_SOCK   Path to the DanTerm control socket
  DANTERM_PANE   Pane id for context-aware commands (set by shell integration)
  DANTERM_TAB    Tab id for context-aware commands (set by shell integration)
```

The command list and env-var names must stay in sync with the
parser. There's no automated check today; treat the help string as
"part of the parser" -- any `parseCommand` change touches both.

### Code changes

`cli/main.swift` only.

1. Add `private static let usageText: String = """ ... """` near
   the top of `DanTermCLI`. Trailing newline included.
2. In `static func main()`, before `parseCommand`:

   ```swift
   let rawArgs = Array(CommandLine.arguments.dropFirst())
   if rawArgs.isEmpty {
       fputs(usageText, stderr)
       exit(1)
   }
   if rawArgs == ["help"] || rawArgs == ["--help"] || rawArgs == ["-h"] {
       print(usageText, terminator: "")
       exit(0)
   }
   let command = try parseCommand(rawArgs)
   ```

3. `parseCommand`'s `missing command` branch becomes unreachable
   for the no-arg case (intercept happens first) but keep it -- it
   still guards against `parseCommand([])` from a future caller.

No changes to `Methods`, `EnvVars`, GhosttyApp, the IPC server, or
any other file. No new dependencies.

### Tests

Extend `scripts/tests/danterm-cli_test.sh`. The existing script
runs the bundled CLI from `Contents/Helpers/danterm` and asserts
on stdout/stderr/exit codes (`scripts/tests/danterm-cli_test.sh`,
already wired into `just test-cli`).

Anchor the new block immediately **after** `"$SCRIPT_DIR/dev-build.sh"`
(`scripts/tests/danterm-cli_test.sh:15`) and **before** the `pkill`/`open`
pair (`scripts/tests/danterm-cli_test.sh:17-18`). That position
proves help works against the freshly built helper but does not
require the app to be running.

The script runs under `set -euo pipefail`
(`scripts/tests/danterm-cli_test.sh:3`), so a bare command that
exits non-zero (the no-arg case is expected to exit 1) aborts the
script before `status=$?` can capture it. Use the same `if ...; then
...; else ...; fi` pattern the script already uses for the
expected-failure case at `scripts/tests/danterm-cli_test.sh:94`.

Add a `run_cli` helper that captures stdout, stderr, and status
into reusable temp files:

```bash
out=$(mktemp); err=$(mktemp)
run_cli() {
    : >"$out"
    : >"$err"
    if "$CLI_PATH" "$@" >"$out" 2>"$err"; then
        status=0
    else
        status=$?
    fi
}
```

Then each of the four cases is:

```bash
run_cli            # bare; expected: status 1, stderr non-empty, stdout empty
run_cli help       # expected: status 0, stdout non-empty, stderr empty
run_cli --help     # same as `help`
run_cli -h         # same as `help`
```

with the per-case assertions (status, stream emptiness, no
`^danterm:` prefix on bare, stable tokens) listed below applied
between calls.

Per-case assertions:

- **No args (`"$CLI_PATH"`):**
  - `status` == 1
  - `out` is empty (stdout silent)
  - `err` is non-empty
  - `err` does NOT match the old `^danterm:` error-line prefix
    (catches an implementation that prepends `danterm: missing
    command` before/in addition to the usage block)
  - `err` contains the stable tokens listed below

- **`help`, `--help`, `-h` (each tested separately):**
  - `status` == 0
  - `err` is empty (stderr silent)
  - `out` is non-empty
  - `out` contains the stable tokens listed below

**Stable tokens to assert** (in the appropriate stream for each
case): `Usage:`, `ls`, `pane split -h|-v`, `todo clear-completed`,
`DANTERM_SOCK`. These pin the synopsis line, the simplest
command, a syntactically distinctive command, the longest
subcommand path, and the env-var section -- so a regression that
omits whole groups (commands, env) or routes output to the wrong
stream fails loudly. Wording around tokens (descriptions,
ordering) is free to evolve without test churn.

Use `grep -qF` (fixed-string) for these -- `pane split -h|-v`
contains regex metacharacters and we do not want to escape them
in the test.

No Swift unit tests added: the `parseCommand` helpers are
`private static` and there's no existing test target for the CLI
binary -- adding one is a separate refactor and out of scope.

## Critical files

- `cli/main.swift` -- add `usageText`, intercept help in `main()`.
- `scripts/tests/danterm-cli_test.sh` -- add four assertions.

## Verification

1. `just build` -- compiles without warnings.
2. `just test` -- existing Swift unit tests still pass (sanity).
3. `just test-cli` (with the dev app running) -- existing IPC
   tests pass and the new help-text block passes.
4. Manual smoke from a shell:
   - `danterm` -> usage on stderr, `$? == 1`.
   - `danterm --help | head` -> usage on stdout, `$? == 0`, pipe
     works (i.e. SIGPIPE-safe).
   - `danterm -h`, `danterm help` -> same as `--help`.
   - `danterm ls`, `danterm tab title`, etc. -> unchanged.
   - `danterm bogus` -> still `danterm: unknown command: bogus`,
     exit 1 (regression check).
