# `danterm doctor` -- integration health-check subcommand

## Context

DanTerm has several *integration* points that break silently: agent notification
hooks in `~/.claude/settings.json` (Claude) and `$CODEX_HOME/hooks.json` /
`$CODEX_HOME/config.toml` (Codex) whose absolute paths go stale after a
move/upgrade; the per-agent DanTerm skill not symlinked into a discovery root; a
`danterm` executable on PATH that can point at an older install; an app-installed
`/usr/local/bin/danterm` link that can dangle for manual `.app` users; an app run
from a translocated DMG so nothing installs; `jq` missing from the agents' PATH.
When any of these fail the user has no signal -- they just blame the app.

`danterm doctor` is a `brew doctor`-style checklist that runs entirely in the
CLI (no app, no IPC -- so it works even when the app is crashed or unlaunched),
reports only what's wrong, and tells the user how to fix each item.

**Scope: v1 is integration health only** -- the agent hooks/skills, the `danterm`
executable found on PATH, the manual-app `/usr/local/bin/danterm` installer link,
app translocation, and `jq`. Config validity, crash recovery, and terminfo are
deliberately deferred (they need on-disk/schema facts this slice doesn't gather)
and are tracked under
[Follow-up checks](#follow-up-checks-out-of-v1-scope).

## Output / status model

Each check resolves to one status; the message rule per status:

- **OK** -- print nothing (collapsed to a count; shown only under `--all`).
- **SKIP** -- one line explaining *why it didn't apply* (gate not met).
- **INFO** -- one advisory line.
- **WARN / ERROR** -- the concrete issue (with the real `<path>`/`<value>`) plus
  the resolution.

Default run prints WARN/ERROR/INFO/SKIP lines + a summary footer
(`2 errors, 1 warning, 3 ok, 2 skipped`). `--all` (alias `-v`) also lists OK
lines. Exit code: **1 if any ERROR**, else 0 (WARN/INFO/SKIP do not fail), so it
is scriptable. `--json` is noted as future, not v1.

**Translocation is a standalone signal, not a gate.** A translocated/uninstalled
running copy is its own WARN; it does NOT suppress any other check. The agent,
skill, `jq`, PATH CLI, and manual app-link checks read absolute paths
(`~/.claude`, `$CODEX_HOME`, the skill roots, `/usr/local/bin`) and PATH -- all
independent of where the running CLI copy lives -- so they stay correct (and a
genuinely dangling hook still surfaces as ERROR) even when the copy running
doctor is translocated.
(Earlier drafts had translocation short-circuit those checks to `SKIP (blocked)`;
that was wrong -- it would hide real dangling-hook ERRORs, since the running
copy's location has no bearing on whether the absolute paths in the agent config
files resolve.)

## The checks (v1 integration set)

Per-agent checks are distinct items. Agent rule: **WARN if the agent is present
but DanTerm isn't wired to it; INFO if the agent isn't installed.**

| Check | Status ladder | Message on non-OK |
|---|---|---|
| Claude hooks valid | ERROR if a wired hook path dangles / ERROR if a wired hook exists but isn't executable / WARN if the hook file fails to parse (`hooksParseError`) / WARN if `~/.claude` present but no DanTerm hook / INFO if `~/.claude` absent | dangling ERROR: `Hook in ~/.claude/settings.json points to missing <path>; repoint to <hookdir>/<name> or remove it.` (`<hookdir>` = `facts.bundledHookDir` when set, else the `/Applications/DanTerm.app/Contents/Resources/danterm-hooks` literal) not-executable ERROR: `Hook <path> exists but isn't executable, so the agent can't run it; restore it with chmod +x <path> (or reinstall from the DanTerm bundle).` parse-error WARN: `~/.claude/settings.json is malformed (<error>); DanTerm can't read its hooks.` unwired WARN: `Claude Code found but DanTerm notifications aren't set up -- add hooks (see docs).` INFO: `Claude Code not installed.` |
| Claude skill installed | OK if the skill is in either `~/.claude/skills/danterm` or the shared `~/.agents/skills/danterm` / WARN if `~/.claude` present but skill in neither root / SKIP if `~/.claude` absent (Claude-hooks row already reports absence) | WARN: `Skill missing. Symlink the DanTerm agent skill into <skillSearchPaths[0]> -- source it from the Nix danterm-agent-skill output or the repo's integrations/danterm (see README "Agent Skill"); it isn't shipped in the app bundle.` (destination rendered from `skillSearchPaths[0]` -- `~/.claude/skills/danterm` by default) SKIP: `Claude Code not installed.` |
| Codex hooks valid | same ladder as Claude hooks (incl. the not-executable ERROR and the parse-error WARN); present = `$CODEX_HOME/` (default `~/.codex/`) exists; hooks sourced from `$CODEX_HOME/hooks.json` (JSON, same shape as Claude) + `$CODEX_HOME/config.toml` (inline `[[hooks.*]]`) | as above, with `danterm-codex-agent-session`; parse-error WARN is JSON-only -- names `$CODEX_HOME/hooks.json` (the `config.toml` inline-hook scan is best-effort, with no malformed-TOML diagnostic) |
| Codex skill installed | same ladder as Claude skill, but OK if the skill is in either `$CODEX_HOME/skills/danterm` (default `~/.codex/skills/danterm`) or the shared `~/.agents/skills/danterm` -- both are real Codex discovery roots, so checking only one false-WARNs the other | WARN: `Skill missing. Symlink the DanTerm agent skill into <skillSearchPaths[0]> -- source it from the Nix danterm-agent-skill output or the repo's integrations/danterm (see README "Agent Skill"); it isn't shipped in the app bundle.` (destination resolved from `skillSearchPaths[0]`, honors `$CODEX_HOME`) SKIP: `Codex not installed.` |
| `danterm` on PATH resolves to this running CLI | WARN / always runs | missing: `No danterm executable found on PATH; add the installed CLI to PATH (Nix profile, Home Manager profile, or DanTerm menu > "Install danterm Command in PATH").` mismatch: `danterm on PATH resolves to <path>, but this doctor command is running from <argv0>; move the intended install earlier in PATH or run that binary's doctor.` |
| Manual app CLI link healthy (`/usr/local/bin/danterm`) | WARN only when the running/PATH CLI appears to be a manual `.app` install outside Nix/profile management; otherwise OK | dangling: `/usr/local/bin/danterm is missing or stale -> DanTerm menu > "Install danterm Command in PATH".` non-symlink: `/usr/local/bin/danterm exists but is a regular file/directory, not a symlink, so "Install danterm Command in PATH" can't replace it; remove or rename it first, then reinstall.` |
| App not translocated | WARN / always runs | `DanTerm is running from a quarantined/translocated copy, so the CLI link and hook paths are ephemeral. Move DanTerm.app to /Applications in Finder (or: xattr -dr com.apple.quarantine /Applications/DanTerm.app), relaunch.` |
| `jq` on PATH | WARN / SKIP if no hooks wired in any agent | `jq not found; agent hooks need it. brew install jq -- ensure it lands in /usr/local/bin or /opt/homebrew/bin so GUI-launched agents see it.` SKIP: `No DanTerm agent hooks configured.` |

## Architecture (follows the pure-core / portable-support / runtime split)

Three pieces, mirroring `Persistence` (pure codec in core) + `RecoveryStore`
(IO in support) + runtime wiring:

1. **Pure evaluator + renderer** -- `lib/DanTermCore/Sources/DanTermCore/Doctor.swift`
   - `func evaluateDoctor(_ facts: DoctorFacts) -> [DoctorCheck]` -- pure decision
     logic: applies the status ladders. Translocation is one standalone WARN, not
     a gate; the `jq` gate is derived here from whether any agent has a wired
     DanTerm hook. Reads the `DoctorFacts` DTO from `DanTermProtocol`. No IO.
   - `func renderDoctorReport(_ checks: [DoctorCheck], showOK: Bool) -> String` --
     pure string formatting (status prefix + message + footer). Color-agnostic
     (TTY/color decided in the CLI if ever added).
   - Models the existing pure-core functions (e.g. `Projections.swift`):
     value-in, value-out, no IO.
   - Must stay clean under `scripts/core-purity-lint.sh` (no `FileManager`,
     `Process`, `import Darwin`) -- it only reads the injected `DoctorFacts`.

2. **Probe layer** -- `lib/DanTermSupport/Sources/DanTermSupport/DoctorProber.swift`
   - `func gatherDoctorFacts(env: DoctorProbeEnv = .live) -> DoctorFacts` -- the
     returned `DoctorFacts` is the shared `DanTermProtocol` DTO (support cannot
     name a core type, so the carrier lives in the module both depend on).
     Gathers every fact from the real system: stat/readlink; JSON decode of
     `~/.claude/settings.json` and `$CODEX_HOME/hooks.json` (default `~/.codex`;
     identical hook shape, so one shared JSON walker serves both -- and only these
     JSON files yield a `hooksParseError`) plus a best-effort scan of
     `$CODEX_HOME/config.toml` for inline `[[hooks.*]]` danterm `command` lines
     (the inline hooks are TOML array-of-tables; full TOML parsing and repo-local
     `.codex/*` are out of v1 scope, so a malformed `config.toml` produces NO
     parse-error WARN -- doctor isn't repo-aware); per-agent skill presence across
     the agent's known skill roots (Claude: `~/.claude/skills/danterm` or shared
     `~/.agents/skills/danterm`; Codex: `$CODEX_HOME/skills/danterm` or shared
     `~/.agents/skills/danterm`); PATH scans for executable `danterm` and `jq`.
   - `DoctorProbeEnv` is the injectable seam (`fileManager`, `environment`,
     `homeDirectory`, `argv0`, and `installerDeps: CLIPathInstaller.Dependencies`),
     defaulted to live -- same pattern as `CoreEnv` (`CoreEnvironment.swift`) and
     `RecoveryStore`'s defaulted params. Tests inject temp dirs / fake env, and a
     temp-fixture `installerDeps` (destination/source/bundle URLs rooted under a
     temp dir) so the manual app-link + translocation facts are exercised
     hermetically, never against the real `/usr/local/bin/danterm`. (No subprocess
     seam in v1 -- every fact is a file/PATH/readlink read.)
   - Resolves the primary `danterm` command from injected PATH first. The prober
     records the first executable PATH candidate (raw path + resolved path), and the
     evaluator compares its resolved path with `runningBinaryResolved`. This is the
     top-level CLI health check because Nix/Home Manager installs are healthy when
     PATH points at the current running helper, even if `/usr/local/bin/danterm` is
     absent.
   - **Reuses** `CLIPathInstaller` (same module) for the secondary manual-app link:
     translocation check
     (`CLIPathInstaller.swift:97`), symlink target read (`symlinkDestinationURL()`
     :223), and its `Dependencies` injection seam (destination/source/bundle URLs,
     :17-54). Add a small internal `installDiagnostics()` instance method (returning
     `(entry: SymlinkEntry, sourceMatches: Bool, translocated: Bool)`) that reads off
     the installer's injected `deps` -- NOT the hardcoded `.default` constants -- so the
     prober reuses the readlink/translocation logic AND a test can point
     `deps.destinationURL` at a temp symlink. It classifies `entry` from the same
     `resourceValuesIfFileExists` read (`.isSymbolicLinkKey`/`.isDirectoryKey`) that
     `ensureDestinationCanBeReplaced()` (`:197-209`) already uses: no entry -> `.missing`,
     a symlink -> `.symlink` (target via `symlinkDestinationURL()`), anything else ->
     `.nonSymlink` -- so the real-file/dir state the installer would reject surfaces as
     its own WARN instead of collapsing into the "missing or stale" remedy. The
     manual app-link evaluator only warns from these facts when the PATH/running CLI
     appears to come from a manual `.app` install outside Nix/profile management;
     Nix/profile-managed commands can legitimately have no `/usr/local/bin/danterm`.
     The prober builds its `CLIPathInstaller`
     from `env.installerDeps` (live `.default` in production; a temp fixture in
     tests, exactly the `Dependencies` injection `CLIPathInstallerTests` already
     uses via `makeInstallerFixture`, including a `bundleURL` override to simulate
     `/AppTranslocation/`).

3. **CLI wiring** -- `cli/main.swift`
   - Intercept `doctor` right after the `help` block (`main.swift:92-94`), before
     `parseCLI`/`request` -- never touches the socket. Parse `--all`/`-v` inline.
   - Body: `let facts = gatherDoctorFacts(); let checks = evaluateDoctor(facts);
     print(renderDoctorReport(checks, showOK: all)); exit(checks.contains{ $0.status == .error } ? 1 : 0)`.
   - Add `doctor` to the hand-maintained `usageText` (`main.swift:69` area).
   - `CLIParser` is **untouched** (doctor is local-only, like `help`).

**Module reachability (the one wiring step):** add two tracked symlinks mirroring
the app so core+support compile into the CLI same-module --
`cli/DanTermCore -> ../lib/DanTermCore/Sources/DanTermCore` and
`cli/DanTermSupport -> ../lib/DanTermSupport/Sources/DanTermSupport`. SwiftPM
compiles everything under the target's `path: "cli"`, so no `Package.swift`
dependency edits are needed for the CLI build and the core/support *symbols* stay
annotation-free (same-module, plain `internal`). (The app already proves
core+support coexist same-module without collision.) `DanTermProtocol` is already
a CLI dependency.

The one exception is the new `DoctorFacts` DTO. It lives in `DanTermProtocol`,
which core and support reach as a genuine cross-module dependency -- both packages
already declare `.package(path: "../DanTermProtocol")` and `import DanTermProtocol`
(e.g. core's `Update.swift`, support's `IpcConnection.swift`). So `DoctorFacts`
follows DanTermProtocol's normal convention: `public struct`, `public` stored
properties, and an explicit `public init` (Swift's synthesized memberwise init is
`internal`, so the support prober could not construct it otherwise), exactly like
`JsonRpcRequest` in `Envelope.swift`.

## Data model (`DoctorFacts` in `DanTermProtocol`; `DoctorCheck` in core)

```
// in DanTermProtocol -- the shared DTO: produced by the support prober, read by
// the core evaluator. It lives here because it is the only module both depend on
// (support must not import core). `public` throughout because core and support
// reach DanTermProtocol cross-module; the memberwise init is written out because
// Swift's synthesized one is `internal`.
// Manual app `/usr/local/bin/danterm` classified so the evaluator picks the right
// remedy only when that app-installer link is relevant. `.nonSymlink` needs the
// "remove or rename it first" fix, because CLIPathInstaller refuses to replace a
// real file/dir (`destinationIsNotSymlink`/`destinationIsDirectory`,
// CLIPathInstaller.swift:197-209), so the plain "Install ... in PATH" remedy would throw.
public enum SymlinkEntry {
    case missing                                     // nothing there -> Install menu works
    case symlink(target: String, targetExists: Bool) // healthy / dangling / shadowed (vs runningBinaryResolved)
    case nonSymlink                                  // a real file/dir -> Install refuses until removed
}
public struct DoctorFacts {
    public struct Agent {
        public var present: Bool; public var hooksParseError: String?  // non-nil -> hooks WARN
        public var dantermHooks: [HookRef]; public var skillInstalled: Bool
        public var skillSearchPaths: [String]   // resolved dirs checked, in order; [0] is the agent's
                                                // own root (honors $CODEX_HOME) -- the missing-skill
                                                // WARN renders its fix path from this
        public init(/* memberwise */) { /* ... */ }
    }
    public struct HookRef {
        public var command: String; public var exists: Bool; public var executable: Bool
        // ^ !exists, or (exists && !executable), -> hook ERROR (a wired hook the agent can't run)
        public init(/* memberwise */) { /* ... */ }
    }
    public var claude: Agent; public var codex: Agent   // claude <- ~/.claude; codex <- $CODEX_HOME
    // ^ skillInstalled is true iff the agent's own root OR the shared
    //   ~/.agents/skills/danterm resolves (following symlinks) to a directory
    //   containing a readable SKILL.md -- the prober checks the union. A bare/empty
    //   danterm/ dir or a broken symlink is NOT installed (it would false-OK otherwise).
    // install
    public var runningBinaryResolved: String?      // realpath(argv0)
    public var pathDanterm: PathCommand?           // first executable `danterm` found on PATH;
                                                   // nil means doctor was invoked by absolute
                                                   // path or PATH lacks a usable command
    public var appInstallerLinkRelevant: Bool      // false for Nix/profile-managed PATH commands
                                                   // (e.g. /etc/profiles/... -> /nix/store/...)
                                                   // so missing /usr/local/bin is not a WARN
    public var bundledHookDir: String?             // <bundleRoot>/Contents/Resources/danterm-hooks from
                                                   // resolveOwnBundleRoot(); nil when argv0 has no .app
                                                   // ancestor. The dangling-hook ERROR repoints to
                                                   // <bundledHookDir>/<name> when set, else the
                                                   // /Applications literal. Carried in the DTO because
                                                   // pure core renders the message but cannot call support.
    public var symlinkEntry: SymlinkEntry           // manual-app /usr/local entry:
                                                   //   .missing / .symlink(target,targetExists) /
                                                   //   .nonSymlink -- evaluator derives dangling
                                                   //   vs non-symlink WARNs from this only when
                                                   //   appInstallerLinkRelevant is true
    public var translocated: Bool
    public var jqOnPath: Bool                       // true iff an executable file named `jq` is on PATH
                                                   // (a non-executable `jq` does NOT count -- the hooks
                                                   // run `command -v jq` / invoke it directly); the
                                                   // hooks-wired gate is derived in the evaluator
    public init(/* memberwise */) { /* ... */ }
}

public struct PathCommand {
    public var path: String                         // raw PATH candidate, e.g. /etc/profiles/.../bin/danterm
    public var resolved: String?                    // realpath(path), used to compare with runningBinaryResolved
    public init(/* memberwise */) { /* ... */ }
}

// in DanTermCore -- the evaluator's output:
enum DoctorStatus { case ok, skip, info, warn, error }
struct DoctorCheck { let id: DoctorCheckID; let title: String
                     let status: DoctorStatus; let message: String? }  // nil iff .ok
```

Prober helpers to add (support): `resolveOwnBundleRoot()` -- `realpath(argv0)` ->
nearest `.app` ancestor -> bundle root -> `Contents/Resources/danterm-hooks`,
stored into `facts.bundledHookDir` so the pure core renders the dangling-hook
repoint path without calling support (nil when argv0 has no `.app` ancestor -> the
ERROR falls back to the `/Applications` literal). The bundle ships the hooks but
NOT the skill, so the missing-skill fix instead points at the Nix
`danterm-agent-skill` output / repo `integrations/danterm` per README, not the
bundle; per-agent
`skillSearchPaths` resolution (the agent's own
`<root>/skills/danterm` honoring `$CODEX_HOME`, then the shared
`~/.agents/skills/danterm`). A skill root counts as installed only when it
(following symlinks) is a directory containing a readable `SKILL.md`; a bare or
empty `danterm/` dir, or a broken symlink, is reported not installed. A hook
entry counts as a DanTerm hook when its `command` contains `/danterm-hooks/` or
basename starts with `danterm-`.

Add `findPathCommand("danterm")` alongside the existing executable PATH scan
helper: it returns the first executable PATH candidate plus its resolved path.
The evaluator treats that as the canonical CLI install health signal. Add
`appInstallerLinkRelevant` as a support-side fact so the pure core does not need
to infer package-manager semantics from path strings: false when the PATH command
or running helper resolves through Nix/profile management (`/nix/store` or
`/etc/profiles`); true for manual app helpers such as
`/Applications/DanTerm.app/Contents/Helpers/danterm` or
`~/Applications/DanTerm Dev.app/Contents/Helpers/danterm`.

## Files

Add:
- `lib/DanTermProtocol/Sources/DanTermProtocol/DoctorFacts.swift` (shared **public** fact DTO; per-agent `skillSearchPaths`)
- `lib/DanTermCore/Sources/DanTermCore/Doctor.swift` (evaluator + renderer + `DoctorCheck`/`DoctorStatus`)
- `lib/DanTermSupport/Sources/DanTermSupport/DoctorProber.swift` (facts gatherer; resolves bundle root + skill paths)
- `lib/DanTermCore/Tests/DanTermCoreTests/DoctorEvaluatorTests.swift`
- `lib/DanTermSupport/Tests/DanTermSupportTests/DoctorProberTests.swift`
- symlinks `cli/DanTermCore`, `cli/DanTermSupport`

Modify:
- `cli/main.swift` -- `doctor` interception + `usageText` line
- `lib/DanTermSupport/Sources/DanTermSupport/CLIPathInstaller.swift` -- internal
  `installDiagnostics()` accessor for reuse
- `scripts/tests/danterm-cli_test.sh` -- pre-app-launch `doctor` smoke (see Tests)
- `integrations/danterm/SKILL.md` -- document the new `doctor` command (per the
  repo rule: CLI surface changes update SKILL.md in the same change)
- `README.md` integration section -- mention `danterm doctor` and explicitly say
  it checks the `danterm` executable found on PATH plus the manual `.app`
  `/usr/local/bin/danterm` installer link only when that link is relevant, so Nix
  installs are not implied to need `/usr/local/bin/danterm`.

Reuse references: symlink + translocation logic (`CLIPathInstaller`; the new
`installDiagnostics()` accessor), bundled hook names (`build-app.sh:73-82`).
Codex `hooks.json` shares Claude's exact JSON hook shape, so one JSON hook walker
serves both.

## Build order (incremental, each step lands with tests)

1. Scaffold: symlinks + `doctor` interception printing an empty report; types in
   `Doctor.swift`; one passing evaluator test. Proves wiring + `just test` gate.
2. Install spine: PATH `danterm` health + manual app-link diagnostic +
   translocation WARN (+ `installDiagnostics()` reuse).
3. Agent integration: Claude (`~/.claude/settings.json`) + Codex (`$CODEX_HOME`
   `hooks.json` + `config.toml`) hooks + skills (each agent's skill checked across
   its own root and the shared `~/.agents/skills`) + the agent severity ladder;
   `jq` gate.
4. Docs (SKILL.md/README).

## Tests (TDD -- spec-first)

Evaluator (pure, core -- fast, no IO; the bulk of coverage). A row per check,
asserting every status that check can reach:
- Claude/Codex hooks: wired+valid -> OK; wired+dangling -> ERROR;
  wired+exists-but-not-executable -> ERROR; `hooksParseError != nil` (malformed
  file) -> WARN naming the source file; present+unwired -> WARN; absent -> INFO.
  (Codex presence keys off `$CODEX_HOME`.) The dangling ERROR renders
  `<bundledHookDir>/<name>` when `bundledHookDir` is set, and falls back to the
  `/Applications/...` literal when it is nil.
- Claude/Codex skill: in the agent's own root -> OK; in only the shared
  `~/.agents/skills/danterm` -> OK (the union case); agent present but skill in
  neither root -> WARN whose fix path is rendered from `skillSearchPaths[0]` (so a
  custom `$CODEX_HOME` yields the right path); agent absent -> SKIP.
- Translocation standalone: `translocated == true` -> one WARN, and it does NOT
  suppress others -- symlink/hooks/skill/jq still produce their normal results
  (e.g. a dangling hook is still ERROR).
- `jq` gate: no hooks wired -> SKIP; hooks wired + `jqOnPath == false` -> WARN;
  hooks wired + `jqOnPath == true` -> OK.
- PATH CLI: `pathDanterm == nil` -> WARN(missing from PATH); `pathDanterm.resolved
  != runningBinaryResolved` -> WARN(PATH points at a different install);
  `pathDanterm.resolved == runningBinaryResolved` -> OK. Include the Nix/profile
  regression: PATH candidate `/etc/profiles/per-user/dan/bin/danterm` resolves to
  the running `/nix/store/.../Applications/DanTerm.app/Contents/Helpers/danterm`,
  `appInstallerLinkRelevant == false`, `/usr/local/bin/danterm` missing -> no
  `/usr/local` WARN.
- Manual app link: when `appInstallerLinkRelevant == true`, `.missing` or a
  dangling `.symlink` (target gone) -> WARN(dangling msg); `.nonSymlink` (a real
  file/dir at the path) -> WARN(non-symlink msg, distinct from dangling: its
  remedy is remove/rename then reinstall, since the Install menu item would throw
  `destinationIsNotSymlink`/`destinationIsDirectory`); a live `.symlink` whose
  target == runningBinaryResolved -> OK. When `appInstallerLinkRelevant == false`,
  the manual-app link row is OK/hidden regardless of `/usr/local/bin/danterm`.
- Exit-code mapping: any ERROR -> report has an error (CLI exits 1); a run with
  only WARN/INFO/SKIP -> exit 0.
- Renderer: OK lines hidden unless `showOK`; SKIP lines carry the why; footer
  counts correct across a mixed result set.

Prober (support -- hermetic temp dirs + injected env, like `RecoveryStoreTests`).
One fixture per nontrivial fact source:
- Hook sources: Claude `settings.json` and Codex `$CODEX_HOME/hooks.json` through
  the shared JSON walker -- valid DanTerm hook (exists/executable), dangling hook,
  present-but-not-executable hook (chmod 0644) -> `exists == true, executable ==
  false`, non-DanTerm hooks ignored, malformed JSON -> `hooksParseError`; plus a
  Codex `config.toml` with an inline `[[hooks.SessionStart]]` danterm `command`
  found by the best-effort scan, and a malformed `config.toml` -> NO
  `hooksParseError` (TOML parse errors are out of v1 scope; only the JSON files set it).
- Skill presence (union) + paths: a `danterm/` dir containing a readable
  `SKILL.md` in the agent's own root only -> `skillInstalled`; in the shared
  `~/.agents/skills/danterm` only -> `skillInstalled`; in neither -> not installed;
  a candidate dir that EXISTS but lacks `SKILL.md` -> not installed (guards the
  empty-dir/broken-symlink false-OK). Exercised for both Claude and Codex, and
  `skillSearchPaths[0]` reflects a custom `$CODEX_HOME` (so the missing-skill fix
  path is right).
- PATH CLI command: injected PATH containing an executable `danterm` -> records raw
  path and resolved path; no executable `danterm` -> nil; Nix/profile fixture
  where `/etc/profiles/per-user/dan/bin/danterm` resolves into `/nix/store/...`
  sets `appInstallerLinkRelevant == false`; manual `.app` fixture where PATH
  `danterm` and `argv0` resolve to
  `/Applications/DanTerm.app/Contents/Helpers/danterm` or
  `~/Applications/DanTerm Dev.app/Contents/Helpers/danterm` sets
  `appInstallerLinkRelevant == true`.
- Manual app link + translocation via injected `installerDeps` (a temp-fixture
  `CLIPathInstaller.Dependencies`, like `makeInstallerFixture`): `destinationURL`
  -> a temp symlink set healthy / dangling / pointing elsewhere -> the matching
  `.symlink(target:targetExists:)` entry; `destinationURL` -> a temp regular file
  (not a symlink) -> `.nonSymlink`; `destinationURL` -> an absent path -> `.missing`;
  `bundleURL` -> a `/AppTranslocation/` path -> `translocated == true`. Never touches
  the real `/usr/local/bin/danterm`.
- `jq` PATH scan: injected PATH with an executable `jq` -> `jqOnPath == true`;
  with no `jq` -> false; with a present-but-non-executable `jq` (chmod 0644) ->
  false (a non-executable `jq` must not read as OK).
- bundle-root resolution from a fake `.app` layout -> `bundledHookDir` ==
  `<bundleRoot>/Contents/Resources/danterm-hooks`; a bare binary with no `.app`
  ancestor -> `bundledHookDir == nil`.

CLI interceptor (`scripts/tests/danterm-cli_test.sh`, pre-app-launch section --
runs against the freshly built helper with the app down, proving the interceptor
never touches the socket):
- `help`/`--help` output now lists `doctor` (guards the `usageText` line).
- `danterm doctor` and `danterm doctor --all` run to completion under a temp
  `HOME` with no app running -- they exit without hanging and without emitting
  `danterm: DanTerm is not running` (i.e. no socket connect).
- `danterm doctor --bogus` fails locally (non-zero, error on stderr), not via the
  socket.

## Verification

- `just test` -- the gate runs protocol XCTest + core Swift Testing + support
  Swift Testing + core-purity lint (pure + portable). The new evaluator must pass
  the pure profile (no IO) and the prober the portable profile.
- `scripts/tests/danterm-cli_test.sh` -- its pre-app-launch section covers the
  interceptor (help lists `doctor`; `doctor`/`doctor --all` run with the app down
  and never hit the socket; a bad flag fails locally). Not part of the headless
  `just test` gate (it needs the dev build + the app-control env gate, like
  `just test-ui`); run it in the CLI smoke harness.
- Build + install dev app (`just build`), then exercise end-to-end from a shell:
  - Healthy: `danterm doctor` -> no ERROR, exit 0 (only INFO/footer).
  - Nix/profile healthy: PATH `danterm` resolves to the running Nix/store helper
    and `/usr/local/bin/danterm` is absent -> no `/usr/local` WARN, exit 0.
  - Break a hook path in `~/.claude/settings.json` (and `~/.codex/hooks.json`) ->
    ERROR with repoint message, exit 1.
  - `chmod -x` a wired hook -> not-executable ERROR, exit 1.
  - `PATH= danterm doctor` with hooks wired -> `jq` WARN; with no hooks -> `jq`
    SKIP.
  - Put an older `danterm` earlier in PATH -> PATH mismatch WARN.
  - For a manual app install, rename the `/usr/local/bin/danterm` symlink target ->
    manual app-link WARN.
  - Replace the link with a regular file (`rm -f /usr/local/bin/danterm && touch
    /usr/local/bin/danterm`) -> non-symlink WARN (remove/rename first; the Install
    menu item refuses a non-symlink), exit 0.
  - `danterm doctor --all` -> OK lines appear.
- Confirm `integrations/danterm/SKILL.md` documents `doctor` (CLI-surface rule).
- Confirm `README.md` describes `doctor` as checking PATH `danterm` first and the
  manual `.app` `/usr/local/bin/danterm` link only when relevant.

## Follow-up checks (out of v1 scope)

These were specified in earlier drafts and are deliberately deferred. Each needs
on-disk or schema facts the v1 integration slice does not gather; none is
specified for implementation here. A v2 would re-add the relevant `DoctorFacts`
fields, prober probes, and evaluator rows behind its own tests.

- **Config validity** -- line-scan `~/.config/danterm/config` for `remote-theme`
  (validated against the bundle's enumerated `ghostty/themes/`) and a positive
  numeric `font-size`; Ghostty's `theme` key stays unchecked (its resolver spans
  `~/.config/ghostty/themes`, absolute paths, and `light:,dark:` pairs, far beyond
  the bundle list). Needs `configContents` + `availableThemeNames` facts and a
  bundle-theme enumerator.
- **Recovery dir writable** -- WARN when the recovery directory can't be written.
  Needs the bundle-id-resolved recovery path + a writability probe.
- **Stale session lock** -- WARN on a leftover `session.json` lock whose pid is
  no longer alive. Needs the lock-file read + a liveness (`kill -0`) probe.
- **Checkpoint schema version current** -- WARN when on-disk recovery files are
  from an older schema than core's `appInitFileVersion`. Needs the on-disk
  light/enriched version facts.
- **`xterm-ghostty` terminfo present** -- INFO when the terminfo entry is absent,
  with the SSH `infocmp | tic` remedy. Needs an `infocmp` subprocess probe (and
  would reintroduce the `runProcess` seam dropped from v1).

## Implementation notes

- `DoctorProbeEnv.live` honors `HOME` from `ProcessInfo.processInfo.environment`
  before falling back to `FileManager.default.homeDirectoryForCurrentUser`, so
  local-only CLI runs and smoke tests probe the same home directory the process
  environment exposes.

## Follow Up

- Add v2 config-validity checks for `~/.config/danterm/config`, including
  `remote-theme` validation against bundled themes and positive numeric
  `font-size` validation.
- Add a v2 recovery-directory writability check using the bundle-id-resolved
  recovery path.
- Add a v2 stale `session.json` lock check that reads the lock file and probes
  pid liveness.
- Add a v2 checkpoint schema-version check for older on-disk recovery files.
- Add a v2 `xterm-ghostty` terminfo check with an `infocmp` subprocess probe and
  SSH `tic` remedy.
