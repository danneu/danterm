#!/usr/bin/env python3
"""Run the committed real-app corpus and maintain compatible benchmark history."""
import datetime
import json
import os
import pathlib
import statistics
import subprocess
import sys
import tempfile

from terminal_benchmark_fixtures import load_corpus


ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA_VERSION = 2
WORKLOADS = load_corpus(ROOT)
CORPUS = tuple(WORKLOADS)
FIXTURES = {name: workload["identity"] for name, workload in WORKLOADS.items()}
HISTORY_PATH = ROOT / "benchmarks" / "results" / "terminal-app.jsonl"
STAGING_ROOT = ROOT / ".build" / "terminal-benchmark-staged"
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
    "iterations",
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


def append_result(path, result, serialized=None):
    """Append one versioned result without rewriting earlier committed measurements."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(serialized if serialized is not None else serialize_result(result))


def serialize_result(result):
    """Freeze one completed run into the bytes used for staging and history."""
    return json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n"


def create_staged_path():
    """Reserve a durable transient file before the first workload completes."""
    STAGING_ROOT.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix="terminal-app-", suffix=".jsonl", dir=STAGING_ROOT)
    os.close(descriptor)
    return pathlib.Path(name)


def promote_staged(staged_path, history_path):
    """Append the exact staged bytes after the user confirms the completed run."""
    history_path.parent.mkdir(parents=True, exist_ok=True)
    with staged_path.open("rb") as source, history_path.open("ab") as destination:
        while chunk := source.read(1024 * 1024):
            destination.write(chunk)


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


def parse_arguments(arguments):
    """Parse the suite's backend, optional workload filter, and save policy."""
    backend = parse_backend(arguments[0] if arguments else "swift")
    workload = None
    save = None
    for argument in arguments[1:]:
        if argument.startswith("workload="):
            workload = argument.removeprefix("workload=")
            if workload not in WORKLOADS:
                raise ValueError(f"unknown benchmark workload: {workload}")
        elif argument.startswith("save="):
            value = argument.removeprefix("save=")
            if value not in ("", "0", "1"):
                raise ValueError("save must be 0 or 1")
            save = {"": None, "0": False, "1": True}[value]
        else:
            raise ValueError(f"unknown argument: {argument}")
    return backend, workload, save


def confirm_save():
    """Ask once after a successful run, defaulting every non-yes answer to no."""
    try:
        answer = input("Save these results to benchmark history? [y/N]")
    except EOFError:
        return False
    return answer.strip().lower() in ("y", "yes")


def refuse_profiled_history():
    """Keep diagnostic profiler timings out of append-only benchmark history."""
    if os.environ.get("DANTERM_BENCHMARK_PROFILING") == "1":
        raise SystemExit("Profiled runs cannot enter benchmark history")


def require_ac_power():
    """Keep battery power-management changes out of comparable benchmark runs."""
    power_status = command_output("pmset", "-g", "batt")
    if "Now drawing from 'AC Power'" not in power_status:
        raise SystemExit("Benchmark requires AC power; plug in this Mac and retry")


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
        "iterations": len(runs),
        "summary": summarize_runs(runs),
    }


def report(result, baseline, serialized=None):
    print((serialized if serialized is not None else serialize_result(result)).rstrip("\n"))
    if baseline is None:
        print("delta: no compatible committed result")
        return
    metrics = ("producerWriteNanoseconds", "finalDrawNanoseconds")
    for metric in metrics:
        if result["summary"][metric].get("available", True):
            print(f"delta {metric}: {delta_percent(result, baseline, metric):+.2f}%")


def main():
    refuse_profiled_history()
    try:
        backend, workload_filter, save = parse_arguments(sys.argv[1:])
    except ValueError as error:
        raise SystemExit(str(error)) from error
    require_ac_power()
    iterations = int(os.environ.get("DANTERM_BENCHMARK_ITERATIONS", "3"))
    if iterations < 2:
        raise SystemExit("DANTERM_BENCHMARK_ITERATIONS must be at least 2")
    workloads = (workload_filter,) if workload_filter is not None else CORPUS
    staged_path = None
    for workload in workloads:
        result = make_result(workload, backend, run_workload(workload, backend, iterations))
        baseline = latest_committed(result)
        serialized = serialize_result(result)
        if staged_path is None:
            staged_path = create_staged_path()
        append_result(staged_path, result, serialized=serialized)
        report(result, baseline, serialized=serialized)
    should_save = confirm_save() if save is None else save
    if should_save:
        promote_staged(staged_path, HISTORY_PATH)
    else:
        print(f"Results staged at {staged_path}")


if __name__ == "__main__":
    main()
