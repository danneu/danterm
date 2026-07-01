# Remove `doctor --all`/`-v`; always print all rows

## Context

`danterm doctor` currently hides `OK` rows by default and only prints them when
`--all` (or `-v`) is passed. The flag adds surface area for no real benefit: a
health check is more useful when it always shows every check it ran, so the user
can see what passed as well as what failed. This change removes the flag and
makes `doctor` always print all rows (OK included), followed by the existing
summary footer.

The flag is a single boolean, `showOK`, threaded from the CLI arg loop in
`cli/main.swift` into the pure renderer `renderDoctorReport(_:showOK:)` in
`lib/DanTermCore/Sources/DanTermCore/Doctor.swift`. Removing it is mechanical.

**Do not touch** the unrelated `-v` = vertical-split flag on `pane split`
(`cli/main.swift:40`, `PaneSplitArgs.swift`, `SKILL.md` lines ~25/202/215/219,
and the `pane split` lines in the shell test). That `-v` is a different command.

**Decision:** keep rejecting stray arguments. After the change `doctor` takes no
arguments, so any arg (`doctor --bogus`, `doctor foo`) still errors. This
preserves the existing `doctor --bogus` behavior and its test.

## Changes

### 1. Renderer — `lib/DanTermCore/Sources/DanTermCore/Doctor.swift` (lines 81-96)

Drop the `showOK` parameter and the OK-hiding branch; update the doc comment.

```swift
/// Renders doctor checks in the CLI's plain text format: one line per check
/// (OK rows included), followed by the summary footer.
func renderDoctorReport(_ checks: [DoctorCheck]) -> String {
    let body = checks.map { check -> String in
        let prefix = statusPrefix(check.status)
        guard let message = check.message, !message.isEmpty else {
            return "\(prefix) \(check.title)"
        }
        return "\(prefix) \(check.title): \(message)"
    }

    return (body + [renderFooter(checks)]).joined(separator: "\n") + "\n"
}
```

`renderFooter` and `doctorExitCode` are unaffected (they already count OK rows
independently of `showOK`).

Also fix two now-stale comments in the same file:

- Line 29-30 (`DoctorCheck` doc): OK rows still carry no message, but the reason
  is no longer "so the default report can collapse them to the footer count."
  Reword to explain OK rows print as a bare `OK <title>` line with nothing to
  report.
- Line 305 (`renderFooter` doc): "including hidden OK rows" -> "including OK
  rows" (they are no longer hidden).

### 2. CLI parse/dispatch — `cli/main.swift`

- **`runDoctor` (lines 158-175):** remove the `showOK` var and the `--all`/`-v`
  case; keep the stray-arg rejection; call the renderer with no `showOK`.

  ```swift
  private static func runDoctor(_ args: [String]) throws {
      for arg in args {
          if arg.hasPrefix("-") {
              throw CLIParseError("unknown flag: \(arg)")
          }
          throw CLIParseError("unexpected argument: \(arg)")
      }

      let checks = evaluateDoctor(gatherDoctorFacts())
      print(renderDoctorReport(checks), terminator: "")
      exit(doctorExitCode(for: checks))
  }
  ```

- **Usage text (line 55):** `doctor [--all|-v]` -> `doctor`, padding spaces so
  the `Check DanTerm integration health` description stays in its current column.

### 3. Unit test — `lib/DanTermCore/Tests/DanTermCoreTests/DoctorEvaluatorTests.swift` (lines 241-261)

Rework the `renderer hides OK unless showOK...` test to a single render call that
asserts OK rows are always printed. Rename it (e.g. `rendererPrintsAllRowsIncludingOKAndCountsFooterStatuses`),
call `renderDoctorReport(checks)` once, flip the OK assertion to expect the OK
line present, drop the second (verbose) render call, and keep the footer
assertion (`"1 error, 1 warning, 1 info, 1 ok, 1 skipped\n"`) unchanged.

### 4. Shell integration test — `scripts/tests/danterm-cli_test.sh`

The smoke test must prove **both** halves of the removed CLI contract: help no
longer advertises the flag, and the old flags are now rejected. A bare
`grep -qF 'doctor'` is too weak (it would still pass a revert that kept
`doctor [--all|-v]` and still accepted the flags), so:

- Lines 51 and 73 (help assertions, on `$err` for the bare-invocation block and
  `$out` for the `help`/`--help`/`-h` loop): replace each
  `grep -qF 'doctor [--all|-v]'` with a pair —
  - positive: the doctor line still appears with its description, tolerant of
    padding, e.g. `grep -qE '^ *doctor +Check DanTerm integration health'`;
  - negative: `! grep -qF 'doctor [--all|-v]'` (the old flag advertisement is
    gone).
- Lines 92-102: move the `grep -qF 'OK '` assertion (line 101) onto the plain
  `doctor` invocation block (lines 92-96), since OK rows now always print. Then
  replace the old `doctor --all` acceptance block (lines 97-102) with rejection
  checks for **both** dropped forms:
  - `doctor --all` -> exit != 0, empty stdout, stderr `danterm: unknown flag: --all`;
  - `doctor -v` -> exit != 0, empty stdout, stderr `danterm: unknown flag: -v`.
  (Reuse the existing `run_doctor_with_temp_home` helper and the
  `! grep -qF 'DanTerm is not running'` guard already used in these blocks.)
- Lines 103-107 (`doctor --bogus`): leave as-is — still valid, since we keep the
  unknown-flag rejection.

### 5. Docs

- **`integrations/danterm/SKILL.md`** (required by AGENTS.md when the CLI surface
  changes): line 30 `danterm doctor [--all|-v]` -> `danterm doctor`; in the
  "Check integration health" section (lines 259-268) delete the `danterm doctor
  --all` example and reword the semantics sentence to say `doctor` prints all
  rows (INFO/SKIP/WARN/ERROR/OK) plus the footer, exit 1 only on ERROR.
- **`README.md`** (line 109): remove the trailing `; danterm doctor --all also
  prints OK rows` clause (all rows print by default now).

### Not edited

`plans/impl/2026-06-09-danterm-doctor-integration-health.md` — historical
implemented-plan record; leave as-is.

## Verification

1. `just test` — runs the core Swift Testing suite (includes the reworked
   `DoctorEvaluatorTests`) plus protocol/support suites and lints.
2. `swift test --package-path lib/DanTermCore --filter DoctorEvaluatorTests` —
   targeted run of the reworked renderer test.
3. Build and exercise the CLI manually:
   - `just build` then run the built `danterm`:
     - `danterm doctor` — exits 0/1 by health, prints OK rows now, no flag needed.
     - `danterm doctor --all` and `danterm doctor -v` — now error
       (`danterm: unknown flag: --all` / `-v`), confirming removal.
     - `danterm doctor --bogus` — still `danterm: unknown flag: --bogus`, exit != 0.
     - `danterm help` — usage line shows `doctor` with no `[--all|-v]`.
4. `DANTERM_CLI_TEST_ALLOW_APP_CONTROL=1 bash scripts/tests/danterm-cli_test.sh`
   (or `just test-cli` with that env var set) — the doctor + help-text
   integration assertions. The script hard-exits at line 10 without the
   `DANTERM_CLI_TEST_ALLOW_APP_CONTROL=1` gate, and it launches the app, so run
   it from a GUI session, not in `just test`.
