# Retire the capability manifest in favor of the markdown doc

## Context

`terminal-capabilities-v1.json` is a machine-readable capability manifest with
no known consumers: no Swift source outside tests reads it, and it is only
copied into the app bundle and byte-compared in four CI/build gates. It largely
duplicates `docs/terminal-capabilities.md`. Its two ncurses terminfo fixtures
differ by a single value (`pairs`: 32767 vs 65536) that no behavioral test
exercises, and its "evidence" fields are only checked for membership in a name
allowlist -- provenance theater.

This change **intentionally retires the bundled machine-readable artifact as a
public interface.** That is an observable change: `Contents/Resources/
terminal-capabilities-v1.json` disappears from the bundle. Compatibility
policy: there are no known external consumers; the normative contract moves to
`docs/terminal-capabilities.md`, and if a machine-readable contract is ever
needed again it ships as a new versioned artifact (v2+), not a revival of v1.

The normative content the JSON carried is preserved, not dropped: every claim
and variant folds into the markdown doc, and the one behaviorally-checked
claim set (key encoding) stays as an executable test.

## Changes

### Fold the manifest's contract into docs/terminal-capabilities.md

Before deleting the JSON, expand `docs/terminal-capabilities.md` to carry
every normative claim and variant it holds: terminfo flags/values (`am`,
`bce`, `colors`, `pairs`), control sequences (`clear`, `cup`, cursor modes,
color sequences `setaf`/`setab`, mouse prefix), the key claims, protocol
supported/denied sets, and limits. Present as tables. Record `pairs` as
32767 (macOS 26 ncurses 6.0) vs 65536 (current ncurses) explicitly.

Add a provenance note: values were captured from the xterm-256color terminfo
entries of macOS 26 ncurses 6.0 and ncurses 6.x upstream (the two retired
fixtures). This note also records the retirement of the old proof obligation:
the "cross-ncurses baseline matrix" byte-comparison is replaced by (a) this
documented provenance and (b) the behavioral key-conformance test; the two
baselines differ only in `pairs`, which no behavior depends on.

### Delete

- `terminal-capabilities-v1.json`
- `terminal-terminfo/xterm-256color-macos-26-ncurses-6.0.json`
- `terminal-terminfo/xterm-256color-ncurses-1.1261.json` (delete the
  `terminal-terminfo/` directory if now empty)
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalCapabilityManifestTests.swift`
  (entire file: `manifestContract()`, the `executableEvidence` allowlist check,
  the private `Decodable` mirrors -- and `keyConformance()`, which moves, see
  below)

### Move + rewrite keyConformance

Add a test to
`lib/TerminalCore/Tests/TerminalCoreTests/TerminalKeyEncodingTests.swift`
(same target, already `@testable import TerminalCore` and exercises
`encodeTerminalKey`). Replace the manifest-decode with an inline table of the
terminfo key expectations the manifest carried -- the xterm-256color
application-cursor-mode sequences for kcuu1/kcud1/kcub1/kcuf1/khome/kend/
kdch1/kpp/knp -- read the current claim `variants` values out of the JSON
before deleting it. Keep the assertion shape:
`encodeTerminalKey(key, modifiers: [], modes: TerminalInputModes(applicationCursorKeys: true))`
must produce the terminfo sequence. Test title should say it pins DanTerm's
input encoding to the xterm-256color terminfo entries (the contract the
manifest used to state).

### Remove build/CI gates

- `build-app.sh:66` -- delete the `cp` of the manifest into Resources.
- `dev-build.sh:73` -- same.
- `scripts/tests/dev-build-configuration-contract_test.sh` -- remove the
  manifest copy (line ~27) and the `cmp` assertion (lines ~90-91); leave the
  rest of the contract test intact.
- `.github/workflows/ci.yml:172,193` -- delete both `cmp` gates.
- `.github/workflows/release-stable.yml:72,137` -- delete both `cmp` gates.

### Doc touch-ups

Repoint every non-historical manifest reference to
`docs/terminal-capabilities.md`, and where a doc states the manifest is the
normative artifact, restate the doc as normative and note the v1 JSON was
retired:

- `README.md:219-220`
- `docs/evidence/2026-07-21-terminal-capability-contract.md:14`
- `plan-terminal-engine/README.md` (declares a DanTerm-owned capability
  manifest normative)
- `plan-terminal-engine/10-protocols-shell-integration.md:43,48`
- `plan-terminal-engine/14-roadmap.md:352`
- `plan-terminal-engine/15-open-questions.md` (manifest v1 / future-versions
  language: reword to the v2+ policy stated in Context)
- `docs/research/1-external-tests.md` (manifest claim)

Leave historical `plans/impl/` files untouched.

## Non-goals / Accepted risks

- AR1: A hypothetical external tool reading the bundled JSON breaks. Accepted:
  no such consumer is known, the artifact was introduced 2026-07-21 on an
  experimental branch, and the v2+ policy above covers any future need.

## Verification

1. `rg -n 'terminal-capabilities-v1|terminal-terminfo|CapabilityManifest'`
   returns hits only in historical `plans/impl/` files and evidence docs that
   intentionally narrate history.
2. `swift test --package-path lib/TerminalCore --filter TerminalKeyEncodingTests`
   passes, including the moved conformance test (first verify it fails if an
   expected sequence is perturbed -- TDD check on the inlined table).
3. `just test` passes (covers the trimmed dev-build configuration contract).
4. `just build` succeeds and the built bundle's `Contents/Resources/` no longer
   contains `terminal-capabilities-v1.json`.
5. `docs/terminal-capabilities.md` contains every claim id present in the
   deleted JSON (spot-check by diffing the claim list against the doc's
   tables before deleting the file).
