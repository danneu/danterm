# A Package Owns Its Sources: One Manifest Declares a Target

- Status: Accepted
- Date: 2026-08-17

## Context

The root `Package.swift` used to declare `DanTermProtocol`, `DanTermClient`, and
`DanTermSupport` itself, each with a `path:` pointing inside
`lib/<package>/Sources/`, and for two of them it re-declared the test target over
the nested package's own `Tests/` directory as well. The nested manifests
declared the same targets over the same directories.

That shape was never decided. The root declared `DanTermProtocol` in May 2026,
before any package carried an iOS pin, and `DanTermClient` copied the shape in
August on the day it was created. Four things followed from it:

- **One suite ran twice.** The gate ran the protocol package and the root
  package, and both compiled and executed `DanTermProtocolTests` over the same
  files.
- **One suite ran under no package of its own.** `DanTermClientTests` compiled
  twice but ran only through the root, and no gate step named
  `lib/DanTermClient` at all.
- **Two declarations of one target drifted.** The root's `DanTermSupport`
  carried `.linkedFramework("CoreText")` and the nested one did not, while
  `FontAvailability.swift` imports CoreText. Darwin autolinking hid the
  difference; nothing prevented the next one.
- **A re-declared test target escaped a gate.** `scripts/ios-portability-gate.sh`
  cross-compiles every target of every iOS-pinned manifest, tests included,
  because skipping test targets is exactly how a package acquires a host-bound
  test while its pin still says iOS. A test target owned instead by the
  macOS-only root manifest sits outside that claim.

## Decision

**O1 -- A target belongs to the nearest first-party `Package.swift` above its
declared path, and no other manifest may declare it.** Nesting stays legal:
`lib/DanTermCore` sits inside the root package's directory, and the root is
simply not the nearest manifest above those sources. What is illegal is an
ancestor manifest reaching *past* a nearer one -- the root declaring a target at
`lib/DanTermProtocol/Sources/DanTermProtocol` while
`lib/DanTermProtocol/Package.swift` stands between them.

A first-party manifest is any tracked file whose basename is `Package.swift`,
except one under `docs/` or `references/`. The discovery in
`scripts/manifest_targets.py` owns this definition. Every gate that enumerates
first-party packages or their `Sources/*/` modules derives its set from that
discovery, so package location cannot make a tracked package invisible.

**O2 -- Cross-package use goes through `.package(path:)` plus
`.product(name:package:)`,** the form the root already used for
`lib/TerminalCore` and `lib/TerminalPTY`, and the form `ios/DanTermMobileKit`
already used for the packages at issue. A target's build settings travel with
the target, so the CoreText link moved into `lib/DanTermSupport/Package.swift`
rather than being dropped.

**O3 -- Ownership is decided by the path a manifest DECLARES, never by the files
that path resolves to.** This is the half of the rule that keeps it away from
the `app/DanTermCore` and `app/DanTermSupport` symlinks. The root's app target
declares `path: "app"` and claims nothing outside it;
`lib/DanTermCore/Package.swift` stays the only manifest that names those
sources; and the second compile buys same-module `internal` access, which a
package dependency cannot deliver
([2026-05-28: The Core Module Compiles Twice, via a Symlink](2026-05-28-core-module-via-symlink.md)).
A symlink inside a target's own declared path is therefore not a violation. A
re-declared target is different in kind: it claims another package's directory
and compiles it under settings and platform pins the owner cannot see.

**O4 -- No allowlist.** `scripts/ios-portability-gate.sh` already argues this
down for its own pin: an allowlist makes a rule mean "owned, except where a list
says otherwise", and the exemption outlives the reason for it.

Two executed checks carry the rule, both reading manifest text only and both
rejecting a `path:` that is not a string literal, so a computed path fails
loudly instead of slipping past:

- `scripts/manifest-ownership-lint.py` enforces O1 and O3.
- `scripts/gate-test-coverage-lint.py` enforces the consequence: every
  first-party test estate runs in `just test`, exactly once, under the package
  that owns it.

## Consequences

- **The root manifest depends on three more packages and declares three fewer
  targets.** Every consumer reaches those modules through
  `.product(name:package:)`. Module identity is unchanged, so every `import`
  resolves the way it did before.
- **A package boundary is an access-level boundary.** Splitting
  `lib/DanTermSupport` out put `package` access out of the CLI's reach, so the
  three declarations `cli/main.swift` uses -- `DoctorProbeEnv`, its `live`
  value, and `gatherDoctorFacts` -- became `public`, the marker AGENTS.md names
  for the `lib/` boundary. Nothing else changed behavior. Expect the same when a
  future target moves out of a manifest: only a cold build shows it, because a
  warm scratch directory keeps the old access working.
- **`client-tests` does `@testable import DanTermSupport` across a package
  boundary.** That is proven in this tree already: `lib/TerminalPTY`'s tests do
  the same across the same kind of boundary.
- **The gate lost a duplicate and gained a lane.** `lib/DanTermClient` has its
  own `swift test` step, the protocol step lost a `--filter` that no longer
  selected anything, and the root test target stopped compiling roughly 4,800
  lines of another package's tests.
- **The iOS pin covers what it claims again.** Both pinned packages own every
  target they declare, so `scripts/ios-portability-gate.sh` cross-compiles the
  whole of each.
- **A new nested package needs no manifest edit at the root beyond a
  dependency.** Declaring its targets from the root is now a gate failure, and
  the failure names the manifest that owns them.

## References

- The ownership lint is `scripts/manifest-ownership-lint.py`; its self-test is
  `scripts/tests/manifest_ownership_lint_test.py`. Both share the manifest text
  parser and first-party manifest discovery in `scripts/manifest_targets.py`
  with the coverage check.
- The gate coverage check is `scripts/gate-test-coverage-lint.py`; its self-test
  is `scripts/tests/gate_test_coverage_lint_test.py`.
- The iOS pin this rule protects is stated in `scripts/ios-portability-gate.sh`.
- Deriving the gate's step list from the manifests is separate work. This
  decision supplies the precondition that work needs: one declaration per
  target.
