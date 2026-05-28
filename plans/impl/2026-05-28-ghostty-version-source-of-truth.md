# Single source of truth for the Ghostty version pin

## Context

DanTerm pins Ghostty to a specific tag (`v1.3.0`). That tag string is currently
duplicated across five files:

- `build-lib.sh` line 22 -- `GHOSTTY_TAG="v1.3.0"`
- `.github/workflows/ci.yml` line 7 -- workflow `env:` block
- `.github/workflows/release-stable.yml` line 12 -- workflow `env:` block
- `.github/workflows/cache-ghosttykit.yml` line 20 -- workflow `env:` block
- `docs/upgrading-ghostty.md` lines 11-14 -- the "Places to update" checklist
  that exists *because* the duplication exists

Bumping Ghostty means editing four files in lockstep plus the doc that lists
those four files. The CI cache key uses `${{ env.GHOSTTY_TAG }}` so drift
between workflows would silently break cache reuse. The intended outcome:
one file edit + one rebuild command + commit.

**Out of scope, deliberately:**

- The Zig pin (`0.15.2` in 3 workflows; `nixpkgs#zig_0_15` in build-lib.sh).
  Local nix channel vs CI exact patch version makes a clean single-file SoT
  awkward, and Zig only bumps when a Ghostty major requires it. Solve when
  it next bites.
- Collapsing the CI workflows' inlined `zig build` into a call to
  `./build-lib.sh`. The local/CI split is intentional (local: `nix shell`;
  CI: `mlugg/setup-zig`); unifying needs a "skip nix wrapper if zig is on
  PATH" branch in build-lib.sh that is hack-shaped.

## Approach

1. **New file `.ghostty-version`** at repo root -- single line, `v1.3.0` plus
   a trailing newline. The sole source of truth.

