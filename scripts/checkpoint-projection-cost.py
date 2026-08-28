#!/usr/bin/env python3
"""Build and run the optimized light-checkpoint projection cost probe.

`--check` compiles the probe and stops, which is what the gate runs. The probe cannot be
an ordinary SwiftPM target: DanTermCore declares nothing `public`, because it compiles
same-module into the app, so the only way to reach `AppModel` is to compile the probe
together with those sources -- which is what this script does and what a package manifest
cannot express. Without `--check` in the gate, the probe is a Swift file no compiler reads
until someone runs the benchmark by hand, and it has already gone stale that way once.
"""

import argparse
import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROBE = ROOT / "scripts" / "checkpoint-projection-cost-probe.swift"
CORE_SOURCES = ROOT / "lib" / "DanTermCore" / "Sources" / "DanTermCore"
PROTOCOL_SOURCES = ROOT / "lib" / "DanTermProtocol" / "Sources" / "DanTermProtocol"


def main() -> int:
    """Compile with the declared production configuration, then run the fixed probe."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="type-check the probe against DanTermCore and exit without measuring",
    )
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="checkpoint-projection-cost-") as directory:
        scratch = pathlib.Path(directory)
        main_source = scratch / "main.swift"
        # Keep the live probe free of first-party imports so the scripts orphan lint
        # can distinguish its same-module exception. The driver supplies the protocol
        # dependency to the temporary compilation unit that it already owns.
        main_source.write_bytes(b"import DanTermProtocol\n" + PROBE.read_bytes())
        protocol_library = scratch / "libDanTermProtocol.dylib"
        subprocess.run(
            [
                "swiftc",
                "-O",
                "-whole-module-optimization",
                "-swift-version",
                "5",
                "-emit-library",
                "-emit-module",
                "-module-name",
                "DanTermProtocol",
                "-o",
                str(protocol_library),
                *(str(path) for path in sorted(PROTOCOL_SOURCES.glob("*.swift"))),
            ],
            check=True,
        )
        binary = scratch / "checkpoint-projection-cost"
        # -typecheck skips optimization and linking, so a gate run costs a fraction of a
        # measurement run. It still catches the whole failure this mode exists for: every
        # way the probe has broken is an API change in DanTermCore, and those are the same
        # errors at every optimization level.
        shape = (
            ["-typecheck"]
            if arguments.check
            else [
                "-O",
                "-whole-module-optimization",
                "-L",
                str(scratch),
                "-lDanTermProtocol",
                "-Xlinker",
                "-rpath",
                "-Xlinker",
                str(scratch),
                "-o",
                str(binary),
            ]
        )
        subprocess.run(
            [
                "swiftc",
                "-swift-version",
                "5",
                "-D",
                "CHECKPOINT_PROJECTION_RELEASE_PROBE",
                "-I",
                str(scratch),
                *shape,
                str(main_source),
                *(str(path) for path in sorted(CORE_SOURCES.glob("*.swift"))),
            ],
            check=True,
        )
        if arguments.check:
            print("checkpoint-projection-cost: probe type-checks against DanTermCore")
            return 0
        return subprocess.run([str(binary)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
