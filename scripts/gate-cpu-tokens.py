#!/usr/bin/env python3
"""Hold a share of one machine-wide CPU budget while a single gate step runs.

`scripts/run-test-suite.sh` already bounds how many compile jobs one `just test`
asks the machine for -- but that bound is per process. Several agents, each in its
own worktree, each politely reserve the same cores, so N concurrent gates
oversubscribe the host by N and every one of them gets slower than a serial run
would have been. This lifts the identical budget to the machine: the tokens live
in one directory under the user's cache, so every gate on the host draws from one
pool no matter which checkout it runs in.

Two decisions carry the design:

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

Acquiring several tokens at once could deadlock -- two claimants each holding half
of what they need -- so claimants are serialized behind one admission lock. That
cannot deadlock in turn, because a claimant that already holds tokens is running a
step, and a step never asks for more.
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


def acquire(root: Path, pool: int, weight: int) -> list[int]:
    """Claims `weight` of `pool` tokens, blocking until all of them are in hand.

    Returns the held descriptors. The caller holds them open for the life of the step
    and never passes them on: they stay close-on-exec, so nothing the step spawns can
    inherit the claim and outlive it.
    """
    root.mkdir(parents=True, exist_ok=True)

    # Serializes claimants. Without it, two claimants can each hold part of what the
    # other needs and neither can finish. Holding it while blocking is safe: the
    # claimants it excludes are not the processes that release tokens.
    admission = os.open(root / "admission.lock", os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(admission, fcntl.LOCK_EX)

    held: list[int] = []
    held_indices: set[int] = set()
    try:
        while len(held) < weight:
            for index in range(1, pool + 1):
                if len(held) >= weight:
                    break
                if index in held_indices:
                    continue
                descriptor = os.open(token_path(root, index), os.O_RDWR | os.O_CREAT, 0o600)
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    os.close(descriptor)
                    continue
                held.append(descriptor)
                held_indices.add(index)
            if len(held) < weight:
                time.sleep(POLL_INTERVAL_SECONDS)
    finally:
        os.close(admission)

    return held


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weight", type=int, required=True,
                        help="tokens this step holds, normally its SwiftPM job cap")
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
    # A request bigger than the whole pool could never be satisfied, so it would block
    # forever and read as a hung gate with no output. Clamping turns the worst case into
    # a serial gate instead.
    weight = min(max(1, options.weight), pool)

    started = time.monotonic()
    # Bound to a name only to keep the descriptors open: the claim lasts exactly as long
    # as this process holds them, which is exactly as long as the step below runs.
    held = acquire(token_pool_root(), pool, weight)  # noqa: F841
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
    # pass the claim on to anything it spawns.
    try:
        completed = subprocess.run(command)
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
