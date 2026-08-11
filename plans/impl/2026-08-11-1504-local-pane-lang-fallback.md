# DanTerm: inject a `LANG` fallback for locally-spawned panes

> Target repo is `~/Code/danterm`, not `guild`. This session's plan file is
> pinned here by the harness; move it to `~/Code/danterm/plans/wip/` before
> implementing.

## Problem

macOS GUI apps launch with no locale environment variables. A terminal that
spawns a shell without filling that hole leaves the child at `LANG=C`, which
breaks UTF-8 in non-interactive contexts -- scripts, and CLI agents like Claude
Code and Codex -- producing mojibake and byte-vs-character bugs that are hard to
trace back to their cause.

Terminal.app ("Set locale environment variables on startup"), iTerm2 ("Set
locale variables automatically"), and Ghostty all do this, all default-on.
DanTerm does not: `assembleTerminalPaneLaunch` advertises `TERM`, `COLORTERM`,
`TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, and `DANTERM_SHELL_INTEGRATION_DIR`
(`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneLaunch.swift:105-116`)
and nothing else. Verified: no `LANG`, `LC_*`, `setlocale`, or `Locale.current`
appears anywhere in shipping sources -- only test harnesses and shell scripts.

The hole was invisible on this machine because `~/world` (home-manager)
force-sets `LANG` and `LC_CTYPE` for the user. Its comment claiming the
`LC_CTYPE` line exists to override "the bare `LC_CTYPE=UTF-8` that
DanTerm/libghostty injects" is stale in both halves: libghostty is gone, and the
Swift engine injects nothing.

## Decision

DanTerm provides a *fallback* for the PTYs it spawns, in the same contract it
already owns for `TERM` and `COLORTERM`. It is not the authoritative environment
for the user -- that stays with their own config, which must cover SSH, launchd,
and other emulators regardless.

The layering only works if DanTerm's contribution yields cleanly. Injecting a
specific `LC_CTYPE`, as libghostty did, stomps a user's `LANG` and forces an
equally specific counter-override; that is the mess the stale nix comment was
documenting, and it is not recreated here.

- Resolve the locale at the app's IO boundary
  (`SwiftTerminalBackend.launchFacts`, alongside `accountShell` and
  `homeDirectory`) and pass it into `TerminalPaneLaunchFacts` as an optional
  string. `assembleTerminalPaneLaunch` stays pure and documented "without IO".
- Build the candidate from `Locale.current`'s language and region *components*,
  not its identifier string, so modern ICU cruft (`@rg=`, `@calendar=`) never
  needs stripping. Append `.UTF-8`.
- Validate the candidate against this machine before advertising it; macOS ships
  a limited set and advertising an unsupported string is worse than advertising
  nothing. Validate with an isolated locale object (`newlocale` / `freelocale`,
  via `import xlocale`), never `setlocale` -- the process-global locale is shared
  mutable state and a save/restore dance around it is a race, not a probe.
- Gate the config knob by collapsing it into the optional: when the knob is off,
  the boundary resolves to nothing and the assembler has one branch, not two.
  The knob is a new `shell.localeFallback` boolean, default on, config-file only
  (no Preferences checkbox); it needs a new value threaded from `AppRuntime`
  through `TerminalSessionRequest` into `launchFacts`, since config does not
  currently reach the launch boundary at all.
- Source the knob once, at `AppRuntime.makeTerminalSession` -- the single funnel
  that builds the only `TerminalSessionRequest` -- by reading `model.config`
  there, not by adding a parameter its two callers (fresh pane, restore) each
  pass. The setting is app-wide, unlike the per-pane `themeName`/`fontSize` those
  callers compute, so a per-caller parameter would manufacture exactly the
  fresh-vs-restore divergence that would otherwise need a test to catch. The
  value still reaches the backend explicitly on the request; only its source
  moves to the funnel.

## Invariants

- **I1** DanTerm advertises `LANG` and only `LANG`. It never advertises
  `LC_CTYPE` or `LC_ALL` -- a fallback at the least-specific level yields to
  whatever the user's shell rc exports later.
- **I2** `LANG` is advertised only when the inherited environment carries no
  non-empty `LC_ALL`, `LC_CTYPE`, or `LANG`. Any one present is an opinion;
  set-but-empty is a hole, not an opinion.
- **I3** The advertised value is a locale this machine accepts for `LC_CTYPE`.
  If neither the region-derived candidate nor the `en_US.UTF-8` fallback is
  accepted, nothing is advertised.
- **I4** Probing never mutates process-global locale state. The probe reads
  through a locale object it owns and frees; the app process's locale is not
  written, not even transiently.
- **I5** With the knob off, DanTerm advertises no locale variable.

## Proof obligations

- **PO1** (I1, I2) Drive `assembleTerminalPaneLaunch` directly across an
  inherited environment with each of `LANG` / `LC_CTYPE` / `LC_ALL` set, each
  set-but-empty, and none set: a `LANG` entry appears exactly in the empty and
  none-set cases, and no `LC_CTYPE` or `LC_ALL` entry appears in any case.
  (`lib/TerminalPTY/Tests/TerminalPaneSessionTests/TerminalPaneSessionPolicyTests.swift`,
  Swift Testing. Its existing exact-equality assertion on the advertised array
  must be updated in lockstep.)
- **PO2** (I5) `launchFacts` given the knob off resolves no locale, so the
  assembled launch advertises no `LANG`, and given it on resolves one.
  (`app-tests/SwiftTerminalBackendLaunchTests.swift`, which already drives
  `launchFacts` through `assembleTerminalPaneLaunch` and `resolveLaunchPlan` to a
  child environment.) The step from decoded config to that argument is left to
  the single-funnel structure above rather than a runtime test: with one
  construction site reading `model.config`, there is no second path to diverge
  from. PO4 covers decoding; real-app verification covers the join.
- **PO3** (I3, I4) Locale selection is tested through a seam that controls which
  candidates the machine accepts, covering all three branches deterministically:
  regional candidate accepted; regional rejected and `en_US.UTF-8` accepted
  (AR1); both rejected, so nothing is advertised. A test that only exercises this
  machine's valid current locale does not discharge this. Separately, the real
  acceptance check is proven not to write process-global locale state.
- **PO4** Config: `shell.localeFallback` decodes `false`, and defaults to on when
  the key is absent (mirroring the existing `copyOnSelect` document tests).

## Non-goals

- Preferences-panel UI for the knob.
- Setting `LC_ALL`, `LC_CTYPE`, or any other `LC_*` category.
- Changing which variables the shell integration forwards over SSH.
- Making the knob take effect on already-running panes; environment is fixed at
  spawn, so it applies to newly created panes only.

## Accepted risks

- **AR1** A user whose region has no macOS locale silently gets `en_US.UTF-8`
  rather than a regional one. Advertising a working UTF-8 locale beats
  advertising a broken regional one.
- **AR2** When DanTerm is launched from a shell (dev runs), the inherited `LANG`
  suppresses injection, so the feature is exercised only in GUI launches. This
  is correct behavior but makes manual verification easy to get wrong -- see
  Verification.
- **AR3** OpenSSH may forward the injected `LANG` to a remote host, which can
  produce the classic `setlocale: LC_CTYPE: cannot change locale` login warning
  on a host that lacks the locale. macOS `/etc/ssh/ssh_config` ships
  `SendEnv LANG LC_*`, and the shell integration's `-o SendEnv=LC_DANTERM` adds
  to that list rather than replacing it, so the fallback is forwarded whenever
  the user's effective SSH configuration says to forward it. That configuration
  is the user's to set; DanTerm does not silently override it, and every terminal
  that injects a locale has the same exposure.

## Rejected ideas

- **RI1** Injecting `LC_CTYPE` (what libghostty did). It is more specific than
  `LANG`, so it overrides a user's shell-rc `LANG` and forces them to fight back
  with their own `LC_CTYPE` -- the exact failure this plan exists to avoid.

## Implementation discretion

- Whether the resolved locale is computed per pane launch or cached once.

## Critical files

- `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneLaunch.swift` --
  `TerminalPaneLaunchFacts` gains the optional locale; the assembler gains the
  conditional entry.
- `app/SwiftTerminalBackend.swift` -- `launchFacts` resolves and probes;
  `createSession` passes the knob through.
- `app/TerminalSession.swift`, `app/AppRuntime.swift` -- `makeTerminalSession`
  reads `model.config` and puts the value on `TerminalSessionRequest`. This keeps
  the existing pattern that the backend never reads `self.model`: the value
  reaches it explicitly on the request, as `themeName`/`fontSize` do.
- `lib/DanTermCore/Sources/DanTermCore/DanTermConfig.swift` and
  `DanTermConfigDocument.swift` -- the `shell.localeFallback` knob, mirroring
  `ui.copyOnSelect` end to end.
- `README.md` -- document the knob in the config sample.

## Verification

**Manual steps must not observe through this machine's shell rc.** `~/.zshenv`
sources home-manager's `hm-session-vars.sh`, which exports `LANG` and `LC_CTYPE`
unconditionally, and fish's `conf.d` does the same. So a bare `printenv LANG` in
a pane reports `en_US.UTF-8` whether injection works or not, and reports
non-empty with the knob *off* -- it fails the correct implementation and passes
the broken one. Read the environment DanTerm handed the child, before rc files
run: start the pane's shell with rc loading disabled (`zsh -f`,
`fish --no-config`) or point `ZDOTDIR` at an empty directory.

1. `swift build` / the repo's usual `check` path, plus the Swift Testing targets
   covering `TerminalPaneSessionTests`, `DanTermCoreTests`, and the app tests.
2. Launch the built `.app` from Finder or `open`, **not** from a shell (AR2).
   With rc loading suppressed as above, expect `LANG=en_US.UTF-8` and `locale`
   emitting no `setlocale` warnings.
3. Repeat with `shell.localeFallback: false` in `~/.config/danterm/config.json`:
   `LANG` is absent. Run this on both a fresh pane and a restored session, since
   this is the join PO2 deliberately leaves to manual check.
4. Repeat with the knob on and `export LANG=C` in the shell rc -- rc loading
   enabled for this step, since the rc is the thing under test: the rc value
   wins.

## Implementation notes

- `SwiftTerminalBackend.launchFacts` accepts an explicit process environment,
  defaulting to the live process environment, so app tests can model a GUI
  launch with no inherited locale variables.

## Follow Up

Once shipped, delete the `LC_CTYPE` line and rewrite the stale comment in
`~/world/hosts/macbook/modules/system.nix:9-19`, keeping `LANG`.
