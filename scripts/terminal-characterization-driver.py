#!/usr/bin/env python3
"""Controlled PTY child for Ghostty text and recovery characterization."""

import base64
import json
import os
import pathlib
import select
import signal
import sys
import termios


STATE_DIRECTORY = pathlib.Path(sys.argv[1])
FIXTURE_PATH = pathlib.Path(sys.argv[2])
with FIXTURE_PATH.open(encoding="utf-8") as fixture_file:
    REPLAY_EVENTS = json.load(fixture_file)["replay"]["events"]
REPLAY_FEEDS = [
    base64.b64decode(event["base64"], validate=True)
    if "base64" in event
    else bytes.fromhex(event["hex"])
    for event in REPLAY_EVENTS
    if event["type"] == "feed"
]
if len(REPLAY_FEEDS) != 3:
    raise ValueError("Characterization replay must contain primary, alternate, and return feeds")
PRIMARY_CORPUS, ALTERNATE_CORPUS, RETURN_TO_PRIMARY = REPLAY_FEEDS


def write_state(name: str, content: str = "ready\n") -> None:
    """Publish process state atomically without adding control traffic to the PTY."""
    temporary = STATE_DIRECTORY / f".{name}.{os.getpid()}"
    temporary.write_text(content, encoding="utf-8")
    temporary.replace(STATE_DIRECTORY / name)


def record_size() -> None:
    """Record the PTY dimensions observed by the child after a resize."""
    size = os.get_terminal_size(sys.stdin.fileno())
    write_state("size", f"{size.columns} {size.lines}\n")


def disable_input_echo() -> None:
    """Prevent terminal-generated input from contaminating the output corpus."""
    attributes = termios.tcgetattr(sys.stdin.fileno())
    attributes[3] &= ~(termios.ECHO | termios.ICANON)
    termios.tcsetattr(sys.stdin.fileno(), termios.TCSANOW, attributes)


phase = "waiting-primary"


def request_primary_or_return(_signum: int, _frame: object) -> None:
    """Advance from initial primary output or from alternate back to primary."""
    global phase
    if phase == "waiting-primary":
        phase = "emit-primary"
    elif phase == "alternate":
        phase = "return-primary"


def request_alternate(_signum: int, _frame: object) -> None:
    """Request the alternate-screen observation after primary captures finish."""
    global phase
    if phase == "primary":
        phase = "emit-alternate"


def request_size(_signum: int, _frame: object) -> None:
    """Record the latest PTY size for harness-driven resize synchronization."""
    record_size()


def main() -> None:
    """Drive output phases and record app-injected PTY bytes out of band."""
    global phase
    STATE_DIRECTORY.mkdir(parents=True, exist_ok=True)
    disable_input_echo()
    signal.signal(signal.SIGUSR1, request_primary_or_return)
    signal.signal(signal.SIGUSR2, request_alternate)
    signal.signal(signal.SIGWINCH, request_size)
    write_state("pid", f"{os.getpid()}\n")
    record_size()
    write_state("ready")

    input_path = STATE_DIRECTORY / "input-bytes"
    while True:
        readable, _, _ = select.select([sys.stdin.fileno()], [], [], 0.05)
        if readable:
            data = os.read(sys.stdin.fileno(), 4096)
            if data:
                with input_path.open("ab") as handle:
                    handle.write(data)
        if phase == "emit-primary":
            os.write(sys.stdout.fileno(), PRIMARY_CORPUS)
            phase = "primary"
            write_state("primary-ready")
        elif phase == "emit-alternate":
            os.write(sys.stdout.fileno(), ALTERNATE_CORPUS)
            phase = "alternate"
            write_state("alternate-ready")
        elif phase == "return-primary":
            os.write(sys.stdout.fileno(), RETURN_TO_PRIMARY)
            phase = "returned-primary"
            write_state("returned-primary-ready")


if __name__ == "__main__":
    main()
