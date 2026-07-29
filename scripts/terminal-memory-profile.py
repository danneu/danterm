#!/usr/bin/env python3
"""Measure sustained memory growth of an already-running benchmark process.

The CPU profilers answer "where does the time go"; this answers "does the
footprint keep climbing". It polls `footprint -j` on an interval and, on
request, brackets the run with memory graphs so `heap --diffFrom` can name the
classes that grew.

Deliberately not a leak detector. `leaks` finds unreachable allocations, and
the failure this codebase can actually produce -- scrollback retaining past its
bound, a cache that never evicts, damage snapshots accumulating -- is fully
reachable and invisible to it. Growth in resident footprint is the signal that
catches those; the heap diff is what attributes it.

Growth is measured from the end of warmup, not from launch, for the same reason
the redraw workloads exclude a settling draw: the caches filling and scrollback
reaching its bound is the design working, and baselining before that reports it
as a leak on every run. Its numbers are diagnostic only, like every other
profile here -- they never enter paired decisions or benchmark history.

Aggregation is pinned by scripts/tests/terminal_memory_profile_test.py.
"""
import argparse
import dataclasses
import json
import pathlib
import subprocess
import sys
import time


# Categories that are large, constant, and file-backed. They dominate the
# footprint of every run and never move, so ranking growth without excluding
# them buries the malloc zones that actually change.
_STATIC_CATEGORIES = frozenset({"__TEXT", "__DATA_CONST", "__LINKEDIT", "mapped file"})


@dataclasses.dataclass(frozen=True)
class Snapshot:
    """One `footprint` reading: total footprint plus per-category resident cost."""

    elapsed: float
    footprint: int
    categories: dict


def snapshot_from_footprint(document, pid, elapsed):
    """Pull one process out of a `footprint -j` document.

    A category's cost is dirty + swapped: the pages that must exist somewhere
    for this process. Clean pages are file-backed and evictable for free.
    """
    for process in document.get("processes", []):
        if process.get("pid") != pid:
            continue
        categories = {
            name: int(values.get("dirty", 0)) + int(values.get("swapped", 0))
            for name, values in (process.get("categories") or {}).items()
        }
        return Snapshot(
            elapsed=elapsed, footprint=int(process.get("footprint", 0)), categories=categories
        )
    raise ValueError(f"footprint document contains no process with pid {pid}")


def _slope(points):
    """Least-squares bytes-per-second over (elapsed, footprint).

    Fitted rather than endpoint-to-endpoint so one noisy final sample cannot
    dominate the reported rate.
    """
    count = len(points)
    mean_x = sum(x for x, _ in points) / count
    mean_y = sum(y for _, y in points) / count
    variance = sum((x - mean_x) ** 2 for x, _ in points)
    if variance == 0:
        return 0.0
    covariance = sum((x - mean_x) * (y - mean_y) for x, y in points)
    return covariance / variance


def summarize_memory(snapshots, warmup_seconds, top=15):
    """Turn a snapshot series into baseline, growth, rate, and per-category growth."""
    measured = [snapshot for snapshot in snapshots if snapshot.elapsed >= warmup_seconds]
    if len(measured) < 2:
        raise ValueError(
            f"need at least two snapshots after the {warmup_seconds}s warmup to measure "
            f"growth, got {len(measured)} of {len(snapshots)}"
        )

    baseline, final = measured[0], measured[-1]
    growth = final.footprint - baseline.footprint
    category_growth = []
    for name in set(baseline.categories) | set(final.categories):
        if name in _STATIC_CATEGORIES:
            continue
        delta = final.categories.get(name, 0) - baseline.categories.get(name, 0)
        if delta:
            category_growth.append(
                {
                    "category": name,
                    "growthBytes": delta,
                    "baselineBytes": baseline.categories.get(name, 0),
                    "finalBytes": final.categories.get(name, 0),
                }
            )
    category_growth.sort(key=lambda row: row["growthBytes"], reverse=True)

    return {
        "warmupSeconds": warmup_seconds,
        "excludedWarmupSamples": len(snapshots) - len(measured),
        "measuredSeconds": round(final.elapsed - baseline.elapsed, 3),
        "baseline": {"elapsed": baseline.elapsed, "footprint": baseline.footprint},
        "final": {"elapsed": final.elapsed, "footprint": final.footprint},
        "peakFootprint": max(snapshot.footprint for snapshot in measured),
        "growthBytes": growth,
        "growthRatio": round(final.footprint / baseline.footprint, 6)
        if baseline.footprint
        else None,
        "growthBytesPerSecond": round(
            _slope([(s.elapsed, s.footprint) for s in measured]), 3
        ),
        "categoryGrowth": category_growth[:top],
        "series": [
            {
                "elapsed": round(snapshot.elapsed, 3),
                "footprint": snapshot.footprint,
                "warmup": snapshot.elapsed < warmup_seconds,
            }
            for snapshot in snapshots
        ],
        "profiledTimingsAreDiagnosticOnly": True,
    }


