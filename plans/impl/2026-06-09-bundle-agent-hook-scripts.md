# Bundle agent-hook scripts into DanTerm.app + fix install docs

## Context

The README's "Without Nix" install instructions for the Claude Code / Codex
hooks tell users to point a hook `command` at
`/absolute/path/to/danterm-claude-notify-osc777` (and `-claude-agent-session`,
`-codex-agent-session`). Those basenames are **Nix package names**
(`flake.nix:44-60`), not files that exist on a normal machine. The actual source
files are named differently (`claude-notify-osc777.sh`,
`danterm-agent-session.sh` x2), so a non-Nix reader following the JSON literally
is pointed at a file that does not exist, and the README otherwise just says
"copy the `.sh` somewhere" with no canonical location.

Today the app bundles only the `danterm` CLI binary
(`Contents/Helpers/danterm`, symlinked to `/usr/local/bin/danterm` by
`CLIPathInstaller`). The hook scripts are not bundled, so there is no stable
in-app path to point at.

**Outcome:** bundle the three hook scripts into
`Contents/Resources/danterm-hooks/` under their Nix basenames, so every install
gets a stable, real, copy-paste hook path
(`/Applications/DanTerm.app/Contents/Resources/danterm-hooks/danterm-claude-notify-osc777`,
etc.). Validation is primarily a CI ZIP-round-trip signature check plus local
tests; the user cuts the real patch release as the final confirmation.

## Design decisions (settled)

- **Bundle under `Contents/Resources/danterm-hooks/`, NOT `Contents/Helpers/`.**
  An executable, non-Mach-O file placed in a nested-*code* location like
  `Contents/Helpers/` is treated by codesign as nested code that needs its own
  signature. A shell script cannot carry a durable embedded (Mach-O-style)
  signature, so codesign falls back to storing it in an extended attribute --
  which an in-place `codesign --verify` accepts, but a `zip`/`unzip` round-trip
  strips, after which strict verify fails with `code object is not signed at
  all`. That is fatal here: `release-stable.yml:110` publishes a
  ZIP, `:134` notarizes it, `:150-167` uploads it, and `package.nix:13-16`
  (`fetchzip`, `dontFixup = true`) installs that ZIP relying on an intact
  signature. Files under `Contents/Resources/` are sealed as plain resources
  (content-hashed in `_CodeSignature/CodeResources`, the same treatment as the
  already-shipped `Assets.car` and ghostty themes) and survive the ZIP
  round-trip. The compiled `danterm` CLI stays in `Contents/Helpers/` untouched
  -- it is Mach-O and carries its own signature (`release-stable.yml:92-93`).

- **Bundle under the Nix basenames, extension stripped** -- mirrors the CLI
  precedent (`DanTermCLI` -> `danterm`, no extension) and unifies naming across
  Nix / non-Nix / source installs. The two same-named source files
  (`danterm-agent-session.sh` in `claude-code/` and `codex/`) map to distinct
  destinations, so there is no collision.

  | Source file | Bundled as |
  |---|---|
  | `integrations/claude-code/claude-notify-osc777.sh` | `Contents/Resources/danterm-hooks/danterm-claude-notify-osc777` |
  | `integrations/claude-code/danterm-agent-session.sh` | `Contents/Resources/danterm-hooks/danterm-claude-agent-session` |
  | `integrations/codex/danterm-agent-session.sh` | `Contents/Resources/danterm-hooks/danterm-codex-agent-session` |

- **The bundled file is the raw `.sh`**, not the Nix `writeShellApplication`
  wrapper. It therefore does **not** bake in `jq` on PATH (and has no
  `set -euo pipefail`). The README must keep the existing "`jq` on PATH" (and
  "`danterm` on PATH" for the session hooks) requirement and must not imply
  byte-identity with the Nix path. Bundling only fixes *where the file lives*;
  the PATH requirement is unchanged from today's copy-it-yourself flow.

- **Mirror the copy in both `build-app.sh` (release) and `dev-build.sh` (dev)**;
  they assemble bundles independently. Accept the small duplication -- do not
  refactor shared assembly (out of scope).

- **Recommend the in-app path as the default non-Nix command**; keep
  "copy the `.sh` yourself" as a one-line fallback for source/dev users.

## Changes

### 1. `build-app.sh` -- bundle + self-check (the load-bearing edit)

