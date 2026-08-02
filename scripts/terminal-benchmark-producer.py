#!/usr/bin/env python3
"""Gate on target PTY geometry, then emit and time one deterministic workload."""
import json
import os
import tempfile
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


# Closed set: exactly the full-screen draw workloads the paired ladder measures
# (`content-churn`, `style-churn`, `incremental-mixed`). A workload no recipe
# reaches is dead stimulus, so adding one here means adding it to the ladder.
REDRAW_WORKLOADS = (
    "full-screen-content-churn",
    "full-screen-style-churn",
    "full-screen-incremental-mixed-churn",
)


# The two topology-specific draw workloads. Separate from `REDRAW_WORKLOADS`
# because they are candidates rather than ladder members: the harness collects
# their blocks and no comparison decides them, so keeping them out of that tuple
# is what keeps its "every entry the paired ladder measures" contract true. They
# join it when a screened threshold graduates them into `WORKLOADS`.
SPARSE_SPAN_WORKLOADS = ("sparse-spans-few", "sparse-spans-max")


def sparse_span_rows(workload, rows=66):
    """Choose the ANSI rows whose engine damage carries the protected topology.

    Returned 1-based for cursor addressing; the contract they satisfy is stated
    in the engine's 0-based rows, because those are what the shared glyph halo
    consumes. At 66 rows `sparse-spans-few` damages engine rows 5 and 60 -- far
    enough apart that their halos stay disjoint -- which the halo draws as 6
    rows in 2 spans, and `sparse-spans-max` damages engine rows 0, 4, ..., 64,
    drawn as 50 rows in 17 spans. Stride four is the adversarial choice: stride
    two and three overlap into fewer, larger spans, so four maximizes the
    disjoint 3-row halo runs a compound clip must represent.
    """
    if workload == "sparse-spans-few":
        return (6, rows - 5)
    if workload == "sparse-spans-max":
        return tuple(range(1, rows + 1, 4))
    raise ValueError(f"unknown sparse-span workload: {workload}")


def sparse_span_screen(workload, sequence, columns=179, rows=66):
    """Change content and style on exactly one workload's sparse source rows.

    Every row is addressed absolutely and written one column short of the grid,
    so nothing wraps or scrolls into a row the topology contract does not
    include, and the sequence number rides the OSC title rather than a cell for
    the same reason.
    """
    lines = [f"\x1b]0;DANTERM-BENCH-REDRAW-{sequence:06d}\x07"]
    width = columns - 1
    for row in sparse_span_rows(workload, rows):
        red = 40 + (sequence * 17 + row * 11) % 180
        green = 40 + (sequence * 23 + row * 13) % 180
        blue = 40 + (sequence * 29 + row * 7) % 180
        content = (
            f" {row:02d}  sparse span item {(sequence * 31 + row * 7) % 10000:04d} "
            f"style {(sequence + row) % 97:02d}"
        ).ljust(width, ".")[:width]
        lines.append(
            f"\x1b[{row};1H\x1b[38;2;{red};{green};{blue}m{content}\x1b[0m"
        )
    return "".join(lines).encode()


def redraw_screen(workload, sequence, columns=179, rows=66):
    """Build one dense pseudo-TUI frame without scrolling or last-column writes."""
    if workload not in REDRAW_WORKLOADS + SPARSE_SPAN_WORKLOADS:
        raise ValueError(f"unknown redraw workload: {workload}")
    if workload in SPARSE_SPAN_WORKLOADS and sequence >= 0:
        return sparse_span_screen(workload, sequence, columns, rows)
    if workload == "full-screen-incremental-mixed-churn" and sequence >= 0:
        return incremental_mixed_screen(sequence, columns, rows)
    title = (
        f"DANTERM-BENCH-REDRAW-{sequence:06d}"
        if sequence >= 0
        else "DANTERM-BENCH-REDRAW-SETUP"
    )
    lines = [f"\x1b]0;{title}\x07\x1b[H"]
    width = columns - 1
    # Each workload freezes one axis: style-churn holds content still, content-churn
    # holds style still, so a measured difference names the work that changed.
    content_sequence = 0 if workload == "full-screen-style-churn" else sequence
    style_sequence = 0 if workload == "full-screen-content-churn" else sequence
    for row in range(rows):
        label = (
            f" {row + 1:02d}  branch feature/redraw  item "
            f"{(content_sequence * 17 + row * 7) % 10000:04d}  "
            f"{'working tree clean' if row % 3 else 'modified benchmark.swift'}"
        )
        content = label.ljust(width, ".")[:width]
        red =40 + (style_sequence * 17 + row * 11) % 180
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

    # Counted here rather than derived from the corpus at report time: the rate
    # this feeds (`20/D1`) is only as trustworthy as its denominator, and a
    # denominator recomputed later belongs to whatever corpus the reader loads
    # rather than to the corpus this block actually drained.
    written = 0
    started = monotonic_ns()
    for chunk in workload_chunks():
        write(chunk)
        written += len(chunk)
    write(completion)
    written += len(completion)
    elapsed = monotonic_ns() - started
    write_result(elapsed, achieved, written)

    if backend == "swift":
        await_draw_result()


