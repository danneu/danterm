# Prevent stale TerminalPTY test artifacts

## Problem and desired outcome

`TerminalPaneSessionControllerTests` crashed deterministically in
`TerminalPaneSessionController.planIfNeeded` while copying a `Terminal`. The bad
retain targeted generated test code in the executable's read-only text segment,
not a heap object. A package-scoped clean made the focused test pass, then all 63
TerminalPTY tests and the complete `just test` gate passed. Recent commits had
changed private `Terminal` storage without causing every downstream TerminalPTY
test object to rebuild.

The default test gate must not execute clients compiled against an older
TerminalCore value layout. Warm runs that use the same TerminalCore inputs must
remain incremental. The explicit `just clean` contract must also remove the
nested SwiftPM caches it currently leaves behind.

## Decision

- Route TerminalPTY tests through one repository-owned wrapper. It fingerprints
  the TerminalCore manifest and source tree. A missing or changed successful
  fingerprint requires a package-scoped TerminalPTY clean before testing;
  unchanged inputs use the warm cache.
- Publish the new fingerprint only after the requested TerminalPTY test command
  succeeds. A failed build, crash, or test therefore cannot bless its artifacts.
- Keep the fingerprint in ignored build state owned by `just clean`. The wrapper
  accepts ordinary `swift test` arguments so focused and full runs share the
  same invalidation policy.
- Expand `just clean` to remove the root build state and every known nested
  SwiftPM package cache using explicit repository-relative targets.
- Close the originating follow-up as a test-orchestration defect. Do not change
  `Terminal`, its snapshot APIs, `planIfNeeded`, or actor ownership to mask stale
  build products.

## Invariants

- **I1 (layout freshness).** A TerminalCore manifest, source-content, source-path,
  addition, or removal change cannot reach TerminalPTY tests without first
  invalidating the old TerminalPTY package build.
- **I2 (incrementality).** Repeated TerminalPTY runs over identical TerminalCore
  inputs do not clean and retain SwiftPM's warm-build behavior.
- **I3 (failure integrity).** Only a successful test command records the current
  fingerprint; real failures remain visible and are never automatically retried
  away.
- **I4 (clean ownership).** After `just clean`, no root or known nested SwiftPM
  build cache, including the fingerprint, remains.
- **I5 (behavioral neutrality).** Application code and public Swift APIs are
  unchanged; the only interface changes are the test wrapper and the stronger
  developer-facing clean contract.

## Proof obligations

- **PO1 (I1-I3).** A shell-level behavioral test proves that the wrapper cleans
  on first use and after every fingerprint-relevant change, stays warm when
  inputs are unchanged, forwards focused-test arguments, and withholds the new
  fingerprint after failure. This self-test runs under `just test`.
- **PO2 (I4).** Exercise `just clean` against populated root, nested-package, and
  fingerprint build state and verify every owned target is absent afterward.
- **PO3 (I1, I2, I5).** From a cold state, the formerly crashing focused test,
  the full TerminalPTY package, and `just test` pass; an immediate warm rerun
  also passes without a TerminalPTY clean.

## Non-goals

- Redesigning `Terminal` representation, adding reference boxing, or changing
  snapshot and controller ownership.
- Fixing SwiftPM or depending on an unverified toolchain upgrade to remove the
  repository workaround.
- Automatically cleaning or retrying every test failure.
- Centralizing every package under a new shared scratch-path layout.

## Accepted risks

- **AR1.** Any TerminalCore source edit triggers a clean even when it cannot
  affect ABI. This is broader than necessary but reliable; classifying Swift
  edits by layout impact would make the guard unsound.
- **AR2.** Corruption unrelated to a TerminalCore input change still requires a
  manual `just clean`. The automatic policy targets the reproduced failure
  class rather than treating every cache as disposable.

## Rejected ideas

- **RI1. Unconditional TerminalPTY cleaning.** Reliable, but it adds the measured
  cold-build cost to every warm gate despite unchanged inputs.
- **RI2. Documentation-only recovery.** A manual command leaves the default gate
  capable of reproducing a bus error after routine core changes.
- **RI3. Automatic clean-and-retry after failure.** A retry could hide a genuine
  memory-safety regression and make the first failure harder to diagnose.

## Implementation discretion

- The portable hashing and atomic stamp-write mechanics, provided path and
  content changes are both represented.
- The exact shell-test seams used to substitute the Swift command and temporary
  repository state.

## Critical files

- `justfile`
- `scripts/test-terminal-pty.sh`
- `scripts/tests/test-terminal-pty_test.sh`
