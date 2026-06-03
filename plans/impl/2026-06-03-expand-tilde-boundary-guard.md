# Plan: boundary-aware guard for `expandTilde`

## Context

`expandTilde` (`lib/DanTermCore/Sources/DanTermCore/Model.swift:543-546`) expands a
saved `~` / `~/...` cwd back to an absolute path during snapshot restore. It guards
with a bare `path.hasPrefix("~")`, which also matches the `~user/...` home syntax and
then concatenates it into a corrupted path:

```
expandTilde("~danielle/foo", home: "/Users/dan")  ->  "/Users/dandanielle/foo"
```

This is the inverse-direction twin of a prefix-boundary bug already fixed in the
sibling `abbreviateHome` (`ModelOperations.swift:476-479`), which now guards
`path == home || path.hasPrefix(home + "/")`. `expandTilde` never got the symmetric
treatment.

**Reachability (why it's latent, but real):** `expandTilde` is reached only via
`resolveLaunch` (`Model.swift:525-537`, called from snapshot restore at
`Model.swift:581`), which expands a pane snapshot's `launch.cwd` / `pane.cwd`. DanTerm's
own save path (`abbreviateHome` at `Persistence.swift:138`) only ever emits `~` or
`~/...`, never `~user`, so a snapshot DanTerm itself saved can't carry a `~user` string
-- the normal save/restore round-trip is safe. The only way a `~user/...` value enters
that path is a hand-authored JSON init/restore snapshot with a `~user`-form `cwd`
(hand-authoring is a documented affordance -- see `Model.swift:324-326`).

The CLI does *not* reach this fix: a launch cwd from `danterm tab new --cwd ...` is
taken raw in `.createTab` (`Update.swift:38`), emitted as `.createSurface` (`Update.swift:94`),
and handed straight to Ghostty as `config.working_directory` (`TerminalView.swift:121`)
-- never through `expandTilde`. So the fix covers exactly the snapshot-restore path, not
live CLI launches.

So it's a correctness landmine through a supported input, not a live crash. The fix is
two lines and removes it.

**Intended outcome:** a `~user/...` path passes through `expandTilde` unchanged
(DanTerm does not do per-user tilde resolution -- and couldn't in the pure core, which
has no access to `getpwnam`), while `~` and `~/...` keep expanding exactly as today.

**Scope:** isolated. An exhaustive search of `lib/*/Sources` + `app/` found no other
tilde-expansion or home-abbreviation site -- `expandTilde` and the already-fixed
`abbreviateHome` are the only two. No sibling instances travel with this.

## The fix

`lib/DanTermCore/Sources/DanTermCore/Model.swift:544` -- tighten the guard to require a
component boundary, mirroring `abbreviateHome`:

```swift
// before
guard path.hasPrefix("~") else { return path }
// after
guard path == "~" || path.hasPrefix("~/") else { return path }
```

The `return home + path.dropFirst(1)` line is unchanged -- `dropFirst(1)` still yields
`""` for bare `~` (-> `home`) and `"/foo"` for `~/foo` (-> `home + "/foo"`). Only the
`~user` branch changes: it now falls through to `return path`.

Behavior table (home = `/Users/dan`):

| input            | before                          | after                      |
| ---------------- | ------------------------------- | -------------------------- |
| `~/foo`          | `/Users/dan/foo`                | `/Users/dan/foo`           |
| `~`              | `/Users/dan`                    | `/Users/dan`               |
| `/absolute`      | `/absolute`                     | `/absolute`                |
| `~danielle/foo`  | `/Users/dandanielle/foo` (bad)  | `~danielle/foo` (intact)   |

**Lint:** confirmed safe. The `// core-purity: ambient-seam` marker on line 543 exempts
the `NSHomeDirectory()` default parameter; the guard-token change touches neither the
marker nor the seam, so no annotation update is needed (`scripts/core-purity-lint.sh`).

## The test

Add a standalone `expandTildeBoundaryAware()` to
`lib/DanTermCore/Tests/DanTermCoreTests/DeterminismSeamTests.swift`, directly beside the
existing `abbreviateHomeBoundaryAware()` (line 156). This follows the established
precedent: DanTerm keeps the *basic* `abbreviateHome` test (`ModelOperationsTests.swift:905+`)
separate from its *boundary regression* in `DeterminismSeamTests`. Co-locating the two
boundary regressions documents them as a pair of the same bug class, in two directions,
and keeps each test's "Why it exists" single-purpose.

```swift
@Test("expandTilde is boundary-aware: a ~user prefix is left intact")
func expandTildeBoundaryAware() {
    // Intent: expandTilde only expands a bare "~" or a "~/"-rooted path;
    //   a "~user/..." form is left intact (DanTerm does not resolve other
    //   users' homes).
    // Why it exists: guards a later "simplification" back to the bare
    //   hasPrefix("~") from reintroducing the /Users/dandanielle/foo
    //   concat-corruption -- the inverse twin of the abbreviateHome
    //   boundary bug pinned just above.
    // Scenario: spec-first boundary check.
    #expect(expandTilde("~/foo", home: "/Users/dan") == "/Users/dan/foo")
    #expect(expandTilde("~", home: "/Users/dan") == "/Users/dan")
    #expect(expandTilde("~danielle/foo", home: "/Users/dan") == "~danielle/foo")
}
```

Inject explicit `home:` (as `abbreviateHomeBoundaryAware` does) so the test is
machine-independent. The existing `expandTildeExpandsHomeDirectory`
(`SnapshotTests.swift:648-661`) stays as-is -- it keeps covering the three basic
branches against ambient `NSHomeDirectory()`.

Minor: the `// MARK: - abbreviate-boundary` at `DeterminismSeamTests.swift:154` will now
host both boundary tests; optionally generalize it (e.g. `// MARK: - path-helper boundary`).

## Critical files

- `lib/DanTermCore/Sources/DanTermCore/Model.swift:544` -- the guard fix.
- `lib/DanTermCore/Tests/DanTermCoreTests/DeterminismSeamTests.swift` (~line 166) -- the
  new `expandTildeBoundaryAware()` test (+ optional MARK rename at line 154).

## Verification

TDD order: write the test first, watch the `~danielle/foo` assertion fail with
`/Users/dandanielle/foo`, then apply the guard change and watch it pass.

- `swift test --package-path lib/DanTermCore --filter DeterminismSeamTests` -- new test
  passes; `abbreviateHomeBoundaryAware` still passes.
- `swift test --package-path lib/DanTermCore --filter SnapshotTests` -- existing
  `expandTildeExpandsHomeDirectory` unaffected.
- `just test` -- full local gate, including the core-purity lint (confirms the
  ambient-seam annotation still satisfies the lint after the guard change).

## Implementation notes

- Took the optional MARK rename the plan flagged: `// MARK: - abbreviate-boundary
  (travels with the boundary-aware abbreviateHome fix)` ->
  `// MARK: - path-helper boundary (travels with the boundary-aware abbreviateHome /
  expandTilde fixes)`, since the section now hosts both boundary regressions.
