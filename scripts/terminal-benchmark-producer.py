#!/usr/bin/env python3
"""Gate on target PTY geometry, then emit and time one deterministic workload."""
import json
import os
import time
from pathlib import Path

from terminal_benchmark_fixtures import iter_bytes, load_corpus, write_all


def wait_for_target_geometry(
    target, terminal_size, monotonic, sleep, timeout_seconds=20
):
    """Wait for the PTY to reach the requested grid before workload activity."""
    deadline = monotonic() + timeout_seconds
    while True:
        observed = terminal_size()
        if observed == target:
            return observed
        if monotonic() >= deadline:
            raise SystemExit(
                "benchmark geometry mismatch: "
                f"required {target.columns}x{target.lines}, "
                f"observed {observed.columns}x{observed.lines}"
            )
        sleep(0.005)


def run_workload(
    *,
    mode,
    target,
    terminal_size,
    monotonic,
    monotonic_ns,
    sleep,
    write,
    workload_chunks,
    await_start_ack,
    await_draw_result,
    acknowledge_geometry,
    write_result,
    backend,
    start_marker,
    completion,
    max_loop_iterations=None,
):
    """Run a benchmark only after geometry convergence, keeping the wait untimed."""
    achieved = wait_for_target_geometry(target, terminal_size, monotonic, sleep)
    acknowledge_geometry()
    if mode == "loop":
        iterations = 0
        while max_loop_iterations is None or iterations < max_loop_iterations:
            for chunk in workload_chunks():
                write(chunk)
            iterations += 1
        return

    write(start_marker)
    if backend == "swift":
        await_start_ack()

    started = monotonic_ns()
    for chunk in workload_chunks():
        write(chunk)
    write(completion)
    elapsed = monotonic_ns() - started
    write_result(elapsed, achieved)

    if backend == "swift":
        await_draw_result()


def wait_for_path(path, timeout_message):
    """Wait for one app-side benchmark acknowledgment with a bounded timeout."""
    deadline = time.monotonic() + 20
    while not os.path.exists(path):
        if time.monotonic() >= deadline:
            raise SystemExit(timeout_message)
        time.sleep(0.005)


def main():
    """Load the harness contract from the environment and run the producer."""
    environment = os.environ
    root = Path(__file__).resolve().parent.parent
    workload_name = environment["DANTERM_TERMINAL_BENCHMARK_WORKLOAD"]
    try:
        workload = load_corpus(root)[workload_name]
    except KeyError as error:
        raise SystemExit(f"unknown benchmark workload: {workload_name}") from error

    backend = environment["DANTERM_TERMINAL_BENCHMARK_BACKEND"]
    start_ack = environment["DANTERM_TERMINAL_BENCHMARK_START_ACK"]
    draw_result = environment["DANTERM_TERMINAL_BENCHMARK_RESULT"]
    geometry_ready = environment["DANTERM_TERMINAL_BENCHMARK_GEOMETRY_READY"]
    output = environment["DANTERM_TERMINAL_BENCHMARK_PRODUCER_RESULT"]
    target = os.terminal_size((
        int(environment["DANTERM_TERMINAL_BENCHMARK_COLUMNS"]),
        int(environment["DANTERM_TERMINAL_BENCHMARK_ROWS"]),
    ))
    completion = (
        "\x1b[0m\x1b[r\x1b[?1049l"
        + environment["DANTERM_TERMINAL_BENCHMARK_EXPECTED_FINAL_STATE"]
        + "\n"
        + environment["DANTERM_TERMINAL_BENCHMARK_COMPLETION_MARKER"]
        + "\n"
    ).encode()

    def write_result(elapsed, geometry):
        with open(output, "w", encoding="utf-8") as stream:
            json.dump({
                "clock": "python-monotonic-nanoseconds",
                "elapsedNanoseconds": elapsed,
                "event": "producer-final-write-returned",
                "geometry": {"columns": geometry.columns, "rows": geometry.lines},
            }, stream, sort_keys=True)

    try:
        run_workload(
            mode=environment.get("DANTERM_BENCHMARK_MODE", "measure"),
            target=target,
            terminal_size=lambda: os.get_terminal_size(1),
            monotonic=time.monotonic,
            monotonic_ns=time.monotonic_ns,
            sleep=time.sleep,
            write=lambda chunk: write_all(1, chunk),
            workload_chunks=lambda: iter_bytes(root, workload),
            await_start_ack=lambda: wait_for_path(
                start_ack, "timed out waiting for app-side start-marker observation"
            ),
            await_draw_result=lambda: wait_for_path(
                draw_result, "timed out waiting for final draw acknowledgment"
            ),
            acknowledge_geometry=lambda: Path(geometry_ready).touch(),
            write_result=write_result,
            backend=backend,
            start_marker=(environment["DANTERM_TERMINAL_BENCHMARK_START_MARKER"] + "\n").encode(),
            completion=completion,
        )
    except SystemExit as error:
        with open(output, "w", encoding="utf-8") as stream:
            json.dump({"error": str(error)}, stream, sort_keys=True)
        raise


if __name__ == "__main__":
    main()