def write_json_result(output, payload):
    """Publish one producer result so its existence implies its completeness.

    The harness waits on `producer-write.json` existing and then parses it, and
    the app writes `final-draw.json` concurrently -- so a destination truncated
    by `open(..., "w")` before `json.dump` returns is a readable empty file. The
    temporary is created in the destination's own directory because `os.replace`
    is only atomic within one filesystem, and a serialization that raises must
    leave the destination absent or its previous content intact.
    """
    directory = os.path.dirname(output) or "."
    descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=".producer-result-")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, sort_keys=True)
        os.replace(temporary, output)
    except BaseException:
        os.unlink(temporary)
        raise


def wait_for_path(path, timeout_message):
    """Wait for one app-side benchmark acknowledgment with a bounded timeout."""
    deadline = time.monotonic() + 20
    while not os.path.exists(path):
        if time.monotonic() >= deadline:
            raise SystemExit(timeout_message)
        time.sleep(0.005)


class AcknowledgmentLog:
    """Record which app-side acknowledgments a block reached before it gave up.

    A timeout message names only the acknowledgment that never arrived, which
    reads the same whether the block never started or stalled after 49 draws.
    The recorded set is what makes the two distinguishable in the run evidence.
    """

    def __init__(self, wait=None):
        self.observed = []
        self.awaiting = None
        self._wait = wait if wait is not None else wait_for_path

    def await_path(self, label, path, timeout_message):
        """Block on one acknowledgment, leaving the label recorded either way."""
        self.awaiting = label
        self._wait(path, timeout_message)
        self.observed.append(label)
        self.awaiting = None

    def evidence(self):
        """Report the acknowledgments observed and the one still outstanding."""
        return {"observed": list(self.observed), "awaiting": self.awaiting}


def completion_bytes(expected_final_state, completion_marker):
    """Build the trailer whose job is to force one final, visible draw.

    The prologue exists to undo whatever mode state the stimulus left behind, so
    the marker text is guaranteed to reach the screen: SGR, scroll region,
    alternate screen, and synchronized output. That last one is not decorative --
    `TerminalPaneSession.planIfNeeded` returns early while synchronized output is
    active, so a stimulus that ends with it set would suppress the very draw this
    trailer is here to produce, and the harness would wait for a draw that can
    never arrive. Every byte of the captured `synchronized-frames` workload sits
    inside such a bracket.
    """
    return (
        "\x1b[0m\x1b[r\x1b[?2026l\x1b[?1049l"
        + expected_final_state
        + "\n"
        + completion_marker
        + "\n"
    ).encode()


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
    completion = completion_bytes(
        environment["DANTERM_TERMINAL_BENCHMARK_EXPECTED_FINAL_STATE"],
        environment["DANTERM_TERMINAL_BENCHMARK_COMPLETION_MARKER"],
    )

    def write_result(elapsed, geometry, written=None):
        result = {
            "clock": "python-monotonic-nanoseconds",
            "elapsedNanoseconds": elapsed,
            "event": "producer-final-write-returned",
            "geometry": {"columns": geometry.columns, "rows": geometry.lines},
        }
        # Absent on the serialized-draw path on purpose. Those workloads write one
        # update and wait for that exact draw, so the bracket measures a handshake
        # and a byte count over it would divide into a rate that looks valid and
        # means nothing. Recording no count is what keeps it underivable.
        if written is not None:
            result["bytesWritten"] = written
        write_json_result(output, result)

    acknowledgments = AcknowledgmentLog()
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
            acknowledgments.await_path(
                "start-ack",
                start_ack,
                "timed out waiting for app-side start-marker observation",
            )
            acknowledgments.await_path(
                "start-draw-ack",
                environment["DANTERM_TERMINAL_BENCHMARK_START_DRAW_ACK"],
                "timed out waiting for start frame draw",
            )
            write_all(1, localized_draw_ready(max(1, target.lines // 2)))
            acknowledgments.await_path(
                "ready-draw-ack",
                environment["DANTERM_TERMINAL_BENCHMARK_READY_DRAW_ACK"],
                "timed out waiting for localized settling draw",
            )
            started = time.monotonic_ns()
            acknowledgment_prefix = environment[
                "DANTERM_TERMINAL_BENCHMARK_LOCALIZED_DRAW_ACK_PREFIX"
            ]
            await_draw = lambda sequence: acknowledgments.await_path(
                f"localized-draw-{sequence:06d}",
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
            acknowledgments.await_path(
                "final-draw",
                draw_result,
                "timed out waiting for final draw acknowledgment",
            )
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
            await_start_ack=lambda: acknowledgments.await_path(
                "start-ack",
                start_ack,
                "timed out waiting for app-side start-marker observation",
            ),
            await_draw_result=lambda: acknowledgments.await_path(
                "final-draw",
                draw_result,
                "timed out waiting for final draw acknowledgment",
            ),
            acknowledge_geometry=lambda: Path(geometry_ready).touch(),
            write_result=write_result,
            backend=backend,
            start_marker=(environment["DANTERM_TERMINAL_BENCHMARK_START_MARKER"] + "\n").encode(),
            completion=completion,
        )
    except SystemExit as error:
        write_json_result(output, {
            "error": str(error),
            "acknowledgments": acknowledgments.evidence(),
        })
        raise


if __name__ == "__main__":
    main()