2. **Extracted validator: `scripts/load-ghostty-version.sh`.** A single
   shell script is the *only* place that parses and trusts
   `.ghostty-version`. Every other caller (CI workflows, `build-lib.sh`)
   goes through it. The script is a **pure function** -- input is the
   file at `$GHOSTTY_VERSION_FILE` (default `./.ghostty-version`); output
   is the validated tag on stdout and an exit status; no other side
   effects, no environment writes. Each caller does its own export
   inline (see section 4 for workflows; section 3 for build-lib.sh).

   - Shebang: `#!/usr/bin/env bash`. Uses `$'\n'` ANSI-C quoting and
     `[[ =~ ]]` (POSIX ERE); requires bash >= 3.2 (matches macOS system
     bash 3.2 and Ubuntu CI bash 5.x). Do **not** use `#!/bin/sh` --
     Ubuntu's `/bin/sh` is `dash`, which lacks both constructs.
   - Reads the file as a whole-blob bash value (`raw=$(<"$version_file")`,
     which strips only trailing newlines), then **rejects any embedded
     newline** with `case "$raw" in *$'\n'*) ... exit 1 ;; esac` (covers
     the multi-line `$GITHUB_ENV` smuggling case).
   - **Then** validates the remaining single-line value against
     `^v[0-9]+\.[0-9]+\.[0-9]+$` using bash's `[[ =~ ]]` (POSIX ERE on
     the whole string, not line-oriented like `grep`).
   - Emits the validated tag on stdout (single line, newline-terminated)
     and exits 0.
   - **On rejection**, writes a single descriptive line to stderr naming
     the failure reason (`embedded newline`, `does not match vX.Y.Z`,
     `file not found`, etc.) and the offending input value (truncated to
     the first 80 chars in case the file is binary). Stdout stays clean
     on rejection so callers can rely on stdout-only-on-success. Exit
     status is non-zero. The validator is the security boundary for
     PR-controlled content, so a contributor whose `.ghostty-version`
     edit fails CI must be able to see *which* check fired without
     spelunking the script source.
   - Accepts an optional `GHOSTTY_VERSION_FILE` env override so the
     paired self-test can drive it against tmpfiles without mutating
     the real `.ghostty-version`.

   **Deliberately-strict regex.** `^v[0-9]+\.[0-9]+\.[0-9]+$` rejects
   prerelease/build-metadata tags like `v1.4.0-rc1`, `v1.4.0-beta.1`,
   `v2.0.0+build.5`. Ghostty currently tags `vX.Y.Z` only, and the
   validator is the security boundary for PR-controlled content, so the
   strict allow-list is the right default. A future contributor wanting
   to test an upstream RC should *consciously* widen the regex (and
   acknowledge the new attack surface) rather than have the validator
   silently accept dashes/plus-signs. The validator script carries a
   one-line comment above the regex stating this choice explicitly.

   Why extracted and not inline in each workflow: (a) the validator is the
   security boundary, so it gets exactly one implementation that all three
   workflows share; no drift between yml files; (b) it can be exercised
   by an on-disk self-test that runs under `just test`, which an inline
   yml block can't be; (c) `build-lib.sh` reuses the same validator
   instead of re-implementing `cat + format check` locally.

   Why pure-function and not "also writes to `$GITHUB_ENV` when set":
   the conditional side-effect branch would never be exercised by the
   self-test (which runs without `GITHUB_ENV` set, locally and in CI), so
   typos like `>` instead of `>>`, missing quotes around the value, or a
   misspelled var name would silently rot. The most damaging case is
   `release-stable.yml`, where the existing "Set version from tag" step
   writes `VERSION`/`DMG_NAME`/`ZIP_NAME` to `$GITHUB_ENV` *before* the
   Load step would run -- a `>` slip would wipe those vars and only fail
   on a real `v*` tag push, since `release-build-check` passes `--version`
   directly and never reads `$VERSION` from env. Pushing the
   `>> "$GITHUB_ENV"` to each call site makes the redirection
   self-evident in the workflow YAML and brings the whole validator
   surface under the self-test.

   **Paired self-test: `scripts/tests/load-ghostty-version_test.sh`.**
   Mirrors the existing `scripts/tests/core-purity-lint_test.sh` pattern.
   Shebang `#!/usr/bin/env bash`, same bash >= 3.2 assumption. The first
   line of the test body is `unset GITHUB_ENV` -- defense-in-depth even
   though the validator no longer touches `$GITHUB_ENV` under the
   pure-function design (this makes the test self-contained regardless
   of caller context). Drives the validator via
   `GHOSTTY_VERSION_FILE=<tmpfile>` and asserts exit status:
   - **Accept:** `v1.3.0\n`, `v0.0.0\n`, `v10.20.30\n` (each must exit 0
     **and** print exactly the tag on stdout; the test compares stdout
     bytes against the expected string).
   - **Reject:** `v1.3.0; echo pwned`, `v1.3.0\nMALICIOUS=1` (embedded
     newline -- the canonical case the prior `grep -Eq` validator
     silently accepted), empty file, `1.3.0` (missing `v`), `v1.3`
     (incomplete semver), `v1.3.0.0` (extra component), `v1.3.0 `
     (trailing space), ` v1.3.0` (leading space), `v1.4.0-rc1` (locks
     the deliberate prerelease-rejection contract in section above).
     Each must exit non-zero **and write something to stderr**; the
     stderr assertion is behavioral (`stderr is non-empty`), not a
     formatting pin -- it just enforces that a silent-rejection regression
     fails the test. Stdout must be empty on rejection. The test fails
     loud if any case is accepted, prints nothing to stderr, or leaks
     output to stdout.

   The test script is wired into `just test` alongside the existing
   `core-purity-lint_test.sh`.

   **Sibling test for the build-lib stale-source guard:
   `scripts/tests/build-lib-stale-guard_test.sh`.** Same shebang +
   bash assumption. Exists because verification #4 (manual edit-and-
   revert) is exactly the kind of step that rots silently; an automated
   test prevents a future cleanup from neutralizing the guard. The test:
   - creates a tmpdir, `git init`s it, makes one commit, tags it `v0.0.1`;
   - writes a tmpfile containing `v0.0.2\n` (a tag the temp repo does
     *not* have);
   - runs `GHOSTTY_VERSION_FILE=<tmpfile> GHOSTTY_CACHE_DIR=<tmpdir> ./build-lib.sh build`;
   - asserts non-zero exit, and stderr contains both `v0.0.1` (actual)
     and `v0.0.2` (expected) -- proves the guard fires *and* names both
     tags;
   - asserts no `zig build` was invoked (no `lib/GhosttyKit.xcframework`
     mutation, no Metal toolchain prompt).
   It also covers the "no `.ghostty-src/` at all" case by pointing
   `GHOSTTY_CACHE_DIR` at a non-existent path and asserting the guard
   fires with a clear "missing source" message. This is why section 3
   requires `build-lib.sh` to accept a `GHOSTTY_CACHE_DIR` env override.

