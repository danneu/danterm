#!/usr/bin/env python3
"""Enforces that a target belongs to the nearest first-party manifest above its declared path, and to no other.

Nesting is normal and stays legal: `lib/DanTermCore` sits inside the root package's
directory, and the root is simply not the nearest manifest above those sources. What
this check rejects is an ancestor manifest reaching *past* a nearer one -- the root
declaring a target at `lib/DanTermProtocol/Sources/DanTermProtocol` while
`lib/DanTermProtocol/Package.swift` stands between them.

That shape is not a style preference. A re-declared target compiles the owner's
sources under settings and platform pins the owner cannot see, so the two
declarations drift; its tests run once per declaring manifest, so the gate pays
twice for one suite; and a test target re-declared by a macOS-only manifest sits
outside the claim `scripts/ios-portability-gate.sh` makes about every target of a
pinned package. Cross-package use goes through `.package(path:)` plus
`.product(name:package:)` instead.

Ownership is decided by the path a manifest DECLARES, never by the files that path
resolves to. That line is what keeps this check away from the `app/DanTermCore` and
`app/DanTermSupport` symlinks: the root target declares `path: "app"` and claims
nothing outside it, so the symlinked sources inside it belong to the manifest that
declares them (docs/design/2026-08-17-package-owns-its-targets.md).

The check reads manifest text only; it never imports or executes a manifest. A
`path:` that is not a string literal is rejected rather than guessed at.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))

from manifest_targets import LintError, declared_targets  # noqa: E402

# Test seam: the self-test points the lint at a fixture tree of tiny manifests, so
# each verdict is proved without a compile. Nothing else sets this.
REPO_ROOT = Path(
    os.environ.get("MANIFEST_OWNERSHIP_LINT_ROOT")
    or Path(__file__).resolve().parent.parent
).resolve()

# Packages the tree owns. `references/` holds external checkouts, so a manifest there
# is not ours to police.
MANIFEST_GLOBS = ("Package.swift", "lib/*/Package.swift", "ios/*/Package.swift")


def owner_of(path: PurePosixPath, package_dirs: list[PurePosixPath]) -> PurePosixPath:
    """The deepest first-party package directory that contains path -- its nearest manifest."""
    containing = [
        directory
        for directory in package_dirs
        if directory == path or directory in path.parents
    ]
    return max(containing, key=lambda directory: len(directory.parts))


def main() -> int:
    manifests: list[Path] = []
    for glob in MANIFEST_GLOBS:
        manifests.extend(sorted(REPO_ROOT.glob(glob)))
    if not manifests:
        print(
            "manifest-ownership-lint: no first-party manifest found, so this check is "
            "checking nothing. Either the tree moved or this script looks in the wrong place.",
            file=sys.stderr,
        )
        return 1

    package_dirs = [
        PurePosixPath(manifest.parent.relative_to(REPO_ROOT).as_posix())
        for manifest in manifests
    ]

    complaints: list[str] = []
    checked = 0
    try:
        for manifest, package_dir in zip(manifests, package_dirs):
            manifest_rel = manifest.relative_to(REPO_ROOT).as_posix()
            for target in declared_targets(manifest):
                checked += 1
                # No `resolve()`, and no filesystem read: a symlink inside the declared
                # path must not move ownership away from the manifest that declared it.
                declared = PurePosixPath(
                    os.path.normpath(package_dir / target.declared_path())
                )
                owner = owner_of(declared, package_dirs)
                if owner == package_dir:
                    continue
                complaints.append(
                    f"{manifest_rel} declares target {target.name} at {declared}, which "
                    f"{owner}/Package.swift owns. A target belongs to the nearest manifest "
                    "above its declared path, and to no other. Depend on that package with "
                    "`.package(path:)` and reach the module through "
                    "`.product(name:package:)` instead of re-declaring its target."
                )
    except LintError as error:
        print(f"manifest-ownership-lint: {error}", file=sys.stderr)
        return 1

    if not checked:
        print(
            "manifest-ownership-lint: no manifest declares a target, so this check is "
            "checking nothing.",
            file=sys.stderr,
        )
        return 1

    if complaints:
        for complaint in complaints:
            print(f"manifest-ownership-lint: {complaint}", file=sys.stderr)
        return 1

    print(
        f"manifest-ownership-lint: {checked} targets across {len(manifests)} manifests, "
        "each declared by its nearest one"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
