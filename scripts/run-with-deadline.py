#!/usr/bin/env python3
"""Runs one command behind a hard deadline and terminates its whole process tree."""

import os
import signal
import subprocess
import sys
import time


class ForwardedSignal(Exception):
    """Carries a wrapper signal into normal process-tree cleanup."""

    def __init__(self, signal_number: int) -> None:
        super().__init__(signal_number)
        self.signal_number = signal_number


def forward_signal(signal_number: int, _frame: object) -> None:
    """Turns wrapper termination into cleanup the main wait can handle."""
    raise ForwardedSignal(signal_number)


def descendant_pids(root: int) -> list[int]:
    """Every live descendant of `root`, read before any signal is sent.

    The snapshot has to come first: killing the group reparents whatever escaped
    it to pid 1, which erases the only evidence that those processes belonged to
    this command at all.
    """
    listing = subprocess.run(
        ["ps", "-eo", "pid=,ppid="], capture_output=True, text=True, check=False).stdout
    children: dict[int, list[int]] = {}
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        try:
            pid, parent = int(fields[0]), int(fields[1])
        except ValueError:
            continue
        children.setdefault(parent, []).append(pid)

    found: list[int] = []
    pending = [root]
    while pending:
        for child in children.get(pending.pop(), []):
            found.append(child)
            pending.append(child)
    return found


def still_alive(pids: list[int]) -> list[int]:
    """The subset of `pids` this process can still signal."""
    alive = []
    for pid in pids:
        try:
            os.kill(pid, 0)
            alive.append(pid)
        except OSError:
            pass
    return alive


def terminate_process_tree(process: subprocess.Popen[bytes]) -> None:
    """Stops the command and every descendant, inside its process group or not.

    A group-only kill is not enough. SwiftPM's test binary runs in a session of
    its own, so it survives the signal aimed at the group, is reparented to pid
    1, and keeps burning a core until someone notices -- one was found 44 minutes
    after the deadline that was supposed to have ended it.
    """
    escapees = descendant_pids(process.pid)

    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        # The group is already gone, but its escapees below may not be. Reap the
        # command itself so this wrapper does not exit over a zombie of its own.
        process.wait()
    else:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()

    # SIGKILL, not SIGTERM: a process wedged badly enough to reach the deadline
    # has already shown that it will not act on a request to stop.
    for pid in still_alive(escapees):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass

    # A pid is signalable until it is reaped, and these are not this process's
    # children to reap, so give the kernel a moment before believing a survivor.
    for _ in range(20):
        survivors = still_alive(escapees)
        if not survivors:
            return
        time.sleep(0.1)
    print(
        f"warning: {len(survivors)} descendant(s) survived cleanup: "
        f"{' '.join(str(pid) for pid in survivors)}",
        file=sys.stderr)


def main() -> int:
    """Returns the command status, or 124 after enforcing the requested deadline."""
    if len(sys.argv) < 4:
        print(
            "usage: run-with-deadline.py SECONDS DESCRIPTION COMMAND [ARG ...]",
            file=sys.stderr,
        )
        return 2

    try:
        seconds = int(sys.argv[1])
    except ValueError:
        print("deadline must be a positive integer", file=sys.stderr)
        return 2
    if seconds <= 0:
        print("deadline must be a positive integer", file=sys.stderr)
        return 2

    description = sys.argv[2]
    process = subprocess.Popen(sys.argv[3:], start_new_session=True)
    signal.signal(signal.SIGTERM, forward_signal)
    try:
        return process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        print(f"{description} exceeded {seconds}s; terminating its process tree", file=sys.stderr)
        terminate_process_tree(process)
        return 124
    except KeyboardInterrupt:
        terminate_process_tree(process)
        return 130
    except ForwardedSignal as interruption:
        terminate_process_tree(process)
        return 128 + interruption.signal_number


if __name__ == "__main__":
    raise SystemExit(main())
