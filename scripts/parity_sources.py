"""Swift source discovery shared by the kitty and alacritty parity lints.

Both lints scan the same population -- every Swift file in the checkout, minus the
vendored, build, and worktree trees -- and the skip rule has one subtlety that is
easy to break (see `swift_sources`). One copy keeps the two lints from drifting
apart on which files they claim to have checked.

Nothing else belongs here. The citation grammar, the pin, and the ledger rules
differ between the two lints and stay in each lint.
"""

from __future__ import annotations

import os
from pathlib import Path


# `.claude` holds agent worktrees (`.claude/worktrees/<name>`), which are full checkouts of
# this same repository. Without skipping it, a lint run from the main checkout also reads
# every in-progress worktree -- so a mistyped citation or a not-yet-recorded hash in someone
# else's branch fails `just test` here, for a file that is not on this branch.
SKIP_DIRS = {".git", ".claude", "references"}


def is_skipped_dir(name: str) -> bool:
    """True for a directory name the lints never descend into."""
    return name in SKIP_DIRS or name.startswith(".build")


def swift_sources(root: Path) -> list[Path]:
    """Every Swift file under `root`, skipping vendored, build, and worktree trees.

    The walk prunes a skipped directory instead of filtering its files afterwards.
    That is the whole cost of this function: `.build` alone holds tens of thousands
    of Swift files, and reading their names to discard them took about 8 seconds per
    lint run.

    Pruning also states the skip rule correctly. The rule applies to directories
    *below `root`*, never to `root`'s own path components. Linting a checkout that
    itself lives under a skipped name -- which is exactly what an agent worktree at
    `.claude/worktrees/<name>` is -- must lint that checkout normally rather than
    skip every file in it and report a vacuous pass.

    Discovery is deliberately a walk and not `git ls-files`, which would be faster
    still: a new, not-yet-committed Swift file is the one whose citations most need
    checking, and a tracked-files listing cannot see it.
    """
    found: list[Path] = []
    for base, directories, files in os.walk(root, followlinks=False):
        directories[:] = [name for name in directories if not is_skipped_dir(name)]
        found.extend(Path(base) / name for name in files if name.endswith(".swift"))
    # A walk yields in arbitrary order, so sort the whole result: diagnostics are
    # reported in discovery order and must not depend on the filesystem.
    return sorted(found)
