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

from terminal_benchmark_fixtures import iter_bytes, load_corpus


ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA_VERSION = 2
CORE_BENCHMARK_METHOD = "fresh-terminal-batch-v1"
CORE_SAMPLE_TARGET_NANOSECONDS = 1_000_000_000
WORKLOADS = load_corpus(ROOT)
CORPUS = tuple(WORKLOADS)
FIXTURES = {name: workload["identity"] for name, workload in WORKLOADS.items()}
HISTORY_PATH = ROOT / "benchmarks" / "results" / "terminal-app.jsonl"
STAGING_ROOT = ROOT / ".build" / "terminal-benchmark-staged"
APP_COMPATIBILITY_FIELDS = (
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
CORE_COMPATIBILITY_FIELDS = (
    "backend",
    "benchmarkMethod",
    "workload",
    "fixture",
    "buildConfiguration",
    "toolchain",
    "machine",
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
    fields = CORE_COMPATIBILITY_FIELDS if result["backend"] == "swift-core" else APP_COMPATIBILITY_FIELDS
    return {field: result[field] for field in fields}


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
    if backend not in ("swift", "ghostty", "swift-core"):
        raise ValueError("backend must be swift, ghostty, or swift-core")
    return backend


def parse_arguments(arguments):
    """Parse named options in any order while retaining positional shorthand."""
    backend = "swift"
    workload = None
    default_workload = None
    save = None
    seen_backend = False
    seen_workload = False
    seen_save = False
    comment = None
    seen_comment = False
    for argument in arguments:
        if argument.startswith("backend=") or argument in ("swift", "ghostty", "swift-core"):
            if seen_backend:
                raise ValueError("backend specified more than once")
            backend = parse_backend(argument)
            seen_backend = True
        elif argument.startswith("workload=") or argument in WORKLOADS:
            if seen_workload:
                raise ValueError("workload specified more than once")
            workload = argument.removeprefix("workload=")
            if workload not in WORKLOADS:
                raise ValueError(f"unknown benchmark workload: {workload}")
            seen_workload = True
        elif argument.startswith("default-workload="):
            default_workload = argument.removeprefix("default-workload=")
            if default_workload not in WORKLOADS:
                raise ValueError(f"unknown benchmark workload: {default_workload}")
        elif argument.startswith("save="):
            if seen_save:
                raise ValueError("save specified more than once")
            value = argument.removeprefix("save=")
            if value not in ("", "0", "1"):
                raise ValueError("save must be 0 or 1")
            save = {"": None, "0": False, "1": True}[value]
            seen_save = True
        elif argument in ("0", "1"):
            if seen_save:
                raise ValueError("save specified more than once")
            save = argument == "1"
            seen_save = True
        elif argument.startswith("comment="):
            if seen_comment:
                raise ValueError("comment specified more than once")
            comment = argument.removeprefix("comment=")
            seen_comment = True
        else:
            if argument.startswith("workload="):
                raise ValueError(f"unknown benchmark workload: {argument.removeprefix('workload=')}")
            raise ValueError(f"unknown argument: {argument}")
    return backend, workload if workload is not None else default_workload, save, comment


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


def target_geometry():
    """Return the grid every raw harness run must report."""
    return {
        "columns": int(os.environ.get("DANTERM_TERMINAL_BENCHMARK_COLUMNS", "80")),
        "rows": int(os.environ.get("DANTERM_TERMINAL_BENCHMARK_ROWS", "24")),
    }


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
    target = target_geometry()
    mismatched = next((run["geometry"] for run in runs if run["geometry"] != target), None)
    if mismatched is not None:
        raise SystemExit(
            "Benchmark geometry mismatch: "
            f"required {target['columns']}x{target['rows']}, "
            f"reported {mismatched['columns']}x{mismatched['rows']}"
        )
    geometry = runs[0]["geometry"]
    display_scale = runs[0]["displayScale"]
    if any(run["geometry"] != geometry or run["displayScale"] != display_scale for run in runs[1:]):
        raise SystemExit("Benchmark geometry or display scale changed between iterations")
    return runs


def run_core_workload(workload, iterations):
    """Measure only Terminal.feed while preserving the committed corpus chunk boundaries."""
    command = (
        "swift", "run", "--package-path", str(ROOT / "lib" / "TerminalCore"),
        "--configuration", "release", "TerminalCoreBenchmark", str(iterations),
    )
    payload = bytearray()
    for chunk in iter_bytes(ROOT, WORKLOADS[workload]):
        payload.extend(len(chunk).to_bytes(8, byteorder="big"))
        payload.extend(chunk)
    completed = subprocess.run(command, input=bytes(payload), capture_output=True)
    if completed.returncode != 0:
        raise SystemExit(completed.stderr.decode(errors="replace").strip())
    measurements = json.loads(completed.stdout)
    if len(measurements["feedDurationNanoseconds"]) != iterations:
        raise SystemExit("Core benchmark returned the wrong sample count")
    if any(
        duration < CORE_SAMPLE_TARGET_NANOSECONDS
        for duration in measurements["sampleDurationNanoseconds"]
    ):
        raise SystemExit("Core benchmark returned a sample below the duration floor")
    return measurements


def make_result(workload, backend, runs, comment=None):
    iteration_count = (
        len(runs["feedDurationNanoseconds"])
        if backend == "swift-core"
        else len(runs)
    )
    result = {
        "schemaVersion": SCHEMA_VERSION,
        "backend": backend,
        "workload": workload,
        "fixture": {"identity": FIXTURES[workload]},
        "commit": command_output("git", "-C", str(ROOT), "rev-parse", "HEAD"),
        "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "machine": machine_identity(),
        "toolchain": command_output("swift", "--version").splitlines()[0],
        "buildConfiguration": "release",
        "profilingActive": False,
        "iterations": iteration_count,
    }
    if comment is not None:
        result["comment"] = comment
    if backend == "swift-core":
        result["benchmarkMethod"] = CORE_BENCHMARK_METHOD
        result["summary"] = {
            "iterations": iteration_count,
            "batchCount": runs["batchCount"],
            "feedDurationNanoseconds": distribution(runs["feedDurationNanoseconds"]),
        }
    else:
        result.update({
            "macOS": command_output("sw_vers", "-productVersion"),
            "displayScale": runs[0]["displayScale"],
            "geometry": runs[0]["geometry"],
            "summary": summarize_runs(runs),
        })
    return result


def report(result, baseline, serialized=None):
    print((serialized if serialized is not None else serialize_result(result)).rstrip("\n"))
    if baseline is None:
        print("delta: no compatible committed result")
        return
    metrics = (("feedDurationNanoseconds",) if result["backend"] == "swift-core"
               else ("producerWriteNanoseconds", "finalDrawNanoseconds"))
    for metric in metrics:
        if result["summary"][metric].get("available", True):
            print(f"delta {metric}: {delta_percent(result, baseline, metric):+.2f}%")


def main():
    refuse_profiled_history()
    try:
        backend, workload_filter, save, comment = parse_arguments(sys.argv[1:])
    except ValueError as error:
        raise SystemExit(str(error)) from error
    iterations = int(os.environ.get("DANTERM_BENCHMARK_ITERATIONS", "3"))
    if iterations < 2:
        raise SystemExit("DANTERM_BENCHMARK_ITERATIONS must be at least 2")
    workloads = (workload_filter,) if workload_filter is not None else CORPUS
    staged_path = None
    for workload in workloads:
        runs = (run_core_workload(workload, iterations) if backend == "swift-core"
                else run_workload(workload, backend, iterations))
        result = make_result(workload, backend, runs, comment=comment)
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
