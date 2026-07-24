#!/usr/bin/env python3
"""Gate on target PTY geometry, then emit and time one deterministic workload."""
import json
import os
import time
from pathlib import Path

from terminal_benchmark_fixtures import iter_bytes, load_corpus, write_all


def localized_draw_update(sequence, row):
    """Build one fixed-row update whose marker lets the app acknowledge its draw."""
    marker = f"DANTERM-BENCH-LOCALIZED-{sequence:06d}"
    return (
        f"\x1b[{row};1H"
        f"\x1b[38;2;237;158;86m{marker}"
        "\x1b[38;2;129;202;191m status"
        "\x1b[38;2;207;171;224m metrics"
        "\x1b[0m\x1b[K"
    ).encode()


def localized_draw_ready(row):
    """Build the excluded settling update that drains setup invalidation."""
    return (
        f"\x1b[{row};1H"
        "\x1b[38;2;129;202;191mDANTERM-BENCH-LOCALIZED-READY"
        "\x1b[0m\x1b[K"
    ).encode()


def localized_draw_initial_screen(start_marker, columns, rows):
    """Build one dense styled screen before timing localized updates."""
    lines = ["\x1b[2J\x1b[H"]
    for row in range(1, rows + 1):
        label = start_marker if row == rows else f"localized draw baseline row {row:02d}"
        content = label.ljust(columns - 1)[:columns - 1]
        if row == rows:
            lines.append(f"\x1b[38;2;207;171;224m{content}\x1b[0m")
            continue
        cells = []
        for column in range(0, len(content), 4):
            red = 40 + (row * 13 + column * 7) % 180
            green = 40 + (row * 17 + column * 11) % 180
            blue = 40 + (row * 19 + column * 5) % 180
            cells.append(
                f"\x1b[38;2;{red};{green};{blue}m{content[column:column + 4]}"
            )
        lines.append("".join(cells) + "\x1b[0m")
        if row != rows:
            lines.append("\r\n")
    return "".join(lines).encode()


def run_localized_draw_workload(*, update_count, row, write, await_draw):
    """Serialize fixed-row updates by waiting for each real draw to complete."""
    for sequence in range(update_count):
        write(localized_draw_update(sequence, row))
        await_draw(sequence)


REDRAW_WORKLOADS = (
    "full-screen-content-churn",
    "full-screen-style-churn",
    "full-screen-mixed-churn",
    "full-screen-symbol-churn",
    "full-screen-sprite-coverage-churn",
)


BTOP_BOX_DRAWING = "\u2500\u2502\u250c\u2510\u2514\u2518\u251c\u2524\u252c\u2534\u253c"

# Explicit candidate sets keep benchmark coverage separate from a promise that
# every scalar in a neighboring Unicode block belongs on the sprite path.
SPRITE_COVERAGE_SETS = (
    tuple(range(0x2500, 0x2580)),
    tuple(range(0x2580, 0x25A0)),
    (0x25E2, 0x25E3, 0x25E4, 0x25E5, 0x25F8, 0x25F9, 0x25FA, 0x25FF),
    tuple(range(0x2800, 0x2900)),
)


def symbol_churn_content(sequence, row, width):
    """Build one btop-weighted row with 90% braille and 10% box drawing."""
    cells = []
    for column in range(width):
        index = row * width + column
        if index % 10 == 0:
            cells.append(BTOP_BOX_DRAWING[
                (sequence + row + column) % len(BTOP_BOX_DRAWING)
            ])
        else:
            pattern = 1 + (sequence * 37 + row * 17 + column * 29) % 255
            cells.append(chr(0x2800 + pattern))
    return "".join(cells)


def sprite_coverage_churn_content(sequence, row, width):
    """Build one row spread evenly across explicit sprite candidate sets."""
    cells = []
    for column in range(width):
        candidates = SPRITE_COVERAGE_SETS[(row * width + column) % 4]
        offset = (sequence * 37 + row * 17 + column * 29) % len(candidates)
        cells.append(chr(candidates[offset]))
    return "".join(cells)


def redraw_screen(workload, sequence, columns=179, rows=66):
    """Build one dense pseudo-TUI frame without scrolling or last-column writes."""
    if workload not in REDRAW_WORKLOADS and workload != "full-screen-incremental-mixed-churn":
        raise ValueError(f"unknown redraw workload: {workload}")
    if workload == "full-screen-incremental-mixed-churn" and sequence >= 0:
        return incremental_mixed_screen(sequence, columns, rows)
    title = (
        f"DANTERM-BENCH-REDRAW-{sequence:06d}"
        if sequence >= 0
        else "DANTERM-BENCH-REDRAW-SETUP"
    )
    lines = [f"\x1b]0;{title}\x07\x1b[H"]
    width = columns - 1
    for row in range(rows):
        if workload == "full-screen-symbol-churn":
            content = symbol_churn_content(sequence, row, width)
            style_sequence = 0
        elif workload == "full-screen-sprite-coverage-churn":
            content = sprite_coverage_churn_content(sequence, row, width)
            style_sequence = 0
        else:
            content_sequence = 0 if workload == "full-screen-style-churn" else sequence
            label = (
                f" {row + 1:02d}  branch feature/redraw  item "
                f"{(content_sequence * 17 + row * 7) % 10000:04d}  "
                f"{'working tree clean' if row % 3 else 'modified benchmark.swift'}"
            )
            content = label.ljust(width, ".")[:width]
            style_sequence = 0 if workload == "full-screen-content-churn" else sequence
        red = 40 + (style_sequence * 17 + row * 11) % 180
        green = 40 + (style_sequence * 23 + row * 13) % 180
        blue = 40 + (style_sequence * 29 + row * 7) % 180
        background = (
            18 + (style_sequence * 5 + row * 3) % 42,
            20 + (style_sequence * 7 + row * 5) % 42,
            24 + (style_sequence * 11 + row * 2) % 42,
        )
        lines.append(
            f"\x1b[38;2;{red};{green};{blue};48;2;"
            f"{background[0]};{background[1]};{background[2]}m{content}\x1b[0m"
        )
        if row != rows - 1:
            lines.append("\r\n")
    return "".join(lines).encode()


