#!/usr/bin/env python3
"""Runs one command behind a hard deadline and terminates its whole process group."""

import os
import signal
import subprocess
import sys


class ForwardedSignal(Exception):
    """Carries a wrapper signal into normal process-group cleanup."""

    def __init__(self, signal_number: int) -> None:
        super().__init__(signal_number)
        self.signal_number = signal_number


def forward_signal(signal_number: int, _frame: object) -> None:
    """Turns wrapper termination into cleanup the main wait can handle."""
    raise ForwardedSignal(signal_number)


def terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    """Stops the command and every descendant without leaving a wedged test helper."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return

    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


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
        print(f"{description} exceeded {seconds}s; terminating its process group", file=sys.stderr)
        terminate_process_group(process)
        return 124
    except KeyboardInterrupt:
        terminate_process_group(process)
        return 130
    except ForwardedSignal as interruption:
        terminate_process_group(process)
        return 128 + interruption.signal_number


if __name__ == "__main__":
    raise SystemExit(main())
