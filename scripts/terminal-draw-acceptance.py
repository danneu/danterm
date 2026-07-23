#!/usr/bin/env python3
"""Run calibrated real-AppKit draw benchmarks and persist serialized redraw history."""
import datetime
import json
import math
import os
import pathlib
import statistics
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent
REDRAW_WORKLOADS = (
    "full-screen-content-churn",
    "full-screen-style-churn",
    "full-screen-mixed-churn",
    "full-screen-symbol-churn",
)
REDRAW_IDENTITIES = {
    "full-screen-content-churn": "full-screen-content-churn-v1-pseudo-lazygit-80x24",
    "full-screen-style-churn": "full-screen-style-churn-v1-pseudo-lazygit-80x24",
    "full-screen-mixed-churn": "full-screen-mixed-churn-v1-pseudo-lazygit-80x24",
    "full-screen-symbol-churn": "full-screen-symbol-churn-v2-geometric-sprite-mix-80x24",
}
HISTORY_PATH = ROOT / "benchmarks" / "results" / "terminal-redraw.jsonl"
STAGING_ROOT = ROOT / ".build" / "terminal-benchmark-staged"
REDRAW_METHOD = "serialized-completed-draw-v1"
REDRAW_COMPATIBILITY_FIELDS = (
    "schemaVersion",
    "workload",
    "fixture",
    "benchmarkMethod",
    "machine",
    "macOS",
    "displayScale",
    "toolchain",
    "buildConfiguration",
    "geometry",
    "batchCount",
    "targetBatchNanoseconds",
    "profilingActive",
)


def calibrated_update_count(measured_nanoseconds, measured_updates, target_nanoseconds):
    """Scale an excluded warm-up to the fixed draw-work duration target."""
    if measured_nanoseconds <= 0 or measured_updates <= 0:
        raise ValueError("calibration requires positive draw duration and update count")
    return max(1, math.ceil(target_nanoseconds * measured_updates / measured_nanoseconds))


def distribution(values):
    """Return the compact range and median used for local A/B decisions."""
    return {"min": min(values), "median": statistics.median(values), "max": max(values)}


