# DanTerm advertises where its shell integration lives

## Context

A zsh pane accumulates prompt debris when its width is dragged. The chain,
measured rather than inferred:

1. zsh's post-SIGWINCH repaint moves the cursor up by the row count the prompt
   had *when it was written*, then erases from there. A width change landing
   mid-write leaves the top prompt row one column too wide, so it soft-wraps
   into two display rows; the erase then starts one row too low and strands the
   head. Each burst strands one more.
2. DanTerm's countermeasure is the OSC 133 `A;redraw=1` grant emitted by the
   bundled integrations and consumed by the resize path. Replaying one captured
   PTY byte-and-resize stream leaves **1** prompt head with the marks present
   and **5** with the marks stripped.
3. The marks were absent because the integration never loaded. The shell decides
   whether to load it by matching `DANTERM_SOCK` against
   `*/com.danneu.danterm-dev/*`. Dev slots use bundle id
   `com.danneu.danterm-dev.N`, so the match fails. Verified live in a slot pane:
   `DANTERM=1`, integration missing. It fails silently because the
   "integration not found" warning sits inside the branch that never ran.

The shell is guessing at a fact only the app holds, from a string the app is
free to change. It did change, and nothing said so.

Desired outcome: whether a pane's shell loads the integration is decided by the
app and communicated, not inferred.

### Load-bearing premises

- Without the marks the debris is not fixable in the emulator. Three terminals
  render it identically (`docs/research/32-post-resize-repaint-loss` `F2`), and
  the terminal cannot know the prompt block's extent unaided. Making the marks
  reliably present is the whole fix.
- Auto-injection would not have fixed this. In Ghostty, kitty and iTerm2 alike,
  injection is one-shot: each restores the variable it hijacked
  (`ZDOTDIR`, `XDG_DATA_DIRS`, `ENV`) before the user's shell starts, so nested
  shells receive nothing. The debris came from a `zsh` typed at a fish prompt.
  All three ship a persistent discovery variable plus a one-line rc hook as
  their documented answer for exactly that case.

## Decision

DanTerm exports an owned child-environment variable naming the running bundle's
own shell-integration directory. Shell hooks source from that variable instead
of reconstructing a path.

This restores a pattern the codebase already had: the retired `__DANTERM_EVT__`
protocol was gated on `DANTERM_TOKEN`, a variable the app set. The current
protocol regressed to path-sniffing.

Behavioral scope: the launch environment, the child-environment contract in
`docs/terminal-capabilities.md`, the home-manager module and README hook
instructions, and one new test bridging bundle to child shell.

## Invariants

- **I1** A pane launched by the Swift engine exposes a variable whose value is a
  directory holding the readable per-shell assets, including the `vendor/`
  sibling `danterm.bash` sources.
- **I2** The variable names the *running* bundle, so a dev build, a dev slot, and
  an installed app each advertise their own copy. No consumer reconstructs an
  install path.
- **I3** A hook keyed on the variable is inert in a shell where neither it nor
  `LC_DANTERM` is set, so the rc line is safe to install unconditionally.
- **I4** The variable is never consumed, unset, or rewritten by the integration
  scripts. It survives into nested and re-exec'd shells, which is what makes a
  shell started from a prompt load the integration.
- **I5** A shell reached over the `LC_DANTERM` remote route, where no local
  bundle exists, still has a supported way to load the assets. Absence of the
  variable is not a failure.
- **I6** When the variable is set but the asset it names is unreadable, the hook
  says so. There is no silent middle state between "app asked for the
  integration" and "integration loaded".

## Proof obligations

- **PO1** (I1, I2) A pane launched through the ordinary launch path exposes the
  variable, and the directory it names holds the readable assets. This is the
  bundle-to-child bridge nothing tests today, and it is the surface this defect
  slipped through. The bundle-derived half must be covered where the bundle is
  actually read -- an app-target test that points the launch path at a synthetic
  bundle location and follows that location into the resolved child environment.
  A test that only injects the directory as a fact proves forwarding, not
  derivation, and would still pass for a build that hardcoded a canonical install
  path and broke every dev slot.
- **PO2** (I4) Sourcing each shipped integration leaves the variable set and
  unchanged. The existing suite already asserts the mirror property for the
  `DANTERM_RESTORE_*` variables, which *are* consumed.