3. **`build-lib.sh` refactor.** Read the tag via the extracted validator:

   ```bash
   GHOSTTY_TAG="$(./scripts/load-ghostty-version.sh)"
   ```

   Split the body into two functions and dispatch on a positional
   subcommand:

   ```
   ./build-lib.sh fetch   # clone/checkout source only
   ./build-lib.sh build   # zig-build the xcframework from existing .ghostty-src/
   ./build-lib.sh all     # default; both (matches current bare-invocation behavior)
   ./build-lib.sh         # same as `all`
   ```

   Required invariants in the refactor:

   - **`fetch_ghostty` is the only function that mutates `.ghostty-src/`.**
     It handles the existing if-clone-else-fetch+checkout logic,
     parameterized on the `GHOSTTY_TAG` returned by the validator.
   - **`build_xcframework` guards against stale source.** Before invoking
     `zig build`, it asserts both that `.ghostty-src/` exists AND that
     `git -C "$CACHE_DIR" describe --tags --exact-match` equals the parsed
     `GHOSTTY_TAG`. If either check fails, exit non-zero with: "run
     `./build-lib.sh fetch` (or `./build-lib.sh all`) -- .ghostty-src/ is at
     `<actual>` but .ghostty-version requires `<expected>`". This preserves
     the pre-refactor guarantee that "build" always builds the pinned tag,
     which the current monolithic script provided implicitly by always
     fetching first. The guard is locked down by
     `scripts/tests/build-lib-stale-guard_test.sh` (see section 2).
   - **`CACHE_DIR` accepts a `GHOSTTY_CACHE_DIR` env override.**
     Specifically, `CACHE_DIR="${GHOSTTY_CACHE_DIR:-$SCRIPT_DIR/.ghostty-src}"`.
     Production callers (workflows, local devs) never set the env var
     and get the default; the stale-guard self-test sets it to a tmpdir
     to exercise the guard without touching the real `.ghostty-src/`.
     Zero behavior change for production; full testability for the guard.
   - **Move the Metal toolchain check into `build_xcframework`.** Currently
     `xcodebuild -downloadComponent MetalToolchain` runs at script startup
     (build-lib.sh lines 17-19). After the refactor it must move inside
     `build_xcframework` so `./build-lib.sh fetch` (and `just fetch-ghostty`)
     stay lightweight source-only operations that do not require Xcode setup.
     Additionally, the Metal check must run *after* the stale-source guard
     fires, so the stale-guard test does not need Xcode (the guard rejects
     before Metal setup is reached).
   - `fetch_ghostty` and `build_xcframework` are otherwise independent and
     compose: `all` calls them in order.