def summarize_batches(batches, expected_updates):
    """Validate draw separation and normalize cumulative time for comparable batches."""
    normalized = []
    dirty_rows = []
    for batch in batches:
        count = batch["drawCount"]
        if count != expected_updates:
            raise ValueError(f"expected {expected_updates} completed draws, got {count}")
        if len(batch["dirtyRowCounts"]) != count:
            raise ValueError("dirty-row evidence does not match completed draw count")
        normalized.append(batch["cumulativeDrawNanoseconds"] // count)
        dirty_rows.extend(batch["dirtyRowCounts"])
    return {
        "batchCount": len(batches),
        "drawCount": distribution([batch["drawCount"] for batch in batches]),
        "nanosecondsPerDraw": distribution(normalized),
        "dirtyRowsPerDraw": distribution(dirty_rows),
        "cumulativeDrawNanoseconds": distribution(
            [batch["cumulativeDrawNanoseconds"] for batch in batches]
        ),
    }


def run_batch(update_count, workload=None):
    """Run one fresh optimized app batch and return its direct draw measurements."""
    environment = os.environ.copy()
    if workload is None:
        environment["DANTERM_TERMINAL_BENCHMARK_LOCALIZED_UPDATES"] = str(update_count)
        harness_workload = "localized-draw-acceptance"
    else:
        environment["DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES"] = str(update_count)
        harness_workload = workload
    completed = subprocess.run(
        (
            str(ROOT / "scripts" / "terminal-benchmark.sh"),
            harness_workload,
            "swift",
        ),
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise SystemExit(completed.stderr.strip())
    payload = json.loads(completed.stdout)
    draw = payload["finalDraw"]
    draw["geometry"] = payload["geometry"]
    draw["displayScale"] = payload["displayScale"]
    return draw


def parse_arguments(arguments):
    """Parse redraw options in any order while keeping the localized legacy mode."""
    workload = None
    save = None
    comment = None
    batches = 15
    target_milliseconds = 400
    positional_count = 0
    redraw_requested = False
    for argument in arguments:
        if argument == "redraw=1":
            redraw_requested = True
        elif argument.startswith("workload="):
            workload = argument.removeprefix("workload=") or None
            if workload is not None and workload not in REDRAW_WORKLOADS:
                raise ValueError(f"unknown redraw workload: {workload}")
        elif argument.startswith("save="):
            value = argument.removeprefix("save=")
            if value not in ("", "0", "1"):
                raise ValueError("save must be 0 or 1")
            save = {"": None, "0": False, "1": True}[value]
        elif argument.startswith("comment="):
            comment = argument.removeprefix("comment=")
        elif argument.startswith("batches="):
            batches = int(argument.removeprefix("batches="))
        elif argument.startswith("target_ms="):
            target_milliseconds = int(argument.removeprefix("target_ms="))
        elif argument.isdigit():
            if positional_count == 0:
                batches = int(argument)
            elif positional_count == 1:
                target_milliseconds = int(argument)
            else:
                raise ValueError(f"unknown argument: {argument}")
            positional_count += 1
        else:
            raise ValueError(f"unknown argument: {argument}")
    if batches < 2 or target_milliseconds <= 0:
        raise ValueError("batches must be >=2 and target_ms must be >0")
    return workload, save, comment, batches, target_milliseconds, redraw_requested


def command_output(*command):
    return subprocess.check_output(command, text=True).strip()


def environment_identity():
    """Capture the environment fields that make direct draw records comparable."""
    hardware = json.loads(command_output("system_profiler", "SPHardwareDataType", "-json"))
    chip = hardware["SPHardwareDataType"][0].get("chip_type") or command_output("uname", "-m")
    return {
        "machine": {"model": command_output("sysctl", "-n", "hw.model"), "chip": chip},
        "macOS": command_output("sw_vers", "-productVersion"),
        "toolchain": command_output("swift", "--version").splitlines()[0],
    }


def require_ac_power():
    """Keep power-management changes out of persistent benchmark comparisons."""
    if "Now drawing from 'AC Power'" not in command_output("pmset", "-g", "batt"):
        raise SystemExit("Benchmark requires AC power; plug in this Mac and retry")


def make_redraw_result(workload, report, raw_batch):
    """Freeze one compatible redraw result after every measured batch succeeds."""
    identity = environment_identity()
    result = {
        "schemaVersion": 1,
        "workload": workload,
        "fixture": {"identity": REDRAW_IDENTITIES[workload]},
        "benchmarkMethod": REDRAW_METHOD,
        **identity,
        "displayScale": raw_batch["displayScale"],
        "buildConfiguration": "release",
        "geometry": raw_batch["geometry"],
        "batchCount": len(report["batches"]),
        "targetBatchNanoseconds": report["targetBatchNanoseconds"],
        "profilingActive": False,
        "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "commit": command_output("git", "rev-parse", "HEAD"),
        "summary": report["summary"],
    }
    return result


def latest_committed(current):
    """Read the newest exactly compatible redraw record from committed history."""
    completed = subprocess.run(
        ("git", "show", "HEAD:benchmarks/results/terminal-redraw.jsonl"),
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        return None
    expected = {field: current[field] for field in REDRAW_COMPATIBILITY_FIELDS}
    latest = None
    for line in completed.stdout.splitlines():
        candidate = json.loads(line)
        try:
            if {field: candidate[field] for field in REDRAW_COMPATIBILITY_FIELDS} == expected:
                latest = candidate
        except KeyError:
            continue
    return latest


def serialize_result(result):
    return json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n"


def run_redraw(workload, batches, target_milliseconds):
    """Calibrate one workload, then run fresh duration-stable optimized-app batches."""
    target_nanoseconds = target_milliseconds * 1_000_000
    warmup_updates = 8
    print(f"[{workload}] excluded warm-up with {warmup_updates} updates", file=sys.stderr)
    warmup = run_batch(warmup_updates, workload)
    update_count = calibrated_update_count(
        warmup["cumulativeDrawNanoseconds"],
        warmup["drawCount"],
        target_nanoseconds * 5 // 4,
    )
    measured = []
    last_raw = None
    for index in range(batches):
        print(f"[{workload}] batch {index + 1}/{batches}, {update_count} updates", file=sys.stderr)
        raw = run_batch(update_count, workload)
        if raw["cumulativeDrawNanoseconds"] < target_nanoseconds:
            raise SystemExit(
                "calibrated batch fell below draw-work duration floor: "
                f"{raw['cumulativeDrawNanoseconds']} < {target_nanoseconds}"
            )
        if any(count != 24 for count in raw["dirtyRowCounts"]):
            raise SystemExit("every serialized full-screen draw must damage exactly 24 rows")
        measured.append(raw)
        last_raw = raw
    report = {
        "targetBatchNanoseconds": target_nanoseconds,
        "batches": measured,
        "summary": summarize_batches(measured, update_count),
    }
    return make_redraw_result(workload, report, last_raw)


def main():
    """Run legacy local acceptance or the persistent serialized redraw suite."""
    try:
        workload, save, comment, batches, target_milliseconds, redraw_requested = (
            parse_arguments(sys.argv[1:])
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error
    redraw_mode = redraw_requested or workload is not None or any(
        argument.startswith(("workload=", "save=", "comment=")) for argument in sys.argv[1:]
    )
    if redraw_mode:
        if os.environ.get("DANTERM_BENCHMARK_PROFILING") == "1":
            raise SystemExit("Profiled runs cannot enter benchmark history")
        require_ac_power()
        workloads = (workload,) if workload else REDRAW_WORKLOADS
        STAGING_ROOT.mkdir(parents=True, exist_ok=True)
        staged = STAGING_ROOT / (
            "terminal-redraw-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + ".jsonl"
        )
        results = []
        for name in workloads:
            result = run_redraw(name, batches, target_milliseconds)
            if comment is not None:
                result["comment"] = comment
            results.append(result)
            baseline = latest_committed(result)
            print(serialize_result(result), end="")
            if baseline is None:
                print("delta: no compatible committed result")
            else:
                old = baseline["summary"]["nanosecondsPerDraw"]["median"]
                new = result["summary"]["nanosecondsPerDraw"]["median"]
                print(f"delta nanosecondsPerDraw: {(new - old) * 100 / old:+.2f}%")
        staged.write_text("".join(serialize_result(result) for result in results), encoding="utf-8")
        should_save = save
        if should_save is None:
            try:
                should_save = input("Save these results to redraw history? [y/N]").strip().lower() in ("y", "yes")
            except EOFError:
                should_save = False
        if should_save:
            HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
            with HISTORY_PATH.open("ab") as destination:
                destination.write(staged.read_bytes())
        return

    target_nanoseconds = target_milliseconds * 1_000_000
    warmup_updates = 8
    print(
        f"[localized draw] excluded warm-up with {warmup_updates} updates",
        file=sys.stderr,
    )
    warmup = run_batch(warmup_updates)
    update_count = calibrated_update_count(
        warmup["cumulativeDrawNanoseconds"],
        warmup["drawCount"],
        target_nanoseconds * 5 // 4,
    )
    measured = []
    for index in range(batches):
        print(
            f"[localized draw] batch {index + 1}/{batches}, {update_count} updates",
            file=sys.stderr,
        )
        batch = run_batch(update_count)
        if batch["cumulativeDrawNanoseconds"] < target_nanoseconds:
            raise SystemExit(
                "calibrated batch fell below draw-work duration floor: "
                f"{batch['cumulativeDrawNanoseconds']} < {target_nanoseconds}"
            )
        measured.append(batch)
    report = {
        "schemaVersion": 1,
        "benchmark": "localized-real-app-draw",
        "targetBatchNanoseconds": target_nanoseconds,
        "calibration": {
            "excluded": True,
            "warmupUpdates": warmup_updates,
            "measuredUpdatesPerBatch": update_count,
        },
        "batches": measured,
        "summary": summarize_batches(measured, update_count),
    }
    json.dump(report, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
