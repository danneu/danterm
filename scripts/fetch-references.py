#!/usr/bin/env python3
"""Materialize external source references at reproducible pinned revisions.

Each checkout is staged and atomically swapped into `references/`, with sparse
cones used for large repositories. Pins and entry metadata are locked down by
scripts/tests/fetch_references_test.py so research can cite stable source.
"""

from __future__ import annotations

import argparse
from collections.abc import Callable, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
import json
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
REFERENCES_DIR = ROOT / "references"
CONE_RECORD = ".danterm-reference.json"


@dataclass(frozen=True)
class Reference:
    """Describes source whose exact commit and materialized subtree must be stable."""

    name: str
    url: str
    pin: str
    sparse_cone: tuple[str, ...]
    why: str
    release_tag: str | None

    def __post_init__(self) -> None:
        # A pin must be the COMMIT, not the annotated-tag object that
        # `git ls-remote --tags` prints -- both are 40 hex characters, so this
        # check cannot tell them apart. git resolves a tag object when fetching,
        # but the checkout's HEAD is the underlying commit, so a tag-object pin
        # fails `cache_is_current` forever and refetches on every run. Get the
        # peeled commit with:
        #     git ls-remote <url> 'refs/tags/<tag>^{}'
        if re.fullmatch(r"[0-9a-f]{40}", self.pin) is None:
            raise ValueError(f"{self.name}: pin must be a full lowercase commit SHA")