4. **Workflow change, identical pattern in 3 files.** For
   `.github/workflows/ci.yml`, `release-stable.yml`,
   `cache-ghosttykit.yml`:

   - Remove `GHOSTTY_TAG: v1.3.0` from the top-level `env:` block.
   - **Immediately after `- uses: actions/checkout@v6` in every affected
     job** (uniform placement across all three workflows -- no special
     cases), add the load step that calls the pure-function validator
     and writes the result to `$GITHUB_ENV`:
     ```yaml
     - name: Load Ghostty version
       run: |
         GHOSTTY_TAG=$(./scripts/load-ghostty-version.sh)
         echo "GHOSTTY_TAG=$GHOSTTY_TAG" >> "$GITHUB_ENV"
     ```
     The two-line form is load-bearing. Bash's `set -e` (the GitHub
     Actions default for `bash` shells, configured as
     `bash --noprofile --norc -eo pipefail {0}`) does **not** propagate
     failures from a command substitution nested inside another command
     -- `inherit_errexit` is off by default. So
     `echo "GHOSTTY_TAG=$(./script)" >> "$GITHUB_ENV"` would silently
     swallow a validator failure: the validator exits 1 with empty
     stdout, `echo` itself returns 0 (a writable redirect with valid
     args always succeeds), and `set -e` sees no failure. The step would
     "succeed" with `GHOSTTY_TAG=` empty, the cache key would land on
     `ghosttykit-v2--<hash>-...`, and the clone step would fail with a
     cryptic `fatal: A branch name must not be empty` far from the root
     cause. The two-line form makes the assignment its own simple
     command: a bare assignment's exit status equals the exit status of
     the last command substitution, so `GHOSTTY_TAG=$(failing)` *does*
     fire `set -e` and abort the step at the validator. The `echo` line
     only runs after the validator succeeds. After this step finishes,
     every subsequent step in the job sees `GHOSTTY_TAG` as a shell env
     var **and** as `${{ env.GHOSTTY_TAG }}`. The "after checkout"
     placement is uniform on purpose: same step body, same position,
     trivial to diff-mirror across the three files.
     **`.ghostty-version` is PR-controlled content on `pull_request`-triggered
     workflows**; the validator is the security boundary that pins the
     contract before any value enters `$GITHUB_ENV`.
   - **Switch every `run:` block that uses the tag from Actions expression
     substitution to native shell variable expansion.** GitHub Actions
     expands `${{ env.X }}` *into the rendered shell script* before the
     shell runs; in a `git clone --branch ${{ env.GHOSTTY_TAG }} ...`
     line, a hostile value would be parsed by the shell as code -- even
     a validator-rejected value would never get there in practice, but
     the defense-in-depth is to never let Actions expression substitution
     reach a shell command line at all. The safe pattern:
     ```yaml
     - name: Clone Ghostty source
       run: |
         git clone --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty.git .ghostty-src
     ```
     Same change applies to any other `run:` line currently using
     `${{ env.GHOSTTY_TAG }}` (search each workflow). The cache `key:`
     keeps `${{ env.GHOSTTY_TAG }}` -- it is an action input that is not
     shell-evaluated, so expression substitution is safe there.

   Affected jobs:
   - `ci.yml`: `build` and `release-build-check` (the `cliff-smoke` job
     never used the tag and is untouched). Each job has both a clone step
     and a cache key reference; only the clone step's `run:` body needs
     the shell-expansion change.
   - `release-stable.yml`: the single `release` job. Load step is placed
     immediately after `actions/checkout@v6` -- *before* the existing
     "Set version from tag" step, not after, so the load step's placement
     is identical to the other two workflows and the implementer never
     has to think about per-workflow ordering. Clone step's `run:` body
     switches to `"$GHOSTTY_TAG"`.
   - `cache-ghosttykit.yml`: the single `cache` job. Clone step's `run:`
     body switches to `"$GHOSTTY_TAG"`.

   **New CI gate -- validator self-test job in `ci.yml`.** The validator
   is the security boundary, so its contract has to be gated on every PR,
   not only on the local developer's machine. Today `ci.yml`'s `build`
   job runs `./build-app.sh` + `codesign` -- it does not run `just test`,
   so a future validator regression that still accepts the canonical
   `.ghostty-version` content would silently pass CI. Add a small focused
   job that mirrors the existing `cliff-smoke` shape, plus a second step
   for the stale-guard test:
   ```yaml
   validator-self-test:
     runs-on: ubuntu-latest
     steps:
       - uses: actions/checkout@v6
       - name: Validator self-test
         run: ./scripts/tests/load-ghostty-version_test.sh
       - name: build-lib stale-source guard self-test
         run: ./scripts/tests/build-lib-stale-guard_test.sh
   ```
   No `env -u GITHUB_ENV` wrapper is needed: under the pure-function
   validator design, the script never touches `$GITHUB_ENV`, and the test
   defensively `unset`s it at the top regardless. Runs in parallel with
   `build` (no `needs:`), so it doesn't slow the build job; PR fails fast
   if either contract regresses.