Shared assembler, called by both `ci.yml` and `release-stable.yml`, so the
copy + assertion here covers every signed/notarized build. Place the block in
the Resources assembly area, after the `Assets.car` copy (line 65), so it sits
with the other resource content it is sealed alongside:

```bash
# Bundle the agent hook scripts as plain resources so users can point Claude Code
# / Codex hooks at a stable in-bundle path (see README "Claude Code Integration").
# MUST live under Contents/Resources/ (not Helpers): an executable non-Mach-O file
# in a nested-code location loses its seal across the published ZIP round-trip
# (codesign: "code object is not signed at all"); Resources files are content-
# sealed in CodeResources and survive. Basenames match the Nix packages (flake.nix)
# so docs are uniform across install methods. These are the raw .sh files: they
# still need jq (and danterm, for the session hooks) on PATH at hook-exec time.
mkdir -p "$APP_PATH/Contents/Resources/danterm-hooks"
for pair in \
  "integrations/claude-code/claude-notify-osc777.sh danterm-claude-notify-osc777" \
  "integrations/claude-code/danterm-agent-session.sh danterm-claude-agent-session" \
  "integrations/codex/danterm-agent-session.sh danterm-codex-agent-session"; do
    set -- $pair
    cp "$SCRIPT_DIR/$1" "$APP_PATH/Contents/Resources/danterm-hooks/$2"
    chmod +x "$APP_PATH/Contents/Resources/danterm-hooks/$2"   # normalize exec bit (independent of source checkout mode/umask)
    test -x "$APP_PATH/Contents/Resources/danterm-hooks/$2" || { echo "Error: hook script $2 not bundled" >&2; exit 1; }
done
```

`chmod +x` normalizes executability regardless of the source checkout's file
mode or umask (hook `command`s execute the file directly). The `test -x` makes a
silent copy failure a hard build error, matching the file's existing
defense-in-depth style.

### 2. `dev-build.sh` -- mirror the copy

After the dev Resources assembly (the `mkdir -p .../Contents/Resources` +
`Assets.car` copy, ~lines 35-36), add the same `mkdir -p
.../Contents/Resources/danterm-hooks` + copy loop, so `just build` produces a
dev bundle (`~/Applications/DanTerm Dev.app`) usable for local hook testing
before any release.

### 3. `release-stable.yml` -- verify layout + ZIP round-trip signature

a. In "Verify release bundle layout" (lines 56-64), after the
   `test -x "$APP_PATH/Contents/Helpers/danterm"` line, assert the three hook
   scripts are present + executable:

   ```bash
   for h in danterm-claude-notify-osc777 danterm-claude-agent-session danterm-codex-agent-session; do
     test -x "$APP_PATH/Contents/Resources/danterm-hooks/$h"
   done
   ```

b. **New step after "Create ZIP" (after line 110): "Verify ZIP round-trip
   signature."** This is the regression guard that would have caught the
   Helpers-placement bug -- it proves the *published* artifact still verifies:

   ```bash
   WORK="$RUNNER_TEMP/ziptest"; rm -rf "$WORK"; mkdir -p "$WORK"
   unzip -q "build/${{ env.ZIP_NAME }}" -d "$WORK"
   codesign --verify --deep --strict --verbose=2 "$WORK/${{ env.APP_NAME }}.app"
   for h in danterm-claude-notify-osc777 danterm-claude-agent-session danterm-codex-agent-session; do
     test -x "$WORK/${{ env.APP_NAME }}.app/Contents/Resources/danterm-hooks/$h"
   done
   ```

No change to the codesign steps themselves: `codesign --force --deep --options
runtime` (line 94) seals the Resources scripts as content-hashed resources, and
DMG creation (`cp -R` of the whole `.app`, line 102) includes them
automatically.

### 4. `ci.yml` -- mirror both checks on PRs

The PR-side release-build job runs `./build-app.sh`, verifies the bundle
(`~lines 161-166`), then ad-hoc signs (`codesign --force --deep --sign -`,
`:172`) and `codesign -v` (`:173`). Ad-hoc signing reproduces the same seal
shape, so add: (a) the three-hook `test -x` to its verify block; (b) a ZIP
round-trip check after the ad-hoc sign -- `zip -r` the signed app, `unzip` to a
temp dir, `codesign --verify --deep --strict` the unzipped copy, and assert the
three hook paths are executable. This gates the regression on every PR without a
real cert or a release.