REFERENCES = [
    Reference(
        name="libvterm",
        url="https://github.com/neovim/libvterm.git",
        pin="934bc2fbf21800ac3458a499df8820ca5fb45fd3",
        sparse_cone=(),
        why="Parser, state, scrollback, and resize/reflow behavior for neutral fixtures.",
        release_tag=None,
    ),
    Reference(
        name="alacritty",
        url="https://github.com/alacritty/alacritty.git",
        pin="852e971cddfabe222d2d5bcda466e130f53af207",
        sparse_cone=("alacritty_terminal",),
        why="Terminal recordings and replay-runner cases for neutral fixtures.",
        release_tag=None,
    ),
    Reference(
        name="kitty",
        url="https://github.com/kovidgoyal/kitty.git",
        pin="2cb1d95c3accadd536bd66ba6bda044973440177",
        sparse_cone=("kitty", "shell-integration", "docs", "kitty_tests"),
        why="Graphics, keyboard, and shell-integration protocols kitty authored, next to the C parser that implements them and the suite that exercises it.",
        release_tag="v0.48.2",
    ),
    Reference(
        name="wezterm",
        url="https://github.com/wezterm/wezterm.git",
        pin="d69264df66fdcc928c7a30c673df108984fda821",
        sparse_cone=(
            "term",
            "termwiz",
            "vtparse",
            "wezterm-escape-parser",
            "wezterm-cell",
            "wezterm-surface",
            "pty",
        ),
        why="Escape-sequence parsing, cell/surface model, and reflow in a terminal engine split from its renderer, like DanTerm's.",
        release_tag=None,
    ),
    Reference(
        name="iterm2",
        url="https://github.com/gnachman/iTerm2.git",
        pin="a7438fdf49b06dcb7476497c51f45a63a14b8ad2",
        sparse_cone=("sources",),
        why="The macOS terminal DanTerm shares a platform with: AppKit surface, PTY, and the OSC 133/1337 dialects iTerm2 originated.",
        release_tag="v3.6.11",
    ),
    Reference(
        name="vte",
        url="https://gitlab.gnome.org/GNOME/vte.git",
        pin="5da1ed34b210f2b000ef954c147f9a1391da363b",
        sparse_cone=("src",),
        why="The most conformance-driven open terminal widget: sequence tables, ring buffer, and its own test corpus.",
        release_tag="0.84.0",
    ),
    Reference(
        name="foot",
        url="https://codeberg.org/dnkl/foot.git",
        pin="de998602dbc00c8862a6823d553cbb1df91c676d",
        sparse_cone=(),
        why="A small, fast C terminal whose grid, scrollback, and damage tracking are readable end to end.",
        release_tag="1.27.0",
    ),
    Reference(
        name="tmux",
        url="https://github.com/tmux/tmux.git",
        pin="e802909de06012a4df6209d55e86487c56223163",
        sparse_cone=(),
        why="Screen model, resize/reflow, and capability negotiation from the layer that both drives and emulates a terminal.",
        release_tag="3.7b",
    ),
    Reference(
        name="xterm",
        url="https://github.com/ThomasDickey/xterm-snapshots.git",
        pin="6380a3eaed857c182ea6cfa78cd706966b2628d0",
        sparse_cone=(),
        why="The de facto sequence specification (ctlseqs.ms) beside the implementation every other terminal is measured against.",
        release_tag="xterm-410",
    ),
    Reference(
        name="windows-terminal",
        url="https://github.com/microsoft/terminal.git",
        pin="1cea42d433253d95c4487a3037db48197b5e72f4",
        sparse_cone=("src/terminal", "src/buffer", "src/types", "doc"),
        why="A state-machine VT parser with an unusually complete conformance test suite, plus written specs for its edge cases.",
        release_tag="v1.25.1912.0",
    ),
    Reference(
        name="xnu",
        url="https://github.com/apple-oss-distributions/xnu.git",
        pin="ac9718fb1af618d5ce8678d0dc6e8a58f252216f",
        sparse_cone=("bsd/kern", "bsd/sys", "bsd/dev", "osfmk/kern", "osfmk/mach"),
        why="Darwin kernel process, signal, tty, and Mach behavior.",
        release_tag="xnu-12377.121.6",
    ),
    Reference(
        name="libdispatch",
        url="https://github.com/apple-oss-distributions/libdispatch.git",
        pin="701f4d1a24ae9c6863901bbbb22624b7d1b87321",
        sparse_cone=(),
        why="Dispatch queue, continuation, and work-item implementation details.",
        release_tag="libdispatch-1542.100.32",
    ),
    Reference(
        name="libpthread",
        url="https://github.com/apple-oss-distributions/libpthread.git",
        pin="1f4f5265b319111142f1bf3a27d4484ef5a98314",
        sparse_cone=(),
        why="Darwin pthread lifecycle, cancellation, and synchronization behavior.",
        release_tag="libpthread-539.100.4",
    ),
    Reference(
        name="libplatform",
        url="https://github.com/apple-oss-distributions/libplatform.git",
        pin="b7ed7cf5cf7dd12b98672435db2225a860f199d8",
        sparse_cone=(),
        why="Apple platform primitives used below dispatch and pthread.",
        release_tag="libplatform-375.120.2",
    ),
    Reference(
        name="Libc",
        url="https://github.com/apple-oss-distributions/Libc.git",
        pin="4e34d0559e3a1b081afeb8604d9e204a1f31321d",
        sparse_cone=(),
        why="Darwin C runtime, process, signal, and terminal interfaces.",
        release_tag="Libc-1752.120.2",
    ),
    Reference(
        name="objc4",
        url="https://github.com/apple-oss-distributions/objc4.git",
        pin="ebfe77e64331034c867285a95d3ac205203291d5",
        sparse_cone=(),
        why="Objective-C runtime ownership, teardown, and message dispatch behavior.",
        release_tag="objc4-951.7",
    ),
    Reference(
        name="fish-shell",
        url="https://github.com/fish-shell/fish-shell.git",
        pin="efb0223da10367031b7c887a3e40eccdf9bf7b06",
        sparse_cone=("share", "src"),
        why="Prompt repaint on SIGWINCH, fish_handle_reflow auto-detection, and the OSC 133 marks fish emits unprompted.",
        release_tag="4.7.1",
    ),
    Reference(
        name="zsh",
        url="https://github.com/zsh-users/zsh.git",
        pin="73d317384c9225e46d66444f93b46f0fbe7084ef",
        sparse_cone=("Src", "Functions"),
        why="Prompt redisplay and expansion behavior the shell-integration dialect embeds marks into.",
        release_tag="zsh-5.9",
    ),
    Reference(
        name="bash",
        url="https://git.savannah.gnu.org/git/bash.git",
        pin="b8c60bc9ca365f8261fa97900b6fa939f6ebc303",
        sparse_cone=("lib/readline",),
        why="Readline redisplay after SIGWINCH, which decides how much of a Bash prompt may be blanked.",
        release_tag="bash-5.3",
    ),
]


def run_git(
    *arguments: str,
    capture_output: bool = False,
) -> subprocess.CompletedProcess[str]:
    """Runs git with file URLs enabled so local fixtures exercise the real fetch path."""
    return subprocess.run(
        ["git", "-c", "protocol.file.allow=always", *arguments],
        check=True,
        text=True,
        capture_output=capture_output,
    )


def recorded_cone(checkout: Path) -> tuple[str, ...] | None:
    """Reads only records written by this script; handmade checkouts are never adopted."""
    try:
        record = json.loads((checkout / CONE_RECORD).read_text())
    except (OSError, json.JSONDecodeError):
        return None
    cone = record.get("sparseCone")
    if not isinstance(cone, list) or not all(isinstance(path, str) for path in cone):
        return None
    return tuple(cone)


def resolved_head(checkout: Path) -> str | None:
    """Returns the checkout's commit without trusting tags or descriptive metadata."""
    try:
        result = run_git(
            "-C",
            str(checkout),
            "rev-parse",
            "HEAD^{commit}",
            capture_output=True,
        )
    except subprocess.CalledProcessError:
        return None
    return result.stdout.strip()