- **PO3** (I3, I5, I6) The hook is inert with the variable unset, loads from the
  variable when set, and reports an unreadable asset. The remote route continues
  to load from packaged assets.
- **PO4** (I1) The advertised directory is the one the build ships. Existing
  bundle-contract coverage carries this once the advertised path is asserted
  against it.

## Non-goals

- Auto-injection via `ZDOTDIR`/`XDG_DATA_DIRS`/`ENV`. See rejected ideas.
- Any change to prompt-debris handling for a shell that emits no marks.
- Any change to the released libghostty app or the retired `__DANTERM_EVT__`
  protocol.

## Accepted risks

- **AR1** A shell that reads no rc file (`zsh -f`, some container entrypoints)
  still loads nothing. No mechanism reaches it; auto-injection would not either.
- **AR2** The variable names the bundle, so editing an asset in the checkout no
  longer reaches the next pane without a rebuild. The previous hook preferred
  the working tree. Preserving that loop is left to build-time packaging.
- **AR3** Another emulator launched from a DanTerm pane inherits the variable, so
  its shells load DanTerm's integration too. This is the same inheritance I4
  requires for nested shells and cannot be separated from it; the assets emit
  standard OSC 133, which a foreign emulator either uses or ignores.

## Rejected ideas

- **RI1** Auto-injecting the integration so no rc hook is needed. It is one-shot
  in every implementation surveyed and so would not have covered the nested
  shell that produced this defect, it takes ownership of three shells' startup
  sequences (bash needs `--posix` plus a hand-rolled re-implementation of bash's
  own startup-file search, and cannot work with Apple's `/bin/bash` at all), and
  it would split the tested artifact from the shipped mechanism: the suite
  sources the assets directly, which stays honest only while sourcing is the
  real path.
- **RI2** A detector that flags panes whose shell never reported. I6 removes the
  silent failure at its source, leaving nothing for a detector to find.

## Critical files

- `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneLaunch.swift` --
  `assembleTerminalPaneLaunch` authors the advertised environment;
  `TerminalPaneLaunchFacts` already carries a bundle-derived value
  (`terminalProgramVersion`) as the precedent for a second one.
- `app/SwiftTerminalBackend.swift` -- `launchFacts` gathers ambient facts and
  today reads only the version from the bundle; deriving the integration
  directory is new behavior here. The initializer already derives a bundle path
  (the bootstrap helper) from an injectable `Bundle`, which is the existing
  precedent and the natural seam for PO1's synthetic-bundle test.
- `docs/terminal-capabilities.md` -- the "Child environment" table is the public
  ownership contract.
- `hm-module.nix`, `README.md` -- the two places that tell a shell where the
  assets are. Both currently hardcode a path; `hm-module.nix` deliberately works
  without the app installed, which is what I5 protects.
- `scripts/tests/shell-integration_test.sh` -- sources the assets directly and
  is where the shell-level obligations belong.

This is the change that makes `Contents/Resources/shell-integration` a runtime
path. `plans/impl/2026-08-01-1955-ship-shell-integration-nix-package-and-bundle.md`
recorded it as "a documentation-only path that the user's rc file sources", and
that is precisely the assumption this plan retires.

## Verification

- `just test` -- carries the shell-integration and dev-build bundle contracts.
- Targeted: `swift test --package-path lib/TerminalPTY` for the launch
  environment, plus the app-target suite for the bundle-derived half of PO1.
- End to end, which is the check that would have caught the defect: launch a dev
  slot (`just launch`), and in a pane confirm the variable is set, that a nested
  shell started from that prompt also sees it, and that the prompt carries the
  OSC 133 mark. `danterm pane read` on a pane whose width has been dragged shows
  whether debris landed in the grid -- that read is how the original defect was
  confirmed and is the honest end-to-end signal.

## Implementation discretion

- Where the variable's name is declared, and what seam lets a test aim the launch
  path at a synthetic bundle location.
- Whether dev packaging links the bundle directory to the checkout to preserve
  the loop named in AR2.

## Implementation notes

- The owned variable is named `DANTERM_SHELL_INTEGRATION_DIR` so its directory
  value is explicit at both the Swift launch seam and shell-hook call sites.
