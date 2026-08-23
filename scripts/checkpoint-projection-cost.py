#!/usr/bin/env python3
"""Build and run the optimized light-checkpoint projection cost probe."""

import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROBE = ROOT / "scripts" / "checkpoint-projection-cost-probe.swift"
CORE_SOURCES = ROOT / "lib" / "DanTermCore" / "Sources" / "DanTermCore"
PROTOCOL_SOURCES = ROOT / "lib" / "DanTermProtocol" / "Sources" / "DanTermProtocol"


def main() -> int:
    """Compile with the declared production configuration, then run the fixed probe."""
    with tempfile.TemporaryDirectory(prefix="checkpoint-projection-cost-") as directory:
        scratch = pathlib.Path(directory)
        main_source = scratch / "main.swift"
        main_source.write_bytes(PROBE.read_bytes())
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
        subprocess.run(
            [
                "swiftc",
                "-O",
                "-whole-module-optimization",
                "-swift-version",
                "5",
                "-D",
                "CHECKPOINT_PROJECTION_RELEASE_PROBE",
                "-I",
                str(scratch),
                "-L",
                str(scratch),
                "-lDanTermProtocol",
                "-Xlinker",
                "-rpath",
                "-Xlinker",
                str(scratch),
                "-o",
                str(binary),
                str(main_source),
                *(str(path) for path in sorted(CORE_SOURCES.glob("*.swift"))),
            ],
            check=True,
        )
        return subprocess.run([str(binary)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
