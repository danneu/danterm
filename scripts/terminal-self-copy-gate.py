#!/usr/bin/env python3
"""Fails when a feed-path function copies a whole `Terminal` value in the release object.

This is `research/39/D5`'s guard (c). Inside a `mutating` method `self` is an `inout`
access, so calling a non-inlined non-mutating member of `Terminal` on it makes the
compiler materialize the whole value into a stack temporary first -- a `memcpy` of
`MemoryLayout<Terminal>.size` bytes, once per parser action at the site `F2` found
(`mov w2, #0x5e9; bl _memcpy` at `apply+392`). `D5` removed the two unconditional
sites and recorded, but did not build, the structure that makes the mechanism
impossible (a pointer-wide `Terminal` over one copy-on-write box). This gate is what
stands in for that structure: it cannot prevent a new site, only report it.

The gate reads both the copy length and the object from the built product, so nothing
here is hard-coded to the 1513 bytes of the day it was written: it builds the release
`TerminalCore`, asks the built module for `MemoryLayout<Terminal>.size` and `.stride`
(a whole-value copy lowers to either), and disassembles `Terminal.swift.o`.

It lives in `just test-tooling` rather than `just test` because it needs a release
build. The benchmark ladder catches the same regression at the next run; this catches
it without one.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE_PACKAGE = ROOT / "lib" / "TerminalCore"

# The functions whose disassembly is read. They are the feed path as `D5` names it:
# `feedBuffer` is the entry every `feed` overload funnels into, `apply` ends every
# parser action with the damage snapshot, `execute` handles the C0 controls the arms
# send, `recoverClusterContextFromGridIfNeeded` runs once per print, and the `print*`
# family is every writer a printable byte reaches (`printTextStretch` and
# `printJoinSegment` among them). Each one runs unconditionally per action, per print,
# or per stretch, so a whole-value copy inside one is paid on every byte fed.
#
# Deliberately not here: the guarded sites `D5` classifies as cold -- `recordDamage`'s
# `damagedViewportRows(for:)` calls (only when the selection or the hovered link
# changed) and `appendToOpenClusterIfJoined`'s `clusterTargetCanChangeWidth` (only when
# a combining mark could change a cluster's width). They share the mechanism, not the
# profile; `D5` names the storage box as their answer if one ever profiles. Also not
# here: `TerminalPTYHost.takeOutputTurn`, which lives in another module and so is not in
# this object at all.
FEED_PATH_NAMES = frozenset(
    {
        "feedBuffer",
        "apply",
        "execute",
        "recoverClusterContextFromGridIfNeeded",
    }
)
FEED_PATH_PREFIXES = ("print",)

# I6: the gate must not pass because it looked at nothing. Each of these has to be
# found in the object, or the run fails instead of reporting a clean feed path.
REQUIRED_NAMES = (
    "feedBuffer",
    "apply",
    "execute",
    "recoverClusterContextFromGridIfNeeded",
)

COPY_CALLEES = ("memcpy", "memmove")

SIZE_PROBE_PRODUCT = "TerminalValueLayoutProbe"


class GateError(Exception):
    """A condition that stops the gate from reaching a verdict, reported as a failure."""


def build_release(scratch: pathlib.Path) -> pathlib.Path:
    """Builds the release layout probe, which drags in the `TerminalCore` object the gate reads."""
    subprocess.run(
        [
            "swift",
            "build",
            "-c",
            "release",
            "--package-path",
            str(CORE_PACKAGE),
            "--scratch-path",
            str(scratch),
            "--product",
            SIZE_PROBE_PRODUCT,
        ],
        check=True,
        cwd=ROOT,
    )
    return scratch


def find_object(scratch: pathlib.Path) -> pathlib.Path:
    """Returns the release `Terminal.swift.o` the build wrote, or fails loudly."""
    candidates = sorted(scratch.glob("**/TerminalCore.build/Terminal.swift.o"))
    if not candidates:
        raise GateError(
            f"no release Terminal.swift.o under {scratch}; the gate has nothing to read"
        )
    return candidates[0]


def read_copy_lengths(scratch: pathlib.Path) -> tuple[int, int]:
    """Asks the built release product for the two lengths a whole-value copy can carry."""
    probe = scratch / "release" / SIZE_PROBE_PRODUCT
    if not probe.is_file():
        raise GateError(f"the release build wrote no {SIZE_PROBE_PRODUCT} at {probe}")
    output = subprocess.run([str(probe)], check=True, capture_output=True, text=True).stdout
    match = re.search(r"size (\d+) stride (\d+)", output)
    if match is None:
        raise GateError(f"the size probe printed no lengths: {output!r}")
    return int(match.group(1)), int(match.group(2))


def disassemble(object_path: pathlib.Path) -> str:
    """Returns the object's disassembly with relocations, so call targets carry names."""
    tool = shutil.which("objdump") or "objdump"
    return subprocess.run(
        [tool, "-d", "-r", str(object_path)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def demangle(symbols: list[str]) -> dict[str, str]:
    """Maps each mangled symbol to its Swift name, so the scope list can be written in source terms."""
    if not symbols:
        return {}
    result = subprocess.run(
        ["xcrun", "swift-demangle", "-compact"],
        input="\n".join(symbols),
        check=True,
        capture_output=True,
        text=True,
    )
    demangled = result.stdout.splitlines()
    if len(demangled) != len(symbols):
        raise GateError("swift-demangle returned a different number of names than it was given")
    return dict(zip(symbols, demangled))


SYMBOL_LINE = re.compile(r"^[0-9a-f]+ <(.+)>:$")
INSTRUCTION_LINE = re.compile(r"^\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )*[0-9a-f]{8}\s+(.*)$")
MOVE_IMMEDIATE = re.compile(r"^mov\s+([wx])2,\s+#(?:0x([0-9a-f]+)|(\d+))")
BRANCH_LINK = re.compile(r"^bl\s+")
RELOCATION = re.compile(r"ARM64_RELOC_BRANCH26\s+(\S+)")
SYMBOL_IN_CALL = re.compile(r"<([^>]+)>")


def function_bodies(disassembly: str) -> list[tuple[str, list[str]]]:
    """Splits a disassembly into (symbol, lines) pairs, one per function label."""
    bodies: list[tuple[str, list[str]]] = []
    current: list[str] | None = None
    for line in disassembly.splitlines():
        label = SYMBOL_LINE.match(line.strip())
        if label is not None:
            current = []
            bodies.append((label.group(1), current))
        elif current is not None:
            current.append(line)
    return bodies


def swift_names(demangled: str) -> set[str]:
    """Returns every `Terminal` member named in a demangled symbol, specializations included.

    A `private` member demangles with its file discriminator in parentheses --
    `TerminalCore.Terminal.(apply in _0C0D...)` -- and every function on the feed path is
    private, so the open paren is part of the name shape rather than an edge case.
    """
    return set(re.findall(r"\bTerminal\.\(?(\w+)", demangled))


def in_scope(names: set[str]) -> bool:
    """Answers whether a symbol names any feed-path function this gate reads."""
    return any(
        name in FEED_PATH_NAMES or name.startswith(FEED_PATH_PREFIXES) for name in names
    )


def whole_value_copies(lines: list[str], lengths: set[int]) -> list[tuple[str, int, str]]:
    """Finds every `memcpy`/`memmove` call in one function whose length register holds a copy length."""
    found: list[tuple[str, int, str]] = []
    pending_length: int | None = None
    pending_call: tuple[str, int] | None = None
    for line in lines:
        relocation = RELOCATION.search(line)
        if relocation is not None and pending_call is not None:
            callee = relocation.group(1).lstrip("_")
            if any(name in callee for name in COPY_CALLEES):
                found.append((pending_call[0], pending_call[1], callee))
            pending_call = None
            continue
        instruction = INSTRUCTION_LINE.match(line)
        if instruction is None:
            continue
        offset, text = instruction.group(1), instruction.group(2).strip()
        pending_call = None
        move = MOVE_IMMEDIATE.match(text)
        if move is not None:
            digits = move.group(2)
            pending_length = int(digits, 16) if digits is not None else int(move.group(3))
            continue
        if BRANCH_LINK.match(text) is None:
            continue
        if pending_length not in lengths:
            continue
        symbol = SYMBOL_IN_CALL.search(text)
        callee = symbol.group(1).lstrip("_") if symbol is not None else ""
        if any(name in callee for name in COPY_CALLEES):
            found.append((offset, pending_length, callee))
        else:
            # A call the disassembly names only through the relocation on the next
            # line, or names as an offset into the enclosing symbol. Hold it until
            # that line is read.
            pending_call = (offset, pending_length)
    return found


def report(object_path: pathlib.Path, disassembly: str, size: int, stride: int) -> int:
    """Prints the verdict for one object and returns the process status."""
    lengths = {size, stride}
    bodies = function_bodies(disassembly)
    if not bodies:
        raise GateError(f"{object_path} disassembled to no functions; the gate read nothing")
    mapping = demangle([symbol for symbol, _ in bodies])
    seen: set[str] = set()
    failures: list[str] = []
    scanned = 0
    for symbol, lines in bodies:
        names = swift_names(mapping[symbol])
        seen |= names
        if not in_scope(names):
            continue
        scanned += 1
        for offset, length, callee in whole_value_copies(lines, lengths):
            failures.append(f"  {mapping[symbol]}+0x{offset}: {callee} of {length} bytes")
    missing = [name for name in REQUIRED_NAMES if name not in seen]
    if missing:
        raise GateError(
            "the release object holds none of these feed-path functions: "
            + ", ".join(missing)
            + ". The gate cannot pass on an object it did not read; check the build "
            "and the names in FEED_PATH_NAMES."
        )
    if failures:
        print(
            f"terminal-self-copy-gate: a whole-`Terminal` copy is back on the feed path "
            f"({size}-byte size, {stride}-byte stride):",
            file=sys.stderr,
        )
        print("\n".join(failures), file=sys.stderr)
        print(
            "\nInside a mutating method, calling a non-inlined non-mutating member of\n"
            "`Terminal` on `inout self` copies the whole value first. Read the state from\n"
            "its inputs, or on the screen sub-value, instead of through a member call on\n"
            "`self`. research/39/D5 and F2 have the mechanism and the two sites it removed.",
            file=sys.stderr,
        )
        return 1
    print(
        f"terminal-self-copy-gate: no {size}/{stride}-byte copy in {scanned} feed-path "
        f"functions of {object_path.name}"
    )
    return 0


def main() -> int:
    """Builds or reads the release object and reports whether the feed path copies a terminal."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--scratch-path",
        type=pathlib.Path,
        help="SwiftPM scratch path for the release build",
    )
    # Test seams. The self-test feeds a fixture disassembly and the lengths it was
    # written against, so the parser's verdicts are provable without a release build.
    parser.add_argument("--disassembly", type=pathlib.Path, help=argparse.SUPPRESS)
    parser.add_argument("--size", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--stride", type=int, help=argparse.SUPPRESS)
    arguments = parser.parse_args()

    try:
        if arguments.disassembly is not None:
            if arguments.size is None or arguments.stride is None:
                raise GateError("--disassembly needs --size and --stride")
            return report(
                arguments.disassembly,
                arguments.disassembly.read_text(encoding="utf-8"),
                arguments.size,
                arguments.stride,
            )
        if arguments.scratch_path is None:
            raise GateError("--scratch-path is required outside the test seam")
        scratch = build_release(arguments.scratch_path)
        size, stride = read_copy_lengths(scratch)
        object_path = find_object(scratch)
        return report(object_path, disassemble(object_path), size, stride)
    except GateError as error:
        print(f"terminal-self-copy-gate: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
