# git-cliff release notes

## Context

`gh release create --generate-notes` produces release bodies from squash-merged
PRs. DanTerm is a solo project where most work lands as direct commits to
`master`, so the auto-generated notes end up empty or trivial — v0.0.42 only
listed `nix: update package.nix to v0.0.41 (#50)`, hiding four real
fix/docs commits.

We already use Conventional Commits consistently. Replace `--generate-notes`
with [git-cliff](https://github.com/orhun/git-cliff), which builds a
release body by grouping conventional commits into sections (Features, Bug
Fixes, etc.) directly from the git log — no PR involvement.

git-cliff is invoked via `nix run nixpkgs#git-cliff` because the workflow
already installs nix later in the job (for `nix hash convert` /
`nix-prefetch-url`); we just need to move that install up.

## Files

- `cliff.toml` — new, repo root
- `.github/workflows/release-stable.yml` — reorder steps + replace `--generate-notes`
- `.github/workflows/ci.yml` — add `cliff-smoke` job that asserts expected
  rendering against a frozen `v0.0.41..v0.0.42` range

No CHANGELOG.md is created or maintained. Notes are generated per release and
written to a tempfile passed to `gh release create --notes-file`.

## cliff.toml

```toml
# git-cliff config for DanTerm release notes.
# Renders the release range requested on the command line; the release
# workflow passes `--current` (commits since the previous tag, scoped to
# the tag at HEAD).
# Filters out automated `release vX.Y.Z` and `nix: update package.nix` commits.

[changelog]
header = ""
body = """
{% for group, commits in commits | group_by(attribute="group") %}
### {{ group | striptags | trim }}

{% for commit in commits -%}
- {% if commit.scope %}*({{ commit.scope }})* {% endif %}\
{{ commit.message | upper_first }}
{% endfor %}
{% endfor %}
"""
trim = true
footer = ""

[git]
conventional_commits = true
filter_unconventional = false
filter_commits = false
tag_pattern = "^v[0-9]+\\.[0-9]+\\.[0-9]+$"
topo_order = false
sort_commits = "oldest"

# Order matters: groups render in declaration order via the
# `<!-- N -->Title` prefix that the `striptags` filter strips out.
commit_parsers = [
    { message = "^release v[0-9]+\\.[0-9]+\\.[0-9]+", skip = true },
    { message = "^nix: update package\\.nix", skip = true },
    { message = "^feat(\\([^)]+\\))?!?:",     group = "<!-- 0 -->Features" },
    { message = "^fix(\\([^)]+\\))?!?:",      group = "<!-- 1 -->Bug Fixes" },
    { message = "^perf(\\([^)]+\\))?!?:",     group = "<!-- 2 -->Performance" },
    { message = "^docs(\\([^)]+\\))?!?:",     group = "<!-- 3 -->Documentation" },
    { message = "^refactor(\\([^)]+\\))?!?:", group = "<!-- 4 -->Refactor" },
    { message = "^build(\\([^)]+\\))?!?:",    group = "<!-- 5 -->Build" },
    { message = "^ci(\\([^)]+\\))?!?:",       group = "<!-- 6 -->CI" },
    { message = "^test(\\([^)]+\\))?!?:",     group = "<!-- 7 -->Tests" },
    { message = "^chore(\\([^)]+\\))?!?:",    group = "<!-- 8 -->Chore" },
    { message = ".*",                          group = "<!-- 9 -->Other" },
]
```

Notes:

- `striptags` strips the `<!-- N -->` prefix used purely for sort ordering.
  git-cliff sorts groups alphabetically; numeric prefixes inside an HTML
  comment is the standard idiom (used by every cliff.toml in the wild).
- Each type parser is anchored to the full Conventional Commit header
  shape: `^feat(\([^)]+\))?!?:` matches `feat:`, `feat(scope):`, `feat!:`,
  and `feat(scope)!:`, but not freeform messages that happen to start
  with the word "feat". A squash-merge title like `fix release workflow
  auto-merge step` lacks the trailing `:` and falls through to the
  `.*` -> Other catchall instead of getting mis-grouped under Bug Fixes.
- Empty sections render nothing because the outer `for` loop iterates only
  over groups that actually have commits.
- `filter_commits = false` plus a `.*` -> Other catchall keeps non-conventional
  commits visible (e.g. legacy `update agents.md`) instead of silently dropping
  them.
- `tag_pattern` is anchored with `^...$` so a stray `test-v0.0.43` or
  `v0.0.43-beta` tag can't slip into the release range. Required so
  `--current` and `--unreleased` walk only real release tags.

## Workflow diff (`.github/workflows/release-stable.yml`)

Three changes:

### 1. Fetch full history at checkout (line 21)

`actions/checkout@v6` defaults to a shallow clone with no tags. git-cliff
needs both to walk back to the previous tag.

```diff
-      - uses: actions/checkout@v6
+      - uses: actions/checkout@v6
+        with:
+          fetch-depth: 0
```

### 2. Move the nix-installer step up (currently line 158)

Move the `DeterminateSystems/nix-installer-action@v21` step to run BEFORE
the `Create GitHub Release` step (line 140). Place it right after `actions/checkout`
so nix is available throughout. The existing `Compute release zip hash` step
stays where it is.

```diff
       - uses: actions/checkout@v6
         with:
           fetch-depth: 0

+      - uses: DeterminateSystems/nix-installer-action@v21
+
       - name: Set version from tag
         ...
```

And remove the duplicate from line 158:

```diff
-      - uses: DeterminateSystems/nix-installer-action@v21
-
       - name: Compute release zip hash
         run: |
```

### 3. Replace `--generate-notes` with git-cliff output (lines 140-156)

```diff
       - name: Create GitHub Release
         env:
           GH_TOKEN: ${{ github.token }}
         run: |
           tag="${{ github.ref_name }}"
           if gh release view "$tag" &>/dev/null; then
             gh release upload "$tag" \
               build/${{ env.DMG_NAME }} \
               build/${{ env.ZIP_NAME }} \
               --clobber
           else
+            NOTES_FILE="$RUNNER_TEMP/release-notes.md"
+            nix run nixpkgs#git-cliff -- \
+              --current \
+              --strip all \
+              --output "$NOTES_FILE"
+            if [ ! -s "$NOTES_FILE" ]; then
+              printf '_No notable changes._\n' > "$NOTES_FILE"
+            fi
             gh release create "$tag" \
               --title "$tag" \
-              --generate-notes \
+              --notes-file "$NOTES_FILE" \
               build/${{ env.DMG_NAME }} \
               build/${{ env.ZIP_NAME }}
           fi
```

Why `--current --strip all`:

- `--current` picks the tag at HEAD. The workflow is triggered by `push:
  tags: ['v*']` and `actions/checkout@v6` checks out that exact tag, so
  HEAD is unambiguously the release we're building. `--latest` would
  instead pick whichever tag sorts highest in the repo, which silently
  breaks if you ever re-run the workflow on an older tag (e.g. to fix a
  failed notarization for v0.0.42 after v0.0.43 has shipped).
- `--strip all` drops both the configured header and footer (which we leave
  empty anyway; this is belt-and-suspenders against future template tweaks).
- The empty-output guard prevents `gh release create` from publishing a
  body that's literally an empty string when the only commits in a range
  are filtered ones.

## Local dry-run

To preview the notes for v0.0.41..v0.0.42 today (before this is merged
anywhere):

```sh
nix run nixpkgs#git-cliff -- v0.0.41..v0.0.42 --strip all
```

Expected output (based on the actual commits in that range):

```
### Bug Fixes

- *(ci)* Swap auto-merge order so nix PRs merge immediately
- *(prefs)* Baseline-align preferences form rows
- *(sidebar)* Sync tab chrome when pane close auto-focuses sibling

### Documentation

- *(readme)* Add todo list feature
```

The `release v0.0.42` and `nix: update package.nix to v0.0.41 (#50)` commits
are filtered out by `skip = true` rules.

To preview what the next release (v0.0.43) would look like before tagging
locally:

```sh
nix run nixpkgs#git-cliff -- --unreleased --tag v0.0.43 --strip all
```

To verify what CI will produce, check out the tag locally and run with
`--current` (mirrors what the workflow does after its tag-triggered
checkout):

```sh
git checkout v0.0.42
nix run nixpkgs#git-cliff -- --current --strip all
git checkout -  # back to your branch
```

Locally, where HEAD usually isn't on a tag, prefer `--latest` for casual
preview — it works without needing to switch branches:

```sh
nix run nixpkgs#git-cliff -- --latest --strip all
```

## CI smoke test

Add a small job to `.github/workflows/ci.yml` so every PR catches template
breakage, group-ordering regressions, or filter-rule typos before they hit
a real release. Runs on ubuntu-latest (cheaper than the macos-26 build job)
because git-cliff is platform-agnostic.

```yaml
  cliff-smoke:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - uses: DeterminateSystems/nix-installer-action@v21

      - name: git-cliff smoke test (v0.0.41..v0.0.42)
        run: |
          out=$(nix run nixpkgs#git-cliff -- v0.0.41..v0.0.42 --strip all)
          echo "$out"

          # Must include expected real commits.
          echo "$out" | grep -qF '*(sidebar)* Sync tab chrome' \
            || { echo "missing fix(sidebar) entry"; exit 1; }
          echo "$out" | grep -qF '*(readme)* Add todo list feature' \
            || { echo "missing docs(readme) entry"; exit 1; }
          echo "$out" | grep -qF '### Bug Fixes' \
            || { echo "missing Bug Fixes section"; exit 1; }
          echo "$out" | grep -qF '### Documentation' \
            || { echo "missing Documentation section"; exit 1; }

          # Must NOT include filtered commits.
          echo "$out" | grep -q 'release v0\.0\.42' \
            && { echo "release commit leaked"; exit 1; }
          echo "$out" | grep -q 'nix: update package\.nix' \
            && { echo "nix-bump commit leaked"; exit 1; }

          # Section order: Bug Fixes must precede Documentation.
          bugs_line=$(echo "$out" | grep -n '### Bug Fixes' | head -1 | cut -d: -f1)
          docs_line=$(echo "$out" | grep -n '### Documentation' | head -1 | cut -d: -f1)
          [ "$bugs_line" -lt "$docs_line" ] \
            || { echo "section order wrong: Bug Fixes($bugs_line) >= Documentation($docs_line)"; exit 1; }

      - name: git-cliff smoke test (v0.0.40..v0.0.41 — Other catchall)
        # This range has only non-conventional commits (`update agents.md`
        # and `Impl per-pane todo list feature (#49)`) plus the filtered
        # `release v0.0.41`. Verifies the `.*` -> Other catchall keeps
        # non-conventional commits visible instead of dropping them.
        run: |
          out=$(nix run nixpkgs#git-cliff -- v0.0.40..v0.0.41 --strip all)
          echo "$out"

          echo "$out" | grep -qF '### Other' \
            || { echo "missing Other section for non-conventional commits"; exit 1; }
          echo "$out" | grep -qF 'Update agents.md' \
            || { echo "non-conventional commit dropped from Other"; exit 1; }
          echo "$out" | grep -q 'release v0\.0\.41' \
            && { echo "release commit leaked into Other"; exit 1; }

      - name: git-cliff smoke test (v0.0.39..v0.0.40 — tightened parser guard)
        # This range contains BOTH a conventional `fix: downgrade
        # swift-tools-version ...` commit AND a non-conventional `fix
        # release workflow auto-merge step ...` commit (no colon after
        # "fix"). With broad `^fix` parsers the latter would mis-group
        # under Bug Fixes; the tightened `^fix(\([^)]+\))?!?:` parser
        # must let it fall through to Other. This test fails loudly if
        # someone reverts the parser regexes back to the broad form.
        run: |
          out=$(nix run nixpkgs#git-cliff -- v0.0.39..v0.0.40 --strip all)
          echo "$out"

          other_line=$(echo "$out" | grep -n '^### Other' | head -1 | cut -d: -f1)
          bugs_line=$(echo "$out" | grep -n '^### Bug Fixes' | head -1 | cut -d: -f1)
          target_line=$(echo "$out" | grep -nF 'Fix release workflow auto-merge step' | head -1 | cut -d: -f1)
          fix_conv_line=$(echo "$out" | grep -nF 'Downgrade swift-tools-version' | head -1 | cut -d: -f1)

          [ -n "$other_line" ]    || { echo "missing Other section"; exit 1; }
          [ -n "$bugs_line" ]     || { echo "missing Bug Fixes section"; exit 1; }
          [ -n "$target_line" ]   || { echo "non-conventional 'fix release workflow ...' missing entirely"; exit 1; }
          [ -n "$fix_conv_line" ] || { echo "conventional 'fix:' commit missing"; exit 1; }

          # Non-conventional `fix release workflow ...` must be under Other,
          # i.e. AFTER the Other header.
          [ "$target_line" -gt "$other_line" ] \
            || { echo "non-conventional 'fix release workflow ...' leaked into Bug Fixes"; exit 1; }

          # Conventional `fix:` must be in Bug Fixes, i.e. between the
          # Bug Fixes header and the Other header.
          [ "$fix_conv_line" -gt "$bugs_line" ] && [ "$fix_conv_line" -lt "$other_line" ] \
            || { echo "conventional 'fix:' not in Bug Fixes section"; exit 1; }
```

Pinning the test to a frozen tag range (`v0.0.41..v0.0.42`) means the
asserted strings stay valid across future commits. If those tags ever
get force-deleted/recreated this test breaks loudly — that's the desired
behavior.

## Edge cases worth flagging

1. **All-filtered release**: if every commit between two tags is a
   `release v*` or `nix: update package.nix` commit, git-cliff with
   `--strip all` produces an empty file. The workflow guard
   (`if [ ! -s "$NOTES_FILE" ]`) writes `_No notable changes._` so the
   release still has a non-empty body. Realistically this only happens
   if you tag twice in a row with no real changes.

2. **Re-running a failed workflow on an existing tag**: the existing
   if/else keeps the original branch (upload assets, don't regenerate
   notes). If you want notes regenerated on re-run, that's a separate
   change — current scope leaves that behavior alone.

3. **`nix run nixpkgs#git-cliff` resolves to an unpinned channel**: this
   is the same trade-off as the existing `nix hash convert` /
   `nix-prefetch-url` calls, which are also unpinned. If you want
   reproducibility, switch to `nixpkgs/nixos-25.11#git-cliff` (matches
   the rest of `~/world`'s channel pin). Recommendation: leave unpinned;
   git-cliff's CLI is stable enough that channel drift is unlikely to
   break things, and a stale-channel pin would require maintenance.

4. **Squash-merged PRs that don't follow Conventional Commits**: would
   land in "Other". With current discipline this is fine; the catchall
   prevents silent disappearance.

5. **macos-26 runner compatibility**: `DeterminateSystems/nix-installer-action@v21`
   already runs on this runner in the existing workflow, so `nix run`
   will work identically. git-cliff has aarch64-darwin and x86_64-darwin
   builds in nixpkgs; no platform issue.

6. **`fetch-depth: 0` cost**: full clone is ~tens of MB for this repo.
   Negligible compared to the multi-minute Zig build that follows. Not
   worth optimizing with `fetch-tags: true` + a shallow clone unless this
   becomes a bottleneck.

## Verification (after implementation)

1. Run the local dry-run command above; confirm output matches the
   expected v0.0.41..v0.0.42 rendering.
2. After PR merges, do a real release: `just release patch`.
3. On GitHub, open the new release and confirm:
   - Body has section headers in the prescribed order.
   - Each commit shows as `*(scope)* message` when scope is present.
   - No `release vX.Y.Z` or `nix: update package.nix` lines appear.
4. If something looks off, re-run the workflow on the same tag — the
   existing if-branch will only re-upload assets, so to test notes you'd
   delete the GitHub release first (not the tag), then re-run.
