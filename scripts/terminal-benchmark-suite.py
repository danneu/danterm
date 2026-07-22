#!/usr/bin/env python3
"""Run the committed real-app corpus and maintain compatible benchmark history."""
import datetime
import json
import os
import pathlib
import statistics
import subprocess
import sys


SCHEMA_VERSION = 2
CORPUS = ("plain-scrolling",)
FIXTURES = {"plain-scrolling": "plain-scrolling-v1-20000-lines"}
ROOT = pathlib.Path(__file__).resolve().parent.parent
HISTORY_PATH = ROOT / "benchmarks" / "results" / "terminal-app.jsonl"
COMPATIBILITY_FIELDS = (
    "schemaVersion",
    "backend",
    "workload",
    "fixture",
    "machine",
    "macOS",
    "displayScale",
    "toolchain",
    "buildConfiguration",
    "geometry",
    "profilingActive",
)


def distribution(values):
    """Return the stable distribution summary used by history and console reports."""
    return {"min": min(values), "median": statistics.median(values), "max": max(values)}


def summarize_runs(runs):
    """Aggregate repeated raw harness runs without combining the two metric meanings."""
    producer = [run["producerWrite"]["elapsedNanoseconds"] for run in runs]
    draw = [run["finalDraw"] for run in runs]
    summary = {
        "iterations": len(runs),
        "producerWriteNanoseconds": distribution(producer),
    }
    if all(item["available"] for item in draw):
        summary["finalDrawNanoseconds"] = {
            "available": True,
            **distribution([item["elapsedNanoseconds"] for item in draw]),
        }
    else:
        summary["finalDrawNanoseconds"] = {
            "available": False,
            "reason": draw[0]["reason"],
        }
    return summary


def compatibility_key(result):
    """Select every environment field that must match before reporting a delta."""
    return {field: result[field] for field in COMPATIBILITY_FIELDS}


def append_result(path, result):
    """Append one versioned result without rewriting earlier committed measurements."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n")


def latest_compatible(path, current):
    """Find the newest historical result with an exactly equal compatibility key."""
    if not path.exists():
        return None
    return latest_compatible_lines(path.read_text(encoding="utf-8").splitlines(), current)


def latest_compatible_lines(lines, current):
    """Find a compatible result while tolerating records from older schemas."""
    expected = compatibility_key(current)
    latest = None
    for line in lines:
        candidate = json.loads(line)
        try:
            if compatibility_key(candidate) == expected:
                latest = candidate
        except KeyError:
            continue
    return latest


def latest_committed(current):
    """Read baselines from HEAD so uncommitted local runs never become history claims."""
    relative_path = HISTORY_PATH.relative_to(ROOT).as_posix()
    completed = subprocess.run(
        ("git", "-C", str(ROOT), "show", f"HEAD:{relative_path}"),
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        return None
    return latest_compatible_lines(completed.stdout.splitlines(), current)


def delta_percent(current, previous, metric):
    """Report median change, where a negative percentage means the run became faster."""
    new = current["summary"][metric]["median"]
    old = previous["summary"][metric]["median"]
    return round((new - old) * 100.0 / old, 2)


def command_output(*command):
    return subprocess.check_output(command, text=True).strip()


def parse_backend(argument):
    """Accept both direct script arguments and just's named-argument spelling."""
    backend = argument.removeprefix("backend=")
    if backend not in ("swift", "ghostty"):
        raise ValueError("backend must be swift or ghostty")
    return backend


def machine_identity():
    model = command_output("sysctl", "-n", "hw.model")
    try:
        hardware = json.loads(command_output("system_profiler", "SPHardwareDataType", "-json"))
        chip = hardware["SPHardwareDataType"][0].get("chip_type")
        if not chip:
            chip = command_output("uname", "-m")
    except (KeyError, json.JSONDecodeError, subprocess.CalledProcessError):
        chip = command_output("uname", "-m")
    return {"model": model, "chip": chip}


def run_workload(workload, backend, iterations):
    runs = []
    for iteration in range(1, iterations + 1):
        print(f"[{workload}] iteration {iteration}/{iterations}", file=sys.stderr)
        output = command_output(str(ROOT / "scripts" / "terminal-benchmark.sh"), workload, backend)
        runs.append(json.loads(output))
    geometry = runs[0]["geometry"]
    display_scale = runs[0]["displayScale"]
    if any(run["geometry"] != geometry or run["displayScale"] != display_scale for run in runs[1:]):
        raise SystemExit("Benchmark geometry or display scale changed between iterations")
    return runs


def make_result(workload, backend, runs):
    return {
        "schemaVersion": SCHEMA_VERSION,
        "backend": backend,
        "workload": workload,
        "fixture": {"identity": FIXTURES[workload]},
        "commit": command_output("git", "-C", str(ROOT), "rev-parse", "HEAD"),
        "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "machine": machine_identity(),
        "macOS": command_output("sw_vers", "-productVersion"),
        "displayScale": runs[0]["displayScale"],
        "toolchain": command_output("swift", "--version").splitlines()[0],
        "buildConfiguration": "release",
        "geometry": runs[0]["geometry"],
        "profilingActive": False,
        "summary": summarize_runs(runs),
    }


def report(result, baseline):
    print(json.dumps(result, indent=2, sort_keys=True))
    if baseline is None:
        print("delta: no compatible committed result")
        return
    metrics = ("producerWriteNanoseconds", "finalDrawNanoseconds")
    for metric in metrics:
        if result["summary"][metric].get("available", True):
            print(f"delta {metric}: {delta_percent(result, baseline, metric):+.2f}%")


def main():
    try:
        backend = parse_backend(sys.argv[1] if len(sys.argv) > 1 else "swift")
    except ValueError as error:
        raise SystemExit(str(error)) from error
    iterations = int(os.environ.get("DANTERM_BENCHMARK_ITERATIONS", "3"))
    if iterations < 2:
        raise SystemExit("DANTERM_BENCHMARK_ITERATIONS must be at least 2")
    for workload in CORPUS:
        result = make_result(workload, backend, run_workload(workload, backend, iterations))
        baseline = latest_committed(result)
        append_result(HISTORY_PATH, result)
        report(result, baseline)


if __name__ == "__main__":
    main()