5. **`cache-ghosttykit.yml` `paths:` trigger.** Add `'.ghostty-version'` to
   the `on.push.paths` list so that a future version bump on master
   automatically warms the cache. Without this, bumping `.ghostty-version`
   alone (no `build-lib.sh` change) would skip the cache warmer.

6. **Two new `just` recipes.** After `clean:` in the justfile:

   ```just
   # Clone/fetch Ghostty source for reference (no xcframework build).
   fetch-ghostty:
       ./build-lib.sh fetch

   # Fetch Ghostty source and build the GhosttyKit xcframework.
   build-lib:
       ./build-lib.sh
   ```

   The existing `test:` recipe gains two new steps that invoke
   `scripts/tests/load-ghostty-version_test.sh` and
   `scripts/tests/build-lib-stale-guard_test.sh`, alongside the existing
   `core-purity-lint.sh` and `core-purity-lint_test.sh`. Total: six
   steps (protocol XCTest, core Swift Testing, core-purity lint,
   core-purity lint self-test, validator self-test, stale-guard self-test).

7. **Doc collapse.**
   - `docs/upgrading-ghostty.md`: the "Places to update" table for the
     Ghostty tag becomes a single line ("edit `.ghostty-version`"). Steps
     collapse to: edit, `just build-lib`, `just build && just test`, PR.
     The Zig-version table stays (still legitimately multi-file).
   - `docs/ci.md`: the "Pinned versions" Ghostty bullet points at
     `.ghostty-version` instead of "set via `GHOSTTY_TAG` env var in each
     workflow".
   - `AGENTS.md`: the build-lib.sh description currently parenthesizes
     "(currently v1.3.0)"; replace with "(pinned via `.ghostty-version`)".

After the change, the bump workflow is:

```bash
echo v1.4.0 > .ghostty-version
just build-lib && just build && just test
git add .ghostty-version lib/ && git commit -m 'chore: bump ghostty to v1.4.0'
```

## Files to modify

