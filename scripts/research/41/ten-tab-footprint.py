#!/usr/bin/env python3
"""Research 41's tier-1 reading: DanTerm's footprint with ten idle tabs open.

One optimized dev slot, staged the way termwars' memory harness stages it --
seeded font, ten inert tabs, the calibrated window geometry, every pane read
back at the benchmark grid -- then a settle and a run of `footprint` samples
over the slot bundle's pid set. Prints one JSON document and stops the slot.

This is the number an agent reads while changing DanTerm, and it is the same
quantity the harness reads at lower rigor: one slot, one arm, no interleaved
control. It steers the edit loop; it makes no claim. A claim is a paired
harness run recorded in docs/research/41-baseline-memory-ten-tabs/series.md.

Staging is borrowed from termwars' adapter rather than reimplemented, so the
grid is read back through the same `pane rows` path and a mismatch fails here
the way it fails there. The adapter takes focus briefly to size the window,
which is why this is not a gate test.

    python3 scripts/research/41/ten-tab-footprint.py [--arm tabs-scrollback-visible]
        [--tabs 10] [--settle 5] [--samples 10] [--interval 1]
        [--termwars ~/Code/termwars] [--hold]

The document also carries the app's own surface attribution, read with `danterm
surfaces` from the sampled process before the slot is stopped. It says what the
app owns and explains the total; the total still decides.

`--hold` prints the document as soon as the samples are in, with the measured
pids at the top level, and then keeps the slot alive until stdin gives a line
or SIGINT arrives. That is how a per-class capture (`vmmap`, `footprint`) is
taken against the same staged process the samples came from.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKOUT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))


def git(*arguments: str) -> str:
    return subprocess.run(
        ["git", "-C", CHECKOUT, *arguments], capture_output=True, text=True,
    ).stdout.strip()


def wait_for_release() -> None:
    """Block while a caller reads the live process, then let the slot be quit.

    Stdin is the release channel so a background run can be freed by appending
    to a fifo or a file; SIGINT is the interactive equivalent. Either way the
    caller's `finally` still quits the slot, so no path leaks it.
    """
    print(
        "held: the slot is up. Send a line on stdin (or SIGINT) to quit it.",
        file=sys.stderr,
        flush=True,
    )
    try:
        sys.stdin.readline()
    except KeyboardInterrupt:
        pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--arm", default="tabs-empty-visible")
    parser.add_argument("--tabs", type=int, default=10)
    parser.add_argument("--settle", type=float, default=5.0)
    parser.add_argument("--samples", type=int, default=10)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument(
        "--hold",
        action="store_true",
        help="print the document, then keep the slot alive until stdin or SIGINT",
    )
    parser.add_argument(
        "--termwars",
        default=os.environ.get("TERMWARS_CHECKOUT", "~/Code/termwars"),
        help="the termwars checkout whose adapter stages the slot",
    )
    arguments = parser.parse_args(argv)

    termwars = os.path.expanduser(arguments.termwars)
    if not os.path.isdir(os.path.join(termwars, "termwars")):
        print(f"no termwars package under {termwars}", file=sys.stderr)
        return 2
    sys.path.insert(0, termwars)
    # The adapter builds and stages whatever DANTERM_CHECKOUT names; pin it to
    # the tree this script lives in so a reading is of the revision reported.
    os.environ["DANTERM_CHECKOUT"] = CHECKOUT

    from termwars.adapters.danterm import DanTermAdapter  # noqa: E402
    from termwars.runner import release_writers, reset_writers  # noqa: E402
    from termwars.sample import sample  # noqa: E402
    from termwars.trial import ARMS, TrialConfig  # noqa: E402

    if arguments.arm not in ARMS:
        print(f"unknown arm {arguments.arm!r}; one of {sorted(ARMS)}", file=sys.stderr)
        return 2
    arm = ARMS[arguments.arm]
    config = TrialConfig(tabs=arguments.tabs)

    run_dir = tempfile.mkdtemp(prefix="r41-", dir=os.path.join(CHECKOUT, ".run"))
    adapter = DanTermAdapter(run_dir)
    problems = adapter.preflight_problems()
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        shutil.rmtree(run_dir, ignore_errors=True)
        return 1

    started = time.monotonic()
    printed = False
    document: dict = {
        "research": "41",
        "tier": 1,
        "commit": git("rev-parse", "--short", "HEAD"),
        "dirty": bool(git("status", "--porcelain", "--untracked-files=no")),
        "arm": arm.name,
        "requestedGrid": [config.columns, config.rows],
        "tabs": config.tabs,
        "font": [config.fontFamily, config.fontSize],
        "settleSeconds": arguments.settle,
        "sampleSeconds": arguments.samples * arguments.interval,
    }
    try:
        reset_writers(run_dir, arm)
        adapter.launch(config, arm)
        adapter.open_units(config.tabs)
        adapter.request_grid(config.columns, config.rows)
        release_writers(run_dir, arm, config.tabs, log=lambda *_: None)
        document["achievedGrids"] = adapter.achieved_grids()
        document["version"] = adapter.version()
        time.sleep(arguments.settle)
        samples = []
        for index in range(arguments.samples):
            reading = sample(adapter.pids(), round(time.monotonic() - started, 3))
            samples.append(reading.as_json())
            if index + 1 < arguments.samples:
                time.sleep(arguments.interval)
        document["samples"] = samples
        footprints = [s["physFootprintBytes"] for s in samples]
        document["medianPhysFootprintBytes"] = int(statistics.median(footprints))
        document["spreadBytes"] = max(footprints) - min(footprints)
        document["processes"] = len(samples[-1]["measuredPids"])
        document["missingPids"] = sorted({p for s in samples for p in s["missingPids"]})
        document["environment"] = adapter.environment_notes()
        # The app's own attribution, read from the same process the samples came
        # from and while it is still up. It explains the total; it never replaces
        # it (research/41 D1). A read that failed is recorded as unmeasured, so
        # the key is always present and never a zero standing in for no answer.
        try:
            document["surfaces"] = json.loads(adapter.control("debug", "surfaces"))
            document["surfaces"]["status"] = "ok"
        except Exception as failure:
            document["surfaces"] = {
                "status": "unmeasured",
                "error": f"{type(failure).__name__}: {failure}",
            }
        document["status"] = "ok"
        if arguments.hold:
            document["pids"] = sorted(adapter.pids())
            print(json.dumps(document, indent=2), flush=True)
            printed = True
            wait_for_release()
    except Exception as failure:  # recorded, never dropped
        document["status"] = "failed"
        document["error"] = f"{type(failure).__name__}: {failure}"
    finally:
        adapter.quit()
        # The slot is gone, so nothing is left to read the gate or the
        # done files. Leaving them behind accumulates one directory per
        # reading under the checkout's .run, which is not this script's
        # to grow.
        shutil.rmtree(run_dir, ignore_errors=True)

    if not printed:
        print(json.dumps(document, indent=2))
    return 0 if document["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