def cache_is_current(checkout: Path, reference: Reference) -> bool:
    """Accepts a cache only when both its resolved commit and recorded cone match."""
    return (
        checkout.is_dir()
        and recorded_cone(checkout) == reference.sparse_cone
        and resolved_head(checkout) == reference.pin
    )


def populate_checkout(reference: Reference, checkout: Path) -> None:
    """Fetches one pinned commit without allowing a branch or tag to choose the result."""
    run_git("init", "-q", str(checkout))
    run_git("-C", str(checkout), "remote", "add", "origin", reference.url)
    run_git(
        "-C",
        str(checkout),
        "fetch",
        "--quiet",
        "--depth",
        "1",
        "--filter=blob:none",
        "origin",
        reference.pin,
    )
    if reference.sparse_cone:
        run_git("-C", str(checkout), "sparse-checkout", "init", "--cone")
        run_git(
            "-C",
            str(checkout),
            "sparse-checkout",
            "set",
            *reference.sparse_cone,
        )
    run_git(
        "-C",
        str(checkout),
        "-c",
        "advice.detachedHead=false",
        "checkout",
        "--quiet",
        "--detach",
        "FETCH_HEAD",
    )
    (checkout / CONE_RECORD).write_text(
        json.dumps({"sparseCone": list(reference.sparse_cone)}, indent=2) + "\n"
    )


@contextmanager
def defer_sigint():
    """Defers Ctrl-C across the two-rename swap window so a target always exists."""
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT})
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def swap_reference(
    staged: Path,
    target: Path,
    *,
    between_renames: Callable[[], None] | None = None,
) -> None:
    """Replaces one reference while restoring its prior complete tree on swap failure."""
    backup = target.parent / f".{target.name}.backup"
    if not target.exists() and backup.exists():
        backup.rename(target)
    if backup.exists():
        shutil.rmtree(backup)

    with defer_sigint():
        if target.exists():
            target.rename(backup)
        try:
            if between_renames is not None:
                between_renames()
            staged.rename(target)
        except BaseException:
            if not target.exists() and backup.exists():
                backup.rename(target)
            raise

    if backup.exists():
        shutil.rmtree(backup)


def fetch_reference(
    reference: Reference,
    *,
    references_dir: Path = REFERENCES_DIR,
    force: bool = False,
) -> None:
    """Materializes one entry without disturbing a valid tree until fetching succeeds."""
    target = references_dir / reference.name
    if not force and cache_is_current(target, reference):
        print(f"{reference.name}: skipped (already at {reference.pin})")
        return

    references_dir.mkdir(parents=True, exist_ok=True)
    print(f"{reference.name}: fetching {reference.pin}")
    with tempfile.TemporaryDirectory(
        dir=references_dir,
        prefix=f".{reference.name}.staging-",
    ) as temporary_directory:
        staged = Path(temporary_directory) / reference.name
        populate_checkout(reference, staged)
        swap_reference(staged, target)


def selected_references(
    names: Sequence[str],
    *,
    manifest: Sequence[Reference],
) -> list[Reference]:
    """Validates positional filters and preserves manifest order for reproducible output."""
    entries_by_name = {entry.name: entry for entry in manifest}
    unknown = sorted(set(names) - entries_by_name.keys())
    if unknown:
        valid = ", ".join(entry.name for entry in manifest)
        quoted = ", ".join(repr(name) for name in unknown)
        raise ValueError(f"unknown reference {quoted}; valid names: {valid}")
    requested = set(names)
    return [entry for entry in manifest if not requested or entry.name in requested]


def main(
    argv: Sequence[str] | None = None,
    *,
    manifest: Sequence[Reference] = REFERENCES,
    references_dir: Path = REFERENCES_DIR,
) -> int:
    """Implements the command-line contract while keeping fixtures injectable."""
    parser = argparse.ArgumentParser(
        description="Fetch external source references at pinned commits."
    )
    parser.add_argument("names", nargs="*", help="references to fetch (default: all)")
    parser.add_argument("--list", action="store_true", help="list references and exit")
    parser.add_argument(
        "--force",
        action="store_true",
        help="replace checkouts even when their commit and sparse cone match",
    )
    arguments = parser.parse_args(argv)

    if arguments.list:
        for entry in manifest:
            release = f", release {entry.release_tag}" if entry.release_tag else ""
            print(f"{entry.name}: {entry.why} ({entry.pin}{release})")
        return 0

    try:
        selected = selected_references(arguments.names, manifest=manifest)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    for entry in selected:
        fetch_reference(entry, references_dir=references_dir, force=arguments.force)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        raise SystemExit(130)
