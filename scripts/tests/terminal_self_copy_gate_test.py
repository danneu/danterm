#!/usr/bin/env python3
"""Self-test for the whole-`Terminal` copy gate.

The gate's verdict is a property of one disassembly and two copy lengths, so every
case here feeds it a fixture through its `--disassembly` seam. What the fixtures
cannot prove -- that the gate reads a real release object and a real mangled symbol --
is proved by running the gate itself, which the tooling suite does.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "terminal-self-copy-gate.py"

SIZE = 1513
STRIDE = 1520


def function(symbol: str, body: str) -> str:
    """Renders one objdump function block, in the shape llvm-objdump prints."""
    return f"0000000000000000 <{symbol}>:\n{body}\n"


CLEAN_BODY = """\
       0: d10143ff    \tsub\tsp, sp, #80
       4: 52800f02    \tmov\tw2, #0x78
       8: 94000000    \tbl\t0x8 <_memcpy>
       c: d65f03c0    \tret
"""

COPY_BODY = """\
       0: d10143ff    \tsub\tsp, sp, #80
     188: 52800042    \tmov\tw2, #0x5e9
     18c: 94000000    \tbl\t0x18c <_memcpy>
     190: d65f03c0    \tret
"""

RELOCATED_COPY_BODY = """\
       0: d10143ff    \tsub\tsp, sp, #80
     188: 52800042    \tmov\tw2, #0x5e9
     18c: 94000000    \tbl\t0x18c <TerminalCore.Terminal.apply+0x18c>
\t\t000000000000018c:  ARM64_RELOC_BRANCH26\t_memcpy
     190: d65f03c0    \tret
"""

MOVE_BODY = """\
       0: d10143ff    \tsub\tsp, sp, #80
     188: 52800bc2    \tmov\tw2, #0x5f0
     18c: 94000000    \tbl\t0x18c <_memmove>
     190: d65f03c0    \tret
"""

APPLY = "TerminalCore.Terminal.apply(_: TerminalAction) -> ()"
# The same function as the release object names it. Every feed-path function is
# `private`, so its symbol carries a file discriminator and demangles with the base name
# in parentheses -- a shape a fixture written in source terms does not exercise, and the
# one the gate first read wrong.
MANGLED_APPLY = (
    "_$s12TerminalCore0A0V5apply33_0C0D8590BE6EC2CCF5892DACD17C1D1DLL_2in4from6before"
    "yAA0A12StreamActionO_SRys5UInt8VGAA0A14StretchScratchVAC06DamageP8SnapshotAELLVztF"
)
FEED_BUFFER = "TerminalCore.Terminal.feedBuffer(_: Swift.UnsafeBufferPointer<Swift.UInt8>) -> ()"
EXECUTE = "TerminalCore.Terminal.execute(_: Swift.UInt8) -> ()"
RECOVER = "TerminalCore.Terminal.recoverClusterContextFromGridIfNeeded() -> Swift.Bool"
PRINT_STRETCH = "TerminalCore.Terminal.printTextStretch(_: Swift.Int) -> ()"
RECORD_DAMAGE = "TerminalCore.Terminal.recordDamage(from: Swift.Int, to: Swift.Int) -> ()"


def object_text(*blocks: str) -> str:
    """Renders a whole fixture object, header included."""
    return (
        "fixture.o:\tfile format mach-o arm64\n\nDisassembly of section __TEXT,__text:\n\n"
        + "\n".join(blocks)
    )


def whole_object(extra: str = "") -> str:
    """Every required feed-path function, clean, plus whatever the case adds."""
    return object_text(
        function(APPLY, CLEAN_BODY),
        function(FEED_BUFFER, CLEAN_BODY),
        function(EXECUTE, CLEAN_BODY),
        function(RECOVER, CLEAN_BODY),
        function(PRINT_STRETCH, CLEAN_BODY),
        *( [extra] if extra else [] ),
    )


def run(disassembly: str) -> subprocess.CompletedProcess[str]:
    """Runs the gate against one fixture disassembly."""
    with tempfile.TemporaryDirectory(prefix="terminal-self-copy-gate-test-") as directory:
        path = pathlib.Path(directory) / "fixture.txt"
        path.write_text(disassembly, encoding="utf-8")
        return subprocess.run(
            [
                sys.executable,
                str(GATE),
                "--disassembly",
                str(path),
                "--size",
                str(SIZE),
                "--stride",
                str(STRIDE),
            ],
            capture_output=True,
            text=True,
            check=False,
        )


def expect(condition: bool, message: str) -> None:
    """Reports one failed expectation and stops."""
    if not condition:
        print(f"terminal_self_copy_gate_test: {message}", file=sys.stderr)
        sys.exit(1)


def main() -> int:
    """Runs every case and prints one line when they all hold."""
    clean = run(whole_object())
    expect(clean.returncode == 0, f"a clean feed path failed: {clean.stderr}")

    for name, body in (("direct", COPY_BODY), ("relocated", RELOCATED_COPY_BODY)):
        regression = run(
            object_text(
                function(APPLY, body),
                function(FEED_BUFFER, CLEAN_BODY),
                function(EXECUTE, CLEAN_BODY),
                function(RECOVER, CLEAN_BODY),
                function(PRINT_STRETCH, CLEAN_BODY),
            )
        )
        expect(regression.returncode == 1, f"a {name} whole-value copy in apply passed")
        expect(
            "apply" in regression.stderr and str(SIZE) in regression.stderr,
            f"the {name} failure did not name the site: {regression.stderr}",
        )

    stride = run(
        object_text(
            function(APPLY, CLEAN_BODY),
            function(FEED_BUFFER, CLEAN_BODY),
            function(EXECUTE, CLEAN_BODY),
            function(RECOVER, CLEAN_BODY),
            function(PRINT_STRETCH, MOVE_BODY),
        )
    )
    expect(stride.returncode == 1, "a stride-length memmove in a print function passed")
    expect(
        "printTextStretch" in stride.stderr,
        f"the stride failure did not name the site: {stride.stderr}",
    )

    mangled = run(
        object_text(
            function(MANGLED_APPLY, COPY_BODY),
            function(FEED_BUFFER, CLEAN_BODY),
            function(EXECUTE, CLEAN_BODY),
            function(RECOVER, CLEAN_BODY),
            function(PRINT_STRETCH, CLEAN_BODY),
        )
    )
    expect(mangled.returncode == 1, "a whole-value copy under a mangled private symbol passed")
    expect(
        "apply" in mangled.stderr,
        f"the mangled failure did not name the site: {mangled.stderr}",
    )

    guarded = run(whole_object(function(RECORD_DAMAGE, COPY_BODY)))
    expect(
        guarded.returncode == 0,
        f"a copy in a guarded function outside the feed path failed: {guarded.stderr}",
    )

    vacuous = run(object_text(function(PRINT_STRETCH, CLEAN_BODY)))
    expect(vacuous.returncode == 1, "an object holding no feed-path root passed")
    expect(
        "apply" in vacuous.stderr and "feedBuffer" in vacuous.stderr,
        f"the vacuity failure did not name the missing roots: {vacuous.stderr}",
    )

    empty = run("fixture.o:\tfile format mach-o arm64\n")
    expect(empty.returncode == 1, "an object with no functions passed")

    print("terminal self-copy gate tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