### 5. `README.md` -- rewrite the three hook sections

For each hook, replace the `/absolute/path/to/<nix-name>` placeholder with the
real in-app path and reframe the prose so the in-app path is the default non-Nix
command. Keep the `${pkgs...}` "With Nix" forms (lines 140, 213, 249) unchanged.
The documented path base is
`/Applications/DanTerm.app/Contents/Resources/danterm-hooks/`.

- **Notify hook** -- all four JSON `command` fields (lines 155, 167, 178, 189)
  become `.../Contents/Resources/danterm-hooks/danterm-claude-notify-osc777`
  (one binary serves all four events). Rewrite the "Without Nix, copy ..."
  paragraph (199-202) to: the script ships inside the app at that path once
  DanTerm is in `/Applications`; ensure `jq` is on the PATH Claude Code uses for
  hooks; (fallback) or copy
  `integrations/claude-code/claude-notify-osc777.sh` somewhere and point at that.
- **Claude session-recovery hook** -- JSON `command` (line 228) becomes
  `.../Contents/Resources/danterm-hooks/danterm-claude-agent-session`; rewrite
  the Without-Nix paragraph (238-241), keeping the "`jq` and `danterm` on PATH"
  note.
- **Codex session-recovery hook** -- JSON `command` (line 264) becomes
  `.../Contents/Resources/danterm-hooks/danterm-codex-agent-session`; rewrite
  the Without-Nix paragraph (274-277), keeping the "`jq` and `danterm` on PATH"
  note.

Add a short note (once, near the notify section) that the path requires DanTerm
in `/Applications` -- the same prerequisite already documented for the
`danterm` CLI install (`CLIPathInstaller` rejects a translocated bundle).

### 6. `docs/ci.md` -- document the placement rule

Add a short subsection (near "Nested helper signing", ~lines 46-50): the bundled
agent hook scripts live in `Contents/Resources/danterm-hooks/` (not
`Contents/Helpers/`) precisely because executable non-Mach-O files in a
nested-code location lose their signature across the published ZIP round-trip,
while Resources are content-sealed and survive. CI verifies this with a ZIP
round-trip `codesign --verify --deep --strict`.

## Explicitly NOT changing

- `integrations/danterm/SKILL.md` -- the `danterm` CLI skill; the CLI surface is
  untouched, so AGENTS.md's "update SKILL.md when the CLI changes" does not apply.
- `CLIPathInstaller.swift` + its tests -- resolve only the exact
  `Contents/Helpers/danterm` path (and assert non-directory); they never
  enumerate the dir, and the hooks live in a different directory entirely.
- `flake.nix` and the Nix `${pkgs...}` doc paths -- bundling is orthogonal to
  the Nix packages, which keep working as-is.
- `package.nix` -- NOT touched in this PR. It still points at a pre-hook release
  ZIP (`package.nix:7`; the latest auto-bump predates this change), wired to
  `.#default` (`flake.nix:77,89`), so adding hook `test -x` checks now would
  fail `nix build .#default` on master. The consumer-side assertion is deferred
  to a separate post-release PR -- see Follow-up.

## Follow-up (deferred -- separate PR after the first hook-bearing release)