def incremental_mixed_rows(rows):
    """Choose a stable contiguous subset whose glyph halo remains bounded."""
    first = max(2, rows // 2 - 2)
    return tuple(range(first, min(rows, first + 4)))


def incremental_mixed_screen(sequence, columns=179, rows=66):
    """Change content and style on a deterministic subset of a settled screen."""
    title = f"DANTERM-BENCH-REDRAW-{sequence:06d}"
    lines = [f"\x1b]0;{title}\x07"]
    width = columns - 1
    for row in incremental_mixed_rows(rows):
        red = 40 + (sequence * 17 + row * 11) % 180
        green = 40 + (sequence * 23 + row * 13) % 180
        blue = 40 + (sequence * 29 + row * 7) % 180
        content = (
            f" {row:02d}  incremental item {(sequence * 31 + row * 7) % 10000:04d} "
            f"style {(sequence + row) % 97:02d}"
        ).ljust(width, ".")[:width]
        lines.append(
            f"\x1b[{row};1H\x1b[38;2;{red};{green};{blue}m"
            f"{content}\x1b[0m"
        )
    return "".join(lines).encode()


def run_redraw_workload(*, workload, update_count, write, await_draw):
    """Alternate one full-screen write with acknowledgment of that exact completed draw."""
    for sequence in range(update_count):
        write(redraw_screen(workload, sequence))
        await_draw(sequence)


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
    if mode == "persistent":
        return
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
    localized_update_count = int(
        environment.get("DANTERM_TERMINAL_BENCHMARK_LOCALIZED_UPDATES", "0")
    )
    redraw_update_count = int(
        environment.get("DANTERM_TERMINAL_BENCHMARK_REDRAW_UPDATES", "0")
    )
    if localized_update_count > 0 or redraw_update_count > 0:
        workload = None
    else:
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
        if localized_update_count > 0 or redraw_update_count > 0:
            achieved = wait_for_target_geometry(
                target, lambda: os.get_terminal_size(1), time.monotonic, time.sleep
            )
            Path(geometry_ready).touch()
            if environment.get("DANTERM_BENCHMARK_MODE") == "persistent":
                return
            if redraw_update_count > 0:
                write_all(1, redraw_screen(workload_name, -1, target.columns, target.lines))
                write_all(
                    1,
                    (
                        f"\x1b[{target.lines};1H"
                        + environment["DANTERM_TERMINAL_BENCHMARK_START_MARKER"]
                    ).encode(),
                )
            else:
                write_all(
                    1,
                    localized_draw_initial_screen(
                        environment["DANTERM_TERMINAL_BENCHMARK_START_MARKER"],
                        target.columns,
                        target.lines,
                    ),
                )
            wait_for_path(
                start_ack, "timed out waiting for app-side start-marker observation"
            )
            wait_for_path(
                environment["DANTERM_TERMINAL_BENCHMARK_START_DRAW_ACK"],
                "timed out waiting for start frame draw",
            )
            write_all(1, localized_draw_ready(max(1, target.lines // 2)))
            wait_for_path(
                environment["DANTERM_TERMINAL_BENCHMARK_READY_DRAW_ACK"],
                "timed out waiting for localized settling draw",
            )
            started = time.monotonic_ns()
            acknowledgment_prefix = environment[
                "DANTERM_TERMINAL_BENCHMARK_LOCALIZED_DRAW_ACK_PREFIX"
            ]
            await_draw = lambda sequence: wait_for_path(
                f"{acknowledgment_prefix}-{sequence:06d}",
                f"timed out waiting for completed draw {sequence}",
            )
            if redraw_update_count > 0:
                run_redraw_workload(
                    workload=workload_name,
                    update_count=redraw_update_count,
                    write=lambda chunk: write_all(1, chunk),
                    await_draw=await_draw,
                )
            else:
                run_localized_draw_workload(
                    update_count=localized_update_count,
                    row=max(1, target.lines // 2),
                    write=lambda chunk: write_all(1, chunk),
                    await_draw=await_draw,
                )
            write_all(1, completion)
            write_result(time.monotonic_ns() - started, achieved)
            wait_for_path(draw_result, "timed out waiting for final draw acknowledgment")
            return

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
