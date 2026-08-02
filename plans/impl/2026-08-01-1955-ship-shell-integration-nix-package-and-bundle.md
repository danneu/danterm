# Ship the shell integration as a Nix package and a working bundle asset

## Context

DanTerm's canonical shell assets live in `integrations/shell-integration/`
(`danterm.{zsh,bash,fish}` plus `vendor/bash-preexec.sh` and its license and
provenance files). Every other integration in this repo is reachable two ways --
a Nix attribute and a path inside the `.app` bundle -- and the README documents
both for each. Shell integration has neither working properly:

- **No Nix output.** `overlays.default` packages the three agent hooks and
  `danterm-agent-skill`, but not the shell assets. `checks.<system>.shell-integration`
  copies `./integrations/shell-integration` straight from the source tree, so
  nothing is exported for a consumer to reference. A remote Linux host receiving
  `LC_DANTERM=1` over ssh has no way to obtain the assets at all -- there is no
  app bundle there, and that is the only supported route today.
- **The bundle asset is broken for bash.** `build-app.sh` and `dev-build.sh`
  copy only the three `danterm.$shell` files, not `vendor/`. `danterm.bash`
  resolves `vendor/bash-preexec.sh` relative to its own `BASH_SOURCE`, so the
  bundle path the README tells bash users to source (`README.md`, `## Shell
  Integration`) fails on the `source` line. Nothing catches it: the dev-build
  contract test and both CI workflows check only the three top-level files.
- **The Linux check has never passed.** `checks` is declared over `hookSystems`
  (which includes `x86_64-linux`), but `scripts/tests/shell-integration_test.sh`
  hardcodes `/bin/bash` and `/usr/bin/expect`, neither of which exists in a Linux
  Nix build sandbox.

Outcome: a consumer can source the assets from `pkgs.danterm-shell-integration`,
from a home-manager option, or from the `.app` bundle, and all three carry the
`vendor/` sibling that makes bash work.

## Decision

- `overlays.default` gains a shell-integration derivation that installs the
  `integrations/shell-integration` directory wholesale, so `vendor/` stays a
  sibling of `danterm.bash`. Its public path is
  `$out/share/danterm-shell-integration/`.
- `packages.<system>.shell-integration` exposes it on both `hookSystems`
  (`aarch64-darwin`, `x86_64-linux`). Linux availability is the point, not a
  side effect: it is the only way a remote host can get the assets.
- `checks.<system>.shell-integration` runs the existing test script against the
  **package output** rather than the source tree. The script takes the directory
  under test from the environment, defaulting to the repo path so the local
  `just test` run is unchanged. This is what makes the packaged layout -- not
  just the source layout -- a tested claim.
- **The check becomes hermetic.** No command the test invokes may depend on an
  absolute path outside the Nix store, since a Linux build sandbox provides only
  `/bin/sh`. That covers `/usr/bin/env` (the shell launcher on ~20 of the test's
  call sites), `/bin/bash`, and `/usr/bin/expect`; each resolves through `PATH`
  from `nativeBuildInputs` instead.
- **The shipped restore helpers stop hardcoding `/bin/cat` and `/bin/rm`.** All
  three assets use those absolute paths to replay and delete the scrollback file.
  This is not only a sandbox problem: NixOS hosts have no `/bin/cat` or `/bin/rm`
  either, so on the remote Linux host this plan exists to serve, restore silently
  replays nothing and leaks the temp file. The absolute paths were buying
  resistance to a `PATH` hijack at rc-source time; the replacement must state how
  it keeps that property or why it does not need it.
- `build-app.sh` and `dev-build.sh` ship the whole
  `integrations/shell-integration` tree into `Contents/Resources/shell-integration`
  and fail the build if any asset is missing afterwards -- matching the `test -x`
  guard the `danterm-hooks` loop already has.
- `hm-module.nix` gains `programs.danterm.shellIntegration`, with its own enable
  flag and `package` option. Its wiring is gated on that flag alone, **not** on
  `programs.danterm.enable`, so a non-Darwin host can import the module for shell
  integration without evaluating the macOS app package.
- **Enable contract.** `shellIntegration.enable` defaults to `false`. When true,
  each of bash/zsh/fish is wired if and only if that shell's own
  `programs.<shell>.enable` is true -- one flag for the user, no config written
  into a shell they do not use. There are no per-shell DanTerm flags.
- **The GUI package default is emitted only on `appSystems`.**
  `homeManagerModules.default` currently sets `programs.danterm.package` to
  `self.packages.${system}.default` unconditionally, and `default` exists only for
  `aarch64-darwin`; forcing that option on `x86_64-linux` fails with
  `attribute 'default' missing`. The shell-integration package default stays
  available on every hook system.