| Path | Change |
|------|--------|
| `.ghostty-version` *(new)* | Single line `v1.3.0\n` |
| `scripts/load-ghostty-version.sh` *(new)* | Pure-function validator (`#!/usr/bin/env bash`): whole-blob read, reject embedded newline, validate `^v[0-9]+\.[0-9]+\.[0-9]+$`, emit validated tag on stdout (success only); on rejection, exit non-zero with a single descriptive stderr line naming the failure reason and offending input (truncated to 80 chars), stdout stays clean. Respects `$GHOSTTY_VERSION_FILE` override; does NOT write to `$GITHUB_ENV` (callers do that inline). Carries a one-line comment documenting the deliberate prerelease-tag rejection |
| `scripts/tests/load-ghostty-version_test.sh` *(new)* | `#!/usr/bin/env bash`. First line `unset GITHUB_ENV`. Drives validator via `GHOSTTY_VERSION_FILE` tmpfiles; asserts exit status AND stdout-bytes on every accept case; for every reject case asserts non-zero exit, non-empty stderr (behavioral, not pinned wording), and empty stdout (incl. the `v1.4.0-rc1` case that locks the prerelease-rejection contract) |
| `scripts/tests/build-lib-stale-guard_test.sh` *(new)* | `#!/usr/bin/env bash`. First line `unset GITHUB_ENV`. Seeds a tmp git repo tagged `v0.0.1`, writes a tmpfile `.ghostty-version` with `v0.0.2`, runs `GHOSTTY_VERSION_FILE=<tmpfile> GHOSTTY_CACHE_DIR=<tmpdir> ./build-lib.sh build`; asserts non-zero exit and that stderr names both tags. Also covers the missing-source case (`GHOSTTY_CACHE_DIR` pointing at a non-existent path) |
| `build-lib.sh` | Call validator for `GHOSTTY_TAG`; split into `fetch_ghostty`/`build_xcframework`; subcommand dispatch; move Metal toolchain into `build_xcframework` (and after the stale-source guard); accept `GHOSTTY_CACHE_DIR` env override on `CACHE_DIR`; stale-tag guard |
| `justfile` | Two new recipes (`fetch-ghostty`, `build-lib`); `test:` gains validator + stale-guard self-test steps |
| `.github/workflows/ci.yml` | Drop env literal; load step is a two-line bash block placed immediately after `actions/checkout@v6` -- `GHOSTTY_TAG=$(./scripts/load-ghostty-version.sh)` then `echo "GHOSTTY_TAG=$GHOSTTY_TAG" >> "$GITHUB_ENV"` (split so the bare assignment carries the validator's exit status under `set -e`; a one-liner would silently swallow validator failures); clone steps use `"$GHOSTTY_TAG"` (shell var, not Actions expression); new `validator-self-test` job runs both self-tests on ubuntu |
| `.github/workflows/release-stable.yml` | Same pattern in the `release` job |
| `.github/workflows/cache-ghosttykit.yml` | Same pattern in the `cache` job; add `.ghostty-version` to `on.push.paths` |
| `docs/upgrading-ghostty.md` | Collapse Ghostty section to single-file edit; keep Zig section |
| `docs/ci.md` | Point Pinned-versions bullet at `.ghostty-version` |
| `AGENTS.md` | Replace "currently v1.3.0" with `.ghostty-version` pointer |

The workflow change is one pattern applied three times; review one diff
carefully, then mirror.

## Verification

1. **Zero literal pin references remain.**
   ```bash
   grep -rn 'v1\.3\.0' build-lib.sh justfile .github/workflows/ docs/ AGENTS.md
   ```
   Allowed remaining hits (factual historical notes, not pin/procedure
   references):
   - `docs/ci.md` line 52 -- "As of Ghostty v1.3.0, dependency URLs use a
     CDN ..." (factual statement about behavior introduced at that version).
   - `AGENTS.md` line 271 -- "As of v1.3.0, dependency URLs use a CDN ..."
     (same factual note).
   No remaining hits in `build-lib.sh`, `justfile`, `.github/workflows/`,
   `docs/upgrading-ghostty.md`, or in any prose that reads as a current pin
   ("currently v1.3.0", "set GHOSTTY_TAG to v1.3.0", etc.). A grep that
   excludes those exact two factual lines should print nothing.

2. **Fetch-only path stays lightweight.**
   ```bash
   rm -rf .ghostty-src
   just fetch-ghostty
   test -f .ghostty-src/build.zig.zon && echo ok
   ```
   Watch stdout:
   - "Ensuring Metal toolchain is installed..." must NOT appear (the
     toolchain check moved into `build_xcframework`).
   - "Building GhosttyKit XCFramework" must NOT appear.
   The script returns after the clone.

3. **Full rebuild + tests pass with tag unchanged.**
   ```bash
   just build-lib    # rebuilds lib/GhosttyKit.xcframework
   just build        # compiles .build/DanTerm Dev.app
   just test         # all six steps green (protocol + core + core-purity lint
                     #   + lint self-test + validator self-test + stale-guard
                     #   self-test)
   ```

4. **Stale-source guard fires.** The primary check is the automated
   sibling test:
   ```bash
   ./scripts/tests/build-lib-stale-guard_test.sh
   ```
   It seeds a throwaway git repo, points `GHOSTTY_CACHE_DIR` and
   `GHOSTTY_VERSION_FILE` at tmp paths, and asserts non-zero exit +
   stderr-naming-both-tags. The real `.ghostty-src/` and
   `.ghostty-version` are never touched, so the test is safe to run
   in any local state.

   Optional manual smoke (only if behavior is in doubt): with the real
   `.ghostty-src/` already on the current tag, edit `.ghostty-version`
   to a real-but-different tag like `v1.2.0`, run `./build-lib.sh build`,
   expect the same mismatch error. Revert. Not needed if the automated
   test passes.

5. **Bump simulation, fetch fails clean.** Edit `.ghostty-version` to a
   deliberately-bad tag (`v999.0.0`), run `./build-lib.sh fetch`, expect a
   clear `git fetch` / `git clone` error mentioning `v999.0.0`. Revert.

6. **Validator self-test passes.** This is the authoritative coverage of
   the validator contract; the workflows and `build-lib.sh` both go
   through the same script, so passing this test certifies all callers.
   ```bash
   ./scripts/tests/load-ghostty-version_test.sh
   ```
   The test drives the validator with `GHOSTTY_VERSION_FILE` pointing
   at tmpfiles (real `.ghostty-version` is never touched), starts with
   `unset GITHUB_ENV` for defense-in-depth, and asserts exit status
   *and* stdout bytes:
   - **Accept (exit 0; stdout exactly equals the tag):** `v1.3.0\n`,
     `v0.0.0\n`, `v10.20.30\n`.
   - **Reject (non-zero exit):** `v1.3.0; echo pwned`,
     `$'v1.3.0\nMALICIOUS=1'` (multiline -- this is the case the
     prior `grep -Eq` validator silently accepted), empty file,
     `1.3.0`, `v1.3`, `v1.3.0.0`, `v1.3.0 `, ` v1.3.0`, `v1.4.0-rc1`
     (locks the deliberate prerelease-rejection contract).
   The test asserts via direct exit-status comparison
   (`if "$validator"; then echo FAIL; exit 1; fi` for reject cases),
   not via shell short-circuit chains like `&& echo ok || echo reject`
   that swallow the failure into a zero exit code. Any acceptance of
   a reject case prints which input slipped through and exits non-zero.

   This same self-test runs in two places:
   - **Locally**, as the fifth step of `just test`, on every developer
     run.
   - **In CI**, as a dedicated `validator-self-test` job in `ci.yml`
     (`runs-on: ubuntu-latest`), which also runs the
     `build-lib-stale-guard_test.sh` sibling test in a second step.
     This job is the actual PR gate -- without it, a future regression
     in either the validator or the stale-guard that still accepted
     the canonical inputs would pass CI's build job (which doesn't run
     `just test`).

   So both contracts (validator + stale-guard) are enforced on every
   local run AND every PR.