# --- capture ------------------------------------------------------------------


def poll(pid, seconds, interval, root, clock=time.monotonic):
    """Sample `footprint -j` until the duration elapses or the process exits."""
    snapshots = []
    started = clock()
    index = 0
    while True:
        elapsed = clock() - started
        if elapsed > seconds:
            break
        destination = root / f"footprint-{index:04d}.json"
        completed = subprocess.run(
            ["footprint", "-j", str(destination), "-p", str(pid)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        if completed.returncode != 0 or not destination.exists():
            raise SystemExit(
                f"footprint failed for pid {pid}: "
                f"{completed.stderr.decode(errors='replace').strip()}"
            )
        document = json.loads(destination.read_text())
        snapshots.append(snapshot_from_footprint(document, pid, elapsed))
        destination.unlink()
        index += 1
        remaining = interval - (clock() - started - elapsed)
        if remaining > 0:
            time.sleep(remaining)
    return snapshots


def capture_memgraph(pid, destination):
    """Write a memory graph for `heap --diffFrom` to compare against later.

    This suspends the target while it walks the heap, which perturbs the run --
    acceptable because these numbers are diagnostic only, but it is why the
    graphs bracket the measured window instead of being taken on the interval.
    """
    completed = subprocess.run(
        ["leaks", "--outputGraph=" + str(destination), "--nostacks", "-q", str(pid)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    if not destination.exists():
        return completed.stderr.decode(errors="replace").strip() or "leaks produced no graph"
    return None


def heap_diff(baseline_graph, final_graph, destination):
    completed = subprocess.run(
        ["heap", "--diffFrom=" + str(baseline_graph), "-s", "-H", str(final_graph)],
        capture_output=True,
    )
    if completed.returncode != 0:
        return completed.stderr.decode(errors="replace").strip() or "heap diff failed"
    destination.write_bytes(completed.stdout)
    return None


def render_summary(summary):
    def megabytes(value):
        return f"{value / 1_000_000:.1f} MB"

    lines = [
        f"measured {summary['measuredSeconds']:.0f}s after a "
        f"{summary['warmupSeconds']:.0f}s warmup "
        f"({summary['excludedWarmupSamples']} warmup samples excluded)",
        f"footprint: {megabytes(summary['baseline']['footprint'])} -> "
        f"{megabytes(summary['final']['footprint'])} "
        f"(peak {megabytes(summary['peakFootprint'])})",
        f"growth:    {megabytes(summary['growthBytes'])} total, "
        f"{summary['growthBytesPerSecond'] / 1000:.1f} KB/s fitted",
    ]
    if summary["categoryGrowth"]:
        lines.append("grew:")
        for row in summary["categoryGrowth"][:8]:
            lines.append(f"  {megabytes(row['growthBytes']):>12}  {row['category']}")
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("pid", type=int)
    parser.add_argument("--output", required=True, help="artifact directory")
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--interval", type=float, default=2.0)
    parser.add_argument(
        "--warmup",
        type=float,
        default=15.0,
        help="seconds to exclude before the baseline; growth is measured after this",
    )
    parser.add_argument(
        "--no-heap-diff",
        action="store_true",
        help="skip the bracketing memory graphs, which suspend the target briefly",
    )
    arguments = parser.parse_args(argv)
    if arguments.seconds <= arguments.warmup:
        parser.error("--seconds must exceed --warmup, or there is nothing to measure")

    root = pathlib.Path(arguments.output)
    root.mkdir(parents=True, exist_ok=True)
    attribution = {"requested": not arguments.no_heap_diff}

    snapshots = []
    baseline_graph = root / "baseline.memgraph"
    if not arguments.no_heap_diff:
        # Take the baseline graph at the warmup boundary so it brackets exactly
        # the window the growth number covers.
        snapshots += poll(arguments.pid, arguments.warmup, arguments.interval, root)
        failure = capture_memgraph(arguments.pid, baseline_graph)
        if failure:
            attribution["baselineError"] = failure
    offset = snapshots[-1].elapsed if snapshots else 0.0
    remainder = poll(arguments.pid, arguments.seconds - offset, arguments.interval, root)
    snapshots += [dataclasses.replace(s, elapsed=s.elapsed + offset) for s in remainder]

    if not arguments.no_heap_diff and baseline_graph.exists():
        final_graph = root / "final.memgraph"
        failure = capture_memgraph(arguments.pid, final_graph)
        if failure:
            attribution["finalError"] = failure
        else:
            failure = heap_diff(baseline_graph, final_graph, root / "heap-diff.txt")
            attribution["diffError" if failure else "diff"] = failure or str(
                root / "heap-diff.txt"
            )

    summary = summarize_memory(snapshots, warmup_seconds=arguments.warmup)
    summary["pid"] = arguments.pid
    summary["attribution"] = attribution
    report_path = root / "memory-report.json"
    report_path.write_text(json.dumps(summary, indent=2) + "\n")
    sys.stdout.write(render_summary(summary))
    print(f"report: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