- **The Linux obligations get a real route.** Home Manager becomes a pinned flake
  input following this flake's nixpkgs, and the existing `ubuntu-latest` +
  `nix-installer-action` CI job (`.github/workflows/ci.yml`) gains a step that
  builds the Linux shell-integration check and evaluates a real Home Manager
  configuration with only `shellIntegration` enabled. A stubbed `lib.evalModules`
  harness is explicitly not sufficient: it would not exercise the actual HM shell
  options the wiring writes to.
- The README documents the Nix route for shell integration in the same
  `### With Nix` / `### Without Nix` shape the `## Agent Skill` section already
  uses, and covers getting the assets onto a remote host.

## Invariants

- `danterm.bash` sourced from any shipped location -- Nix store path or `.app`
  bundle -- resolves `vendor/bash-preexec.sh` successfully.
- The three sourced entry points behave identically whichever location they come
  from; the package is a copy of the source tree, not a rewritten variant.
- The home-manager module evaluates on a non-Darwin system when only
  `shellIntegration` is enabled, including when every option value is forced.
  No macOS-only package is referenced on a system that does not have one.
- A consumer pinned to a given DanTerm revision gets shell assets matching that
  revision from every route.
- Scrollback restore -- replaying the file and then removing it -- works on a
  host whose only absolute-path binary is `/bin/sh`.

## Proof obligations

- The flake check exercises the packaged output on each of `hookSystems`,
  including a bash case that depends on the `vendor/` sibling resolving. It must
  actually run on `x86_64-linux`, not merely be declared there. Passing there is
  itself the hermeticity proof: the sandbox has no `/usr/bin/env`, `/bin/bash`,
  `/usr/bin/expect`, `/bin/cat`, or `/bin/rm`, so any surviving absolute path
  fails the check.
- The check's existing restore case -- which asserts the scrollback content is
  replayed and the file is gone afterwards -- covers the `/bin/cat` and `/bin/rm`
  removal for all three shells once it runs on Linux. No new test is needed for
  it; the obligation is that the existing one reaches Linux.
- The dev-build contract test
  (`scripts/tests/dev-build-configuration-contract_test.sh`) proves the bundle
  preserves `vendor/bash-preexec.sh` alongside the three shell files -- extending
  the per-shell `cmp` loop it already has.
- Both release-bundle verifications (`.github/workflows/ci.yml`,
  `.github/workflows/release-stable.yml`) check the vendor asset pre-sign and
  after the ZIP round trip, alongside the `danterm.$shell` checks they already do.
- A CI-gated Home Manager evaluation on `x86_64-linux`, against the pinned
  Home Manager input and with option values forced, proves the module evaluates
  with only `shellIntegration` enabled and never reaches a macOS-only package.
  This is the invariant most likely to regress silently, since nothing else in
  the module is cross-platform. The same evaluation asserts the enable contract:
  a shell whose `programs.<shell>.enable` is false receives no DanTerm wiring,
  and one whose flag is true does.

## Files

| File | Change |
|---|---|
| `flake.nix` | shell-integration derivation in `overlays.default`; `shell-integration` in the `hookSystems` packages attrset; repoint `checks.<system>.shell-integration` at the package output and make it hermetic; pin the Home Manager input |
| `flake.nix` (`homeManagerModules.default`) | default `shellIntegration.package` to the shell-integration package on every hook system; emit the `programs.danterm.package` default only on `appSystems` |
| `scripts/tests/shell-integration_test.sh` | take the integration directory from the environment, defaulting to the repo path; resolve every invoked command through `PATH` (`/usr/bin/env`, `/bin/bash`, `/usr/bin/expect`) |
| `integrations/shell-integration/danterm.{bash,zsh,fish}` | drop the hardcoded `/bin/cat` and `/bin/rm` from the scrollback-restore block |
| `build-app.sh`, `dev-build.sh` | ship the whole integration tree into the bundle and fail if an asset is missing |
| `hm-module.nix` | `programs.danterm.shellIntegration` options and their shell wiring, gating independently of `programs.danterm.enable` |
| `scripts/tests/dev-build-configuration-contract_test.sh` | assert the bundled `vendor/` files |
| `.github/workflows/ci.yml` | add the vendor asset to the bundle verification loops; add the Linux check build + Home Manager evaluation to the existing Nix-enabled `ubuntu-latest` job |
| `.github/workflows/release-stable.yml` | add the vendor asset to the bundle verification loops |
| `README.md` | `### With Nix` / `### Without Nix` under `## Shell Integration`; remote-host guidance |

