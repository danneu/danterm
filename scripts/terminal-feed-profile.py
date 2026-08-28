#!/usr/bin/env python3
"""Attach `sample` to a sustained headless `Terminal.feed` loop for one corpus workload.

The GUI profiler (`scripts/terminal-benchmark-profile.sh`) captures whole-app
trees in which feed shares the process with planning, drawing, AppKit, and the
PTY source, and it needs a window server to run at all. Feed research wants the
opposite: one thread doing nothing but parsing bytes into a `Terminal`, with no
draw path to attribute against and no display dependency, so a call tree can be
read as a straight breakdown of feed itself.

That harness already exists -- `TerminalCoreBenchmark --profile` loops
`measureFeedBatch` forever -- but the paired comparison runner only ever invokes
its measurement modes, so nothing drives the profiling mode. This is that driver.

Scope boundary: this produces attribution, never a verdict. It builds from the
operator's working tree on purpose, because its job is to show where feed time
goes while code is being changed. Directional performance claims still belong to
`terminal-benchmark-compare.py`, which builds both arms from immutable trees.
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from terminal_benchmark_fixtures import frame_chunks, iter_bytes, load_corpus

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGE_PATH = REPO_ROOT / "lib" / "TerminalCore"
PRODUCT = "TerminalCoreBenchmark"
# Long enough for the loop to reach steady state (the first cycle pays terminal
# construction and page faults) and short enough not to pad every capture.
WARMUP_SECONDS = 2.0


def framed_fixture(workloads):
    """Frame chosen workloads as the length-prefixed stream the Swift harness decodes."""
    framed = bytearray()
    for workload in workloads:
        framed.extend(frame_chunks(iter_bytes(REPO_ROOT, workload)))
    return bytes(framed)


def build_harness():
    """Compile release so the tree reflects optimized code, not -Onone artifacts."""
    subprocess.run(
        [
            "swift", "build",
            "--package-path", str(PACKAGE_PATH),
            "--configuration", "release",
            "--product", PRODUCT,
        ],
        check=True,
        stdout=sys.stderr.fileno(),
    )
    binary_path = subprocess.run(
        [
            "swift", "build",
            "--package-path", str(PACKAGE_PATH),
            "--configuration", "release",
            "--show-bin-path",
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return pathlib.Path(binary_path) / PRODUCT


def worktree_identity(names):
    """Record what was measured, since this harness deliberately builds a dirty tree."""
    def git(*arguments):
        return subprocess.run(
            ["git", *arguments], cwd=str(REPO_ROOT), capture_output=True, text=True
        ).stdout.strip()

    corpus = load_corpus(REPO_ROOT)
    return {
        "schemaVersion": 1,
        "harness": "terminal-feed-profile",
        "product": PRODUCT,
        "configuration": "release",
        "workloads": [
            {"name": name, "identity": corpus[name]["identity"]} for name in names
        ],
        "commit": git("rev-parse", "HEAD"),
        "isWorkingTreeDirty": bool(git("status", "--porcelain")),
        "attributionOnly": (
            "sample shares are attribution, not timings; a directional claim "
            "requires terminal-benchmark-compare.py against a named baseline"
        ),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    corpus = load_corpus(REPO_ROOT)
    parser.add_argument(
        "workload",
        nargs="?",
        default="styled-screen-redraw",
        choices=[*corpus.keys(), "all"],
        help="corpus workload to replay, or 'all' for the full four-stream fixture",
    )
    parser.add_argument("--seconds", type=int, default=20)
    arguments = parser.parse_args()
    if arguments.seconds < 1:
        parser.error("profiling duration must be a whole number of seconds")

    names = list(corpus.keys()) if arguments.workload == "all" else [arguments.workload]
    fixture = framed_fixture([corpus[name] for name in names])
    binary = build_harness()

    profile_root = REPO_ROOT / ".build" / "terminal-feed-profiles" / time.strftime("%Y-%m-%d-%H%M%S")
    profile_root.mkdir(parents=True, exist_ok=True)
    (profile_root / "identity.json").write_text(
        json.dumps(worktree_identity(names), indent=2) + "\n", encoding="utf-8"
    )

    fixture_path = profile_root / "fixture.bin"
    fixture_path.write_bytes(fixture)
    sample_path = profile_root / "sample.txt"

    with open(fixture_path, "rb") as fixture_handle:
        harness = subprocess.Popen(
            [str(binary), "--profile"],
            stdin=fixture_handle,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
    try:
        time.sleep(WARMUP_SECONDS)
        if harness.poll() is not None:
            raise SystemExit(
                f"feed harness exited early: {harness.stderr.read().decode(errors='replace')}"
            )
        subprocess.run(
            ["sample", str(harness.pid), str(arguments.seconds), "-f", str(sample_path)],
            check=True,
            stdout=sys.stderr.fileno(),
        )
    finally:
        harness.terminate()
        harness.wait()
        # The fixture is reproducible from the corpus and is the bulk of the
        # artifact's size, so keep the directory to the parts worth reading.
        os.unlink(fixture_path)

    print(f"workloads: {', '.join(names)}")
    print(f"profile:   {sample_path}")
    print(f"identity:  {profile_root / 'identity.json'}")
    # The child writes to this stdout directly, so flush first or its summary
    # lands above the paths printed here.
    sys.stdout.flush()
    # `sample`'s call graph is written for a human reader; the report beside it is
    # the form a caller can aggregate without re-parsing an indented tree.
    subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "terminal-profile-report.py"), str(sample_path)],
        check=True,
    )


if __name__ == "__main__":
    main()