7. **Workflow lint.** Run `actionlint .github/workflows/*.yml` if installed;
   otherwise read-through each affected job and confirm:
   - The `Load Ghostty version` step appears after `actions/checkout@v6`
     and before any step that references `$GHOSTTY_TAG` or
     `${{ env.GHOSTTY_TAG }}`.
   - No literal `v1.3.0` remains under `.github/workflows/`.
   - Every `run:` block that uses the tag does so via `"$GHOSTTY_TAG"`
     (shell var), not via `${{ env.GHOSTTY_TAG }}` (Actions expression).
   - The cache `key:` still reads
     `ghosttykit-v2-${{ env.GHOSTTY_TAG }}-${{ hashFiles('build-lib.sh') }}-...`
     -- safe because `key:` is an action input, not shell-evaluated.

8. **CI live check.** Open the PR. Expected:
   - The new `validator-self-test` job in `ci.yml` runs on
     `ubuntu-latest` and passes (fast: a few seconds; runs in parallel
     with `build`).
   - The `build` and `release-build-check` jobs in `ci.yml` **cold-build**
     GhosttyKit. The cache key includes `hashFiles('build-lib.sh')` and
     this PR changes `build-lib.sh`, so the cache key is new -- cache miss
     is the correct outcome on this refactor PR. Subsequent reruns with
     the same tag *and* the same `build-lib.sh` hash will hit cache.
   - `cache-ghosttykit.yml` doesn't run on the PR (master-push trigger);
     it warms the post-merge cache on master. Post-merge: verify a fresh
     CI run on master, or a downstream PR rebased on master, hits cache.
   - As a follow-up smoke test (separate throwaway branch): bump
     `.ghostty-version` to a hypothetical newer tag, push, observe cache
     miss -> fresh build -> revert.

9. **Cold-read the upgrade doc.** Read `docs/upgrading-ghostty.md` from
   scratch and confirm the procedure is genuinely "edit one file + rebuild
   + test + PR" with no hidden extra-file edits.

## Implementation notes

- Updated `AGENTS.md`'s `just test` description to include the Ghostty validator
  and stale-source self-tests because the justfile gate now runs six steps.
- Workflow cache keys use a `Load Ghostty version` step output instead of
  `${{ env.GHOSTTY_TAG }}` so action inputs do not depend on `$GITHUB_ENV`
  updating the workflow expression context; the same load step still writes
  `GHOSTTY_TAG` to `$GITHUB_ENV` for shell commands.
