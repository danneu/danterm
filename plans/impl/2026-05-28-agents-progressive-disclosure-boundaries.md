# Plan: AGENTS.md simplification round 2 -- progressive disclosure + boundaries

## Context

We already cut ~55 lines from `AGENTS.md` in commit `791e839` (file-tree fix,
comment-rule reconciliation, file-header rationale, XCTest preamble drop, Plan
Review Protocol removal). The remaining ~350-line file still carries reference
content (`Build Details`, `Test architecture`, `Reference Sources`) that
agents don't need on every session, narrative around the Build section, and
several one-liner sections that don't pull weight. It also lacks explicit
negative-space rules (the GitHub-blog 2,500-repo study cited concrete
prohibitions as the most commonly helpful constraint), and mandates a
3-section preamble on every test in a way that collides with the
declaration-comment rule's "earn it" principle.

After three rounds of multiple-choice review with the user (round 1: hoisting,
build, deletions; round 2: test rule, voice, boundaries; round 3:
architecture, CLI API), nine concrete moves were agreed. This plan executes
them in a single editing pass.

Target shape: ~200 lines, progressive-disclosure for reference content,
explicit boundary rules near the top, imperative voice throughout, no
contradictions between policy sections.

## Goals

- Simple: cut narrative and reference content that doesn't belong in
  always-on context; collapse one-liner sections.
- Robust: surface concrete "never touch" rules; reconcile the test-preamble
  vs declaration-comment conflict.
- Reversible: every hoisted section is preserved -- either adapted into a
  new file under `agent-docs/` or represented by an existing tracked design
  doc -- with a one-line pointer in `Further reading`. Nothing is
  permanently deleted that the user might want back.

## Files affected

### Modified

- `AGENTS.md` -- the main edit pass (~9 section-level changes).

### Created

- `agent-docs/build-details.md` -- holds the current `## Build Details`
  content (build-lib.sh internals, dev/release Swift compilation, xcframework
  + linker explanation).
- `agent-docs/reference-sources.md` -- holds the current `## Reference
  Sources` content (`.ghostty-src/` key files, cmux reference, "don't guess"
  rule with full context).

Note: `agent-docs/` does not exist in `my-apps/danterm/` yet -- the parent
repo `~/world/agent-docs/` is the convention precedent. Creating the
directory under DanTerm matches that pattern locally.

### Not created

- No agent-doc for `Test architecture` -- the existing design doc at
  `docs/design/2026-05-28-core-module-via-symlink.md` already covers it
  comprehensively. The current Test-architecture section already ends with a
  pointer there; after hoist, the section disappears and the pointer migrates
  into the `Further reading` block.

## Section-by-section edits in AGENTS.md

Numbered to match the agreed decision list.

### 1. Hoist `Build Details`, `Test architecture`, `Reference Sources`

- Delete the entire `## Build Details` section (current lines ~263-290) and
  its `### build-lib.sh` + `### Swift compilation` subsections. Adapted
  content lives in `agent-docs/build-details.md` (see content spec below).
  Lightly edited from the current section: imperative-voice pass applied;
  `just release` mentioned only to clarify it is NOT a build-script wrapper
  (it's an inline tag/push recipe routed through the `## Boundaries` rule
  in AGENTS.md), so the recipe list there stays focused on build wrappers.
