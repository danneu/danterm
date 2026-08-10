#!/usr/bin/env python3
"""Research doc 33, task T9: interleaved headless drain A/B between two built arms.

`benchmark-quick`'s drain bracket runs inside a GUI process where the main
thread plans and draws against the feed concurrently, and F17 recorded that it
returns disagreeing signs on drain-sized effects inside blocks that are mostly
not drain. This is the adjudicating instrument that precedent names: the same
`TerminalCoreBenchmark` duration-stable feed measurement, one arm built from
the baseline tree and one from the working tree, run strictly interleaved
(A B A B ...) on an otherwise idle machine so drift hits both arms equally.

Usage:
  scripts/research/33/t9-headless-drain-ab.py \
      --baseline <path to baseline TerminalCoreBenchmark> [--rounds N] [--workload W]

The working-tree arm is built (release) if missing. Reports per-round medians
and the paired median delta. Attribution only under contention; a verdict here
needs the idle machine every timing rule in this repo assumes.
"""
import argparse
import json
import pathlib
import statistics
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

from terminal_benchmark_fixtures import iter_bytes, load_corpus  # noqa: E402

CANDIDATE = ROOT / "lib" / "TerminalCore" / ".build" / "release" / "TerminalCoreBenchmark"


def framed_chunks(workload_name):
    workload = load_corpus(ROOT)[workload_name]
    framed = bytearray()
    for chunk in iter_bytes(ROOT, workload):
        framed.extend(len(chunk).to_bytes(8, byteorder="big"))
        framed.extend(chunk)
    return bytes(framed)


def run_arm(binary, fixture, iterations):
    result = subprocess.run(
        [str(binary), str(iterations)],
        input=fixture,
        capture_output=True,
        check=True,
    )
    payload = json.loads(result.stdout)
    return statistics.median(payload["feedDurationNanoseconds"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=pathlib.Path)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--workload", default="scrollback-stream")
    arguments = parser.parse_args()

    if not CANDIDATE.exists():
        subprocess.run(
            [
                "swift", "build",
                "--package-path", str(ROOT / "lib" / "TerminalCore"),
                "--configuration", "release",
                "--product", "TerminalCoreBenchmark",
            ],
            check=True,
        )
    fixture = framed_chunks(arguments.workload)

    baseline_medians = []
    candidate_medians = []
    for round_index in range(arguments.rounds):
        baseline = run_arm(arguments.baseline, fixture, arguments.iterations)
        candidate = run_arm(CANDIDATE, fixture, arguments.iterations)
        baseline_medians.append(baseline)
        candidate_medians.append(candidate)
        print(
            f"round {round_index}: baseline {baseline / 1e6:.2f} ms, "
            f"candidate {candidate / 1e6:.2f} ms, "
            f"delta {(candidate - baseline) / baseline * 100:+.2f}%"
        )

    baseline_median = statistics.median(baseline_medians)
    candidate_median = statistics.median(candidate_medians)
    print(
        f"medians: baseline {baseline_median / 1e6:.2f} ms, "
        f"candidate {candidate_median / 1e6:.2f} ms, "
        f"delta {(candidate_median - baseline_median) / baseline_median * 100:+.2f}%"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
