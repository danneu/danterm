#!/usr/bin/env python3
"""Hold a share of one machine-wide CPU budget while a single gate step runs.

`scripts/run-test-suite.sh` already bounds how many compile jobs one `just test`
asks the machine for -- but that bound is per process. Several agents, each in its
own worktree, each politely reserve the same cores, so N concurrent gates
oversubscribe the host by N and every one of them gets slower than a serial run
would have been. This lifts the identical budget to the machine: the tokens live
in one directory under the user's cache, so every gate on the host draws from one
pool no matter which checkout it runs in.

Three decisions carry the design:

  * **One firm token, extras only if free.** A claimant polls until it holds
    exactly one token, then takes up to `ask - 1` more in a single non-blocking
    sweep and never waits for them. Because no claimant ever waits while holding,
    deadlock is structurally impossible, so there is no admission lock and no
    retry ordering to reason about. The step is told what it got through
    DANTERM_SWIFT_JOBS, so a reservation always stands behind real work: a step
    can never ask SwiftPM for more compile jobs than the tokens it holds.
  * **Locks, not a counter.** Tokens are flock(2) on files, the idiom
    `scripts/dev-slot-launcher.py` already uses for development slots. The kernel
    releases them, so a step that fails, hangs, or is killed returns its share
    with no cleanup path that could be wrong. A counter in a file would need one.
  * **A supervisor holds the tokens, not the step.** This script runs the step as
    a child and waits, rather than exec'ing the step over itself. Handing the
    descriptors to the step looks simpler and is wrong: descriptors are inherited
    transitively, so a step that leaves anything running -- a PTY child, a spawned
    server, a launched app -- would leave the gate's CPU tokens held by that
    survivor for as long as it lived. Keeping them here, where they are
    close-on-exec, binds the claim to exactly the span the step runs for. A killed
    supervisor still releases through the kernel, so the crash path needs no
    cleanup code that could be wrong.
"""

from __future__ import annotations

import argparse
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import time

# Long enough that a pool under contention costs no measurable CPU to wait on, short
# enough to be invisible against gate steps measured in seconds.
POLL_INTERVAL_SECONDS = 0.05


def token_pool_root() -> Path:
    """Locates the one pool every gate on this host shares.

    The environment override is a test seam: the self-tests must never draw on the
    real pool, or they would contend with a gate actually running on the machine.
    """
    override = os.environ.get("DANTERM_GATE_TOKEN_DIR")
    if override:
        return Path(override)
    return Path.home() / "Library" / "Caches" / "com.danneu.danterm-gate-tokens"


def token_path(root: Path, index: int) -> Path:
    """Names one token so the pool is legible to anyone who lists the directory."""
    return root / f"cpu-{index}.lock"


def try_claim(root: Path, index: int) -> int | None:
    """Takes one token if it is free right now, else leaves it untouched."""
    descriptor = os.open(token_path(root, index), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(descriptor)
        return None
    return descriptor


def acquire(root: Path, pool: int, ask: int) -> list[int]:
    """Claims one token, blocking until it is in hand, plus free extras up to `ask`.

    Returns the held descriptors. The caller holds them open for the life of the step
    and never passes them on: they stay close-on-exec, so nothing the step spawns can
    inherit the claim and outlive it.
    """
    root.mkdir(parents=True, exist_ok=True)

    held: dict[int, int] = {}
    while not held:
        for index in range(1, pool + 1):
            descriptor = try_claim(root, index)
            if descriptor is not None:
                held[index] = descriptor
                break
        if not held:
            time.sleep(POLL_INTERVAL_SECONDS)

    # Extras are taken from whatever is free at this instant and never waited for.
    # Waiting here is what would need an admission lock to stay deadlock-free.
    for index in range(1, pool + 1):
        if len(held) >= ask:
            break
        if index in held:
            continue
        descriptor = try_claim(root, index)
        if descriptor is not None:
            held[index] = descriptor

    return list(held.values())


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ask", type=int, required=True,
                        help="tokens this step may use; one is claimed firmly, the "
                             "rest only if free right now")
    parser.add_argument("--pool", type=int, required=True,
                        help="total tokens on this machine, the gate's core budget")
    parser.add_argument("command", nargs=argparse.REMAINDER,
                        help="the step to run, after a bare --")
    options = parser.parse_args(argv)

    command = options.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("no command given")

    pool = max(1, options.pool)
    ask = max(1, options.ask)

    started = time.monotonic()
    held = acquire(token_pool_root(), pool, ask)
    waited = time.monotonic() - started

    # Reported so a step's own duration stays comparable between a quiet machine and a
    # busy one: the runner subtracts this from the elapsed time it prints. Truncated
    # rather than rounded, because the runner measures elapsed time with bash's $SECONDS,
    # which truncates too -- rounding one side up makes the two errors compound into a
    # step that reports less time than it ran for.
    wait_file = os.environ.get("DANTERM_GATE_TOKEN_WAIT_FILE")
    if wait_file:
        Path(wait_file).write_text(f"{int(waited)}\n")

    # The descriptors stay close-on-exec, which is Python's default, so the step cannot
    # pass the claim on to anything it spawns. DANTERM_SWIFT_JOBS carries the claim's
    # size to the runner's swift shim, so SwiftPM parallelism follows the tokens held.
    try:
        completed = subprocess.run(
            command,
            env={**os.environ, "DANTERM_SWIFT_JOBS": str(len(held))},
        )
    except OSError as error:
        print(f"gate-cpu-tokens: cannot run {command[0]}: {error}", file=sys.stderr)
        return 127

    # Report a signalled step the way a shell does, so the runner sees the status it
    # would have seen with no pool in front of the step.
    if completed.returncode < 0:
        return 128 - completed.returncode
    return completed.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