- Delete the entire `### Test architecture` subsection under Code Style
  (current lines ~171-198), including its trailing design-doc pointer. No
  agent-doc replaces it; the existing design doc at
  `docs/design/2026-05-28-core-module-via-symlink.md` already covers the
  same material, and its pointer migrates into `Further reading` (see #5).
- Delete the entire `## Reference Sources` section (current lines ~298-317).
  Adapted content lives in `agent-docs/reference-sources.md` (see content
  spec below). Restructured into Ghostty-source / Other-terminals /
  Don't-guess subsections; the load-bearing "don't guess" rule is also
  echoed in `## Boundaries` so it survives without an agent reading the
  full file.
- Pointers to the two new agent-docs files plus the migrated design-doc
  pointer land in `Further reading` (see #5).

### 2. Collapse `Build` to flat recipe list + two-step note

Replace the entire current `## Build` block (lines ~200-261, including the
`### Dev build` and `### Tests` subsections, and the "We practice TDD"
trailer) with this shape:

```
## Build

Run `./build-lib.sh` once to build the cached `GhosttyKit.xcframework` before
the first Swift build. Re-run only when the pinned Ghostty version changes.

- `just build` -- compile to `.build/DanTerm Dev.app` and install to
  `~/Applications/DanTerm Dev.app`. Dev bundle ID `com.danneu.danterm-dev`
  runs side-by-side with production `DanTerm.app`.
- `just build-run` -- same as `just build`, then launch the installed app.
- `just test` -- local gate: protocol XCTest + core Swift Testing +
  core-purity lint + three shell self-tests (`core-purity-lint_test.sh`,
  `load-ghostty-version_test.sh`, `build-lib-stale-guard_test.sh`).
- `just test-ui` -- AppKit UI harness (needs a display).

Targeted core runs: `swift test --package-path lib/DanTermCore`, optionally
with `--filter CheckpointTests`. Protocol-only: `swift test --package-path
lib/DanTermProtocol --filter DanTermProtocolTests`.

See [agent-docs/build-details.md](agent-docs/build-details.md) for
`build-lib.sh` internals, dev/release Swift compilation modes, and xcframework
linker details.
```

The TDD policy line ("Practice TDD: write the failing test first, ...") moves
to the top of the `Test preambles` subsection -- TDD is about *when* to write
tests, which sits naturally alongside the rule for *what* a test's preamble
should say.

`just release` is intentionally omitted from the recipe list; the new
Boundaries section carries it as a "don't run without instruction" rule and
that's enough context for an agent.

### 3. Fold `## GitHub API` rule into Boundaries

The current one-line section says "Use `gh` CLI for all GitHub API
requests." That's a load-bearing behavioral constraint, not just an
incidental line -- without it, agents will reach for `curl` or hand-rolled
HTTP for GitHub work. Delete the lonely top-level section but preserve the
rule by adding it to the new `## Boundaries` block (see #8 for the exact
shape).

Net effect: section count drops by one, behavioral rule survives.

### 4. Delete `## Git commits`

One-line section. Remove entirely. The parent `~/world/AGENTS.md` already
states the Conventional Commits convention.

### 5. Merge `Design Docs` + `Operational Docs` into `Further reading`

Replace the two adjacent sections with a single `## Further reading` block,
mirroring the parent `~/world/AGENTS.md` "Read when ..." pattern. The block
absorbs (a) all current Design Docs + Operational Docs links, (b) the new
`agent-docs/` pointers from #1, (c) the migrated Test-architecture pointer.

Shape:

```
## Further reading

Topic docs. Read the linked file before editing if your task touches the
topic.

- [docs/design/index.md](docs/design/index.md) -- ADR-style design-decision
  index.
- [docs/design/2026-05-28-core-module-via-symlink.md](docs/design/2026-05-28-core-module-via-symlink.md)
  -- pure core compiled same-module via symlink, tested via nested SwiftPM
  package. Read when touching the test architecture, the `app/DanTermCore`
  symlink, or `lib/DanTermCore/Package.swift`.
- [docs/design/2026-03-05-display-scaling.md](docs/design/2026-03-05-display-scaling.md)
  -- HiDPI/Retina scaling, content scale invariants, zero-frame guards.
- [agent-docs/build-details.md](agent-docs/build-details.md) --
  `build-lib.sh`, Swift compilation modes, xcframework + linker details. Read
  when touching build scripts or upgrading Ghostty.
- [agent-docs/reference-sources.md](agent-docs/reference-sources.md) --
  `.ghostty-src/` layout, key files for the libghostty C API, other terminal
  references. Read when implementing against libghostty.
- [docs/ci.md](docs/ci.md) -- CI/CD pipeline, code signing, notarization,
  troubleshooting.
- [docs/upgrading-ghostty.md](docs/upgrading-ghostty.md) -- upgrading the
  pinned Ghostty version, CI cache.
```

### 6. Loosen the test-preamble rule

Replace the current "Every individual test opens with a `//` preamble of
three labeled sections" with an earn-its-keep gate matching the declaration
rule. New shape for the section body:

```
### Test preambles

Practice TDD: write the failing test first, verify it fails for the expected
reason, then change the code and verify the test passes.

A test earns a `//` preamble when something non-trivial belongs above the
body -- a regression it pins down, an invariant the test name can't carry, a
non-obvious why. Trivial spec-first tests just need a descriptive
`@Test("...")` title and no preamble. When you write one, use these three
labeled sections at the top of the method body:

1. **Intent** -- the behavior this test verifies.
2. **Why it exists** -- the risk it guards: a regression for a bug-fix test,
   or the behavior contract it pins down for a spec-first test.
3. **Scenario** -- the concrete user/system story the test models. For a
   bug-fix test, name the incident. For a spec-first test, describe the
   user-facing behavior. Don't invent an incident -- DanTerm is TDD-first, so
   most tests are spec-first and legitimately have none.

Applies to both idioms: Swift Testing `@Test("...") func ...` in
`lib/DanTermCore/Tests/` and XCTest `func testX()` in
`lib/DanTermProtocol/Tests/` -- same shape in both.
```

The existing bug-fix example (`movePane(.splitRight) threads ...`) stays
under this section unchanged -- it demonstrates exactly the case where a
preamble earns its keep.

### 7. Imperative-voice pass

Mechanical changes throughout the file. Representative examples (not
exhaustive):

- "We practice TDD" -> "Practice TDD" (now lives in Test preambles).
- "Both build scripts use `swift build`" -> "Build scripts use `swift
  build`" (lives in `agent-docs/build-details.md`; apply there too).
- "Every individual test opens with ..." -> already restructured under #6.
- "We do not use Xcode's `//  FileName.swift` banner" (file-header section)
  -> "Don't use Xcode's `//  FileName.swift` banner".
- "Every `.swift` file opens with a top-of-file `//` comment block on line 1"
  -> "Open every `.swift` file with a top-of-file `//` comment block on line
  1".
- Code Style intro stays in third person ("Comments explain intent...") --
  it reads as policy/principle, not instruction-to-agent. Don't force
  imperative there.

Audit each section once during execution; convert any "we/this project/the
project" subject-as-actor into imperative or descriptive form.

### 8. Add `Boundaries` section

Place immediately after `## App design goals` and before `## Architecture`.
Top-third placement makes the rules visible before an agent gets deep into
the model. Use the "Don't" structure to group the negative-space rules
clearly:

```
## Boundaries

Don't edit:

- `lib/GhosttyKit.xcframework/` -- regenerated by `./build-lib.sh`; manual
  edits get wiped on the next rebuild.
- `.ghostty-src/` -- cloned libghostty reference for the C API and Ghostty's
  macOS Swift app; manual edits make the reference unreliable.

Don't run:

- `just release patch|minor|major` (or any other release/publish command)
  without explicit user instruction.

Don't guess:

- API signatures, delegate protocols, enum cases, or framework behavior.
  Check local sources first -- see
  [agent-docs/reference-sources.md](agent-docs/reference-sources.md).

For GitHub API requests:

- Use the `gh` CLI. Don't reach for `curl` or hand-rolled HTTP.
```

Two of these bullets absorb rules from sections being deleted elsewhere in
this pass: the "Don't guess" bullet carries the load-bearing rule from the
hoisted `## Reference Sources` section (see #1), and the "GitHub API
requests" bullet carries the rule from the folded `## GitHub API` section
(see #3). Both survive the section-level deletions.

### 9. Trim `CLI API Documentation` to one line

Replace the current 4-line `## CLI API Documentation` section with:

```
## CLI API Documentation

When changing the `danterm` CLI surface (commands, flags, stdout shape,
parser errors), update `integrations/danterm/SKILL.md` in the same change.
```

The parenthetical file-path enumeration (`cli/main.swift` and
`lib/DanTermProtocol/.../CLIParser.swift`) is dropped -- the SKILL.md itself
should know what it tracks.

## Content for new files

### `agent-docs/build-details.md`

Header (top-of-file `//` style doesn't apply to markdown; use a one-line
intro):

```
# Build details

Reference for the DanTerm build pipeline. Read when touching `build-lib.sh`,
the dev/release Swift build scripts, or the xcframework linker setup. The
build recipes `just build` and `just build-run` wrap the scripts described
here; `just release` is a separate inline tag/push recipe in the `Justfile`
that's covered by the `## Boundaries` rule in `AGENTS.md`.

## build-lib.sh

- Clones Ghostty at a pinned tag (currently v1.3.0).
- Builds with `nix shell nixpkgs#zig_0_15 nixpkgs#gettext --command zig
  build`.
- Flags: `-Demit-xcframework -Demit-macos-app=false -Dsentry=false
  -Doptimize=ReleaseFast`.
- xcframework output path is `lib/GhosttyKit.xcframework/` (NOT `zig-out/`).
- As of v1.3.0, dependency URLs use a CDN (`deps.files.ghostty.org`); the old
  iTerm2-Color-Schemes URL staleness issue is resolved.

## Swift compilation

Build scripts use `swift build` via `Package.swift`, the single source of
truth for Swift sources, framework dependencies, and linker flags.

- `dev-build.sh` -- debug mode (fast incremental rebuilds), dev icons, dev
  bundle ID, installs to `~/Applications`. Wrapped by `just build` and `just
  build-run`.
- `build-app.sh` -- release mode (`--configuration release`, applies `-O`),
  production icons, optional `--version` stamping. Called by CI and release
  workflows.

The xcframework contains a static library (`libghostty.a`) + C headers with
a module map, NOT a `.framework` bundle. `Package.swift` declares
`GhosttyKit` as a `.binaryTarget` and specifies the required frameworks in
`linkerSettings`:

- `-lc++` -- libghostty statically links SPIRV-Cross and glslang (C++).
- `-framework Carbon` -- keyboard layout APIs (TIS*).

## Requirements

- nix (for `zig_0_15` and `gettext`).
- Xcode with Metal toolchain: `xcodebuild -downloadComponent
  MetalToolchain`.
- The GhosttyKit xcframework must be built before compiling the Swift app.
```

The `Requirements` content moves from AGENTS.md into here -- it's build-env
trivia that fits naturally with the build pipeline reference. The current
top-level `## Requirements` section is removed from AGENTS.md as part of the
hoist (consolidating with build details).

### `agent-docs/reference-sources.md`

```
# Reference sources

External sources to consult when implementing against the libghostty C API
or referencing other terminals' approaches.

## Ghostty source

The Ghostty source is cloned locally at `.ghostty-src/` (by `build-lib.sh`).
When you need to reference the libghostty C API, read these files directly
instead of making web requests:

- `.ghostty-src/include/ghostty.h` -- full C API header (types, structs,
  functions).
- `.ghostty-src/macos/Sources/Ghostty/` -- Ghostty's own macOS Swift app
  (reference implementation).
- `.ghostty-src/src/apprt/embedded.zig` -- embedded runtime (implements the
  C API).

For any other external library, clone it locally first so you can read it
directly. Never use web requests to read source code when a local clone is
available.

## Other terminals

- `github:manaflow-ai/cmux` -- another macOS terminal built on libghostty
  (vertical tabs, AI agent notifications). Useful reference for feature
  work.

## Don't-guess rule

Don't guess at API signatures, delegate protocols, enum cases, or framework
behavior. Check local sources first; if insufficient, search online and read
official docs before writing code. AGENTS.md surfaces this rule in
`## Boundaries` so the agent sees it before diving in -- this file holds
the full context.
```

## Verification

After execution, the following should hold:

1. **Compile + test still pass**: `just build` and `just test` are
   unaffected by docs-only edits, but run them as sanity checks to confirm
   no code accidentally moved.
2. **Pointers resolve**: every link in the new `Further reading` block
   resolves to an existing file. Confirm with: `grep -oE
   '\(([a-zA-Z0-9./_-]+\.md)\)' AGENTS.md | tr -d '()' | sort -u | xargs -I
   {} test -f {}` -- nothing should print as missing. The character class
   must include digits so dated filenames like
   `2026-05-28-core-module-via-symlink.md` match.
3. **AGENTS.md length sanity check**: `wc -l AGENTS.md` should land in the
   ~200-line range. If it's still >250, the hoist or Build collapse left
   prose behind.
4. **No section drift**: AGENTS.md table of contents (`grep '^## '
   AGENTS.md`) should match this final list, in order:
   - `## App design goals`
   - `## Boundaries`
   - `## Architecture` (with `### Data flow`, `### Typed IDs`)
   - `## Code Style` (with `### File header comments`, `### Doc comments on
     declarations`, `### Test preambles`)
   - `## Build`
   - `## CI/CD`
   - `## CLI API Documentation`
   - `## Further reading`
5. **No load-bearing content lost**: spot-check that (a) the TDD policy line
   landed in Test preambles, (b) the "don't guess" rule landed in
   Boundaries, (c) Test-architecture's design-doc pointer landed in Further
   reading, (d) Requirements content landed in `agent-docs/build-details.md`,
   (e) the `gh` CLI rule landed in Boundaries (its former top-level section
   is deleted).

## Notes / open follow-ups

- The "App design goals" section (4 lines, kept as-is) and the Architecture
  section (tree + Data flow + Typed IDs, kept as-is) are explicitly out of
  scope for this round per the user's round-3 choices.
- The Code Style header subsections (`File header comments`, `Doc comments
  on declarations`) are untouched -- their content was just settled in the
  previous simplification commit.
- The agent-docs/ directory is new for DanTerm; the parent `~/world/` repo
  already uses the same pattern with the same `Further reading` framing, so
  the convention transfers cleanly.
- Commit message: planned single commit titled `docs: progressive disclosure
  + boundaries pass on AGENTS.md` (Conventional Commits, matches the prior
  `docs: simplify AGENTS.md ...` commit style).