No Swift changes. Nothing in `app/` or `lib/` reads
`Contents/Resources/shell-integration` -- it is a documentation-only path that
the user's rc file sources.

## Verification

```sh
nix build .#shell-integration
ls result/share/danterm-shell-integration/vendor/bash-preexec.sh

nix flake check                       # darwin check, now against the package
nix build .#checks.x86_64-linux.shell-integration   # needs the linux builder; CI runs it

bash scripts/tests/shell-integration_test.sh        # unchanged local path

just test                              # includes the dev-build contract test
just build && ls "$HOME/Applications/DanTerm Dev.app/Contents/Resources/shell-integration/vendor"
```

End-to-end, the case that is broken today:

```sh
bash --noprofile --norc -c \
  'source "$HOME/Applications/DanTerm Dev.app/Contents/Resources/shell-integration/danterm.bash"; \
   type danterm_emit_cwd'
```

## Non-goals

- Landing this on `master`. The assets exist only on
  `experiment/swift-terminal-engine`; sequencing the master landing is a separate
  decision and does not change the shape of this work.
- Teaching the app to export its own asset directory to child shells. That would
  remove the hardcoded bundle path from consumer configs, but it is an
  independent change and this one does not depend on it.
- Changing dispatch logic in `~/world`, or the wire protocol.
- Removing the `.app` bundle copy in favor of the Nix package. Both routes stay;
  non-Nix users have only the bundle.

## Implementation discretion

Free choices, as long as the public package path, the shipped directory layout,
the enable contract, independent Home Manager gating, and hermetic execution
hold: the derivation constructor and where it sits in the overlay; how the
bundle copy is expressed and how the two build scripts share (or don't share)
that block; the environment variable name the test script reads and how its
`/bin/bash` and `/usr/bin/expect` call sites are rewritten; the option names
under `shellIntegration`; the module structure used to gate the two config
blocks apart; and the mechanism the restore helpers use to reach `cat`/`rm`
(bare `PATH` lookup, a resolved-once absolute path, or a builtin-only rewrite),
provided it satisfies the restore invariant and the stated `PATH`-safety
position.

## Commit progress

- [x] 1. Make the shell assets and their test hermetic
- [x] 2. Package shell integration with Nix and check the packaged output
- [ ] 3. Add the `programs.danterm.shellIntegration` home-manager module
- [ ] 4. Ship the whole shell-integration tree into the app bundle
- [ ] 5. Document the Nix and bundle routes in the README

## Implementation notes

- **Restore mechanism: `command cat` / `command rm`** (bare `PATH` lookup through
  the `command` builtin), not a resolved-once absolute path. The `PATH`-safety
  position, stated inline in all three assets: `command` still bypasses a
  shadowing function or alias, and anyone able to prepend to the `PATH` of the
  shell sourcing the file already has arbitrary code execution in that shell the
  moment any command runs -- so the absolute paths only ever bought ordering, not
  a security boundary. `rm` has no builtin in bash or fish, so a builtin-only
  rewrite was not available uniformly.
- **The test script's directory input is `DANTERM_INTEGRATION_DIR`**, defaulting
  to the repo path so the local `just test` run is unchanged.
- **`expect` was added to the darwin check's `nativeBuildInputs` in commit 1**,
  ahead of the commit-2 flake work. Rewriting `/usr/bin/expect` to a `PATH`
  lookup breaks `checks.aarch64-darwin.shell-integration` immediately (verified:
  `expect: command not found`), and commit 1 has to leave the repo green.

- **The Linux check step landed in the `cliff-smoke` job** (commit 2). That is
  the only existing `ubuntu-latest` + `nix-installer-action` job in
  `ci.yml`, which is what the plan named; the job's name now undersells what it
  runs. Commit 3's Home Manager evaluation goes in the same place.
- **Overlay attribute is `danterm-shell-integration`, flake output is
  `packages.<system>.shell-integration`** -- matching the existing
  `danterm-agent-skill` / `danterm-claude-*` split between namespaced overlay
  names and bare package names.

## Follow Up

- The `claude-lint-shell` pre-edit hook blocks on pre-existing info-level
  shellcheck findings (SC2016, SC1003, SC1091) in
  `integrations/shell-integration/danterm.bash` and
  `scripts/tests/shell-integration_test.sh`. They are all deliberate --
  single-quoted snippets passed to `-c`, and `\033\\` escapes -- and fire on
  every edit to those files regardless of the change. Worth either a
  `# shellcheck disable=` directive at the top of each file or a severity
  threshold on the hook.