`package.nix`'s consumer-side guard goes in its OWN PR, NOT on the auto-generated
bump PR. After each release the workflow opens a `nix: update package.nix to vX`
PR (`release-stable.yml:191-201`) and immediately squash-merges it --
`gh pr merge --squash || gh pr merge --auto --squash` (`release-stable.yml:203-212`;
no required checks or reviews, so #99/#98/... merged by the bot within minutes).
There is no window to amend that PR.

So once the FIRST stable release cut *after* this change has merged its package
bump -- i.e. `package.nix`'s `version`/`sha256` now resolve to a ZIP that
actually contains `Contents/Resources/danterm-hooks/` -- open a separate
follow-up PR adding the guard to `package.nix`'s `installPhase` (which already
`test -x`'s the GUI and CLI, lines 21-25):

```nix
for h in danterm-claude-notify-osc777 danterm-claude-agent-session danterm-codex-agent-session; do
  test -x "$out/Applications/DanTerm.app/Contents/Resources/danterm-hooks/$h"
done
```

Doing it as a separate post-merge PR (not now, not on the auto PR) keeps `nix
build .#default` green on master, since the check only runs against a ZIP that
contains the hooks. Once added it is permanent -- every later hook-bearing
release keeps passing it.

## Verification

### Implementation verification (run by the implementer)

1. `just build` (runs `dev-build.sh`), then confirm layout:
   `ls -l "$HOME/Applications/DanTerm Dev.app/Contents/Resources/danterm-hooks/"`
   shows the three scripts, each executable.
2. **Behavioral check against the bundled artifacts** using the existing
   harnesses (each honors `HOOK_UNDER_TEST`, the same override `flake.nix`'s
   checks use at lines 139/155/171) pointed at the dev bundle:
   ```sh
   APP="$HOME/Applications/DanTerm Dev.app/Contents/Resources/danterm-hooks"
   HOOK_UNDER_TEST="$APP/danterm-claude-notify-osc777" bash integrations/claude-code/claude-notify-osc777.test.sh
   HOOK_UNDER_TEST="$APP/danterm-claude-agent-session" bash integrations/claude-code/danterm-agent-session.test.sh
   HOOK_UNDER_TEST="$APP/danterm-codex-agent-session" bash integrations/codex/danterm-agent-session.test.sh
   ```
   All suites pass -- this exercises real hook semantics (including the `Stop`
   subagent-suppression branch the old ad-hoc smoke got wrong) against the
   files as bundled, not just the source copies.
3. **Local ZIP round-trip signature proof** (no cert needed; reproduces the
   reviewer's repro and proves Resources placement survives):
   ```sh
   ./build-app.sh
   codesign --force --deep --sign - build/DanTerm.app
   ( cd build && zip -qr RoundTrip.zip DanTerm.app )
   rm -rf build/roundtrip && unzip -q build/RoundTrip.zip -d build/roundtrip
   codesign --verify --deep --strict --verbose=2 build/roundtrip/DanTerm.app   # must pass
   for h in danterm-claude-notify-osc777 danterm-claude-agent-session danterm-codex-agent-session; do
     test -x "build/roundtrip/DanTerm.app/Contents/Resources/danterm-hooks/$h"; done
   ```
4. `just test` stays green (no core/protocol/lint behavior changed).
5. (Optional live test) Point a `Stop` hook in `~/.claude/settings.json` at the
   dev path and confirm a DanTerm notification fires on turn end.

CI then re-runs the layout + ZIP round-trip checks on the PR (change 4).

### Release validation (user-triggered, post-merge -- NOT an implementation step)

Per AGENTS.md, release/publish commands run only on explicit user instruction;
the implementer must not run them. As the final real-world confirmation, the
user:

1. Runs `just release patch` and waits for the stable workflow to sign +
   notarize + publish the DMG and ZIP.
2. Downloads the DMG, drags DanTerm to `/Applications`, then:
   ```sh
   APP=/Applications/DanTerm.app/Contents/Resources/danterm-hooks
   test -x "$APP/danterm-claude-notify-osc777"
   codesign --verify --deep --strict --verbose=2 /Applications/DanTerm.app   # must pass
   spctl -a -t exec -vvv /Applications/DanTerm.app                           # Gatekeeper: accepted
   printf '%s' '{"hook_event_name":"Stop","last_assistant_message":"hi"}' \
     | "$APP/danterm-claude-notify-osc777" | jq .                            # emits terminalSequence
   ```
   Note the smoke payload omits `agent_id` -- with it present the notify hook
   intentionally suppresses output (`claude-notify-osc777.sh:22`).

## Risk

The signing question that was previously "open" is now resolved by the reviewer's
repro and folded into the design: bundling under `Contents/Helpers/` was the
latent bug (the published ZIP's seal does not survive there), and
`Contents/Resources/danterm-hooks/` is the evidence-backed safe location.
Residual risk is low and is gated in this change two ways before any release
reaches users -- the local ZIP round-trip proof (impl step 3) and the CI ZIP
round-trip verify (changes 3b/4) -- with a third consumer-side `package.nix`
`test -x` guard following in the post-release bump PR (see Follow-up).
If a future macOS codesign ever objected even to Resources placement, the
fallback is a non-executable bundling (drop the exec bit, document `bash <path>`
as the hook command) -- not expected to be needed.

## Follow Up

- After the first stable release that bundles `Contents/Resources/danterm-hooks/`
  and its package bump have landed, add hook executable assertions to
  `package.nix`'s `installPhase`.
