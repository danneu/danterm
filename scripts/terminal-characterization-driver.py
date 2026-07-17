#!/usr/bin/env python3
"""Controlled PTY child for Ghostty text and recovery characterization."""

import os
import pathlib
import signal
import sys
import termios


STATE_DIRECTORY = pathlib.Path(sys.argv[1])
HISTORY_CORPUS = b"".join(f"HISTORY-{index:02d}\r\n".encode("ascii") for index in range(1, 46))
PRIMARY_CORPUS = b"\x1b[3J\x1b[2J\x1b[H" + HISTORY_CORPUS + (
    b"HARD-BOUNDARY-A\r\nHARD-BOUNDARY-B\r\n"
    b"WRITTEN-SPACES:[  lead middle  trail  ]  \r\n"
    b"EMPTY-BEFORE\r\n\r\nEMPTY-AFTER\r\n"
    b"SPANISH: ni\xc3\xb1o, acci\xc3\xb3n, coraz\xc3\xb3n\r\n"
    b"CHINESE: \xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c\r\n"
    b"EMOJI: \xf0\x9f\x99\x82 \xf0\x9f\x9a\x80\r\n"
    b"LONG-LOGICAL:abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ-0123456789-end\r\n"
    b"CORPUS-END"
)
ALTERNATE_CORPUS = b"\x1b[?1049hALT-TRANSIENT\r\nALT-WRITTEN-SPACES:[  x  ]  "
RETURN_TO_PRIMARY = b"\x1b[?1049l\r\nRETURNED-PRIMARY"


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
    """Wait for signal-driven phases while keeping terminal bytes deterministic."""
    global phase
    STATE_DIRECTORY.mkdir(parents=True, exist_ok=True)
    disable_input_echo()
    signal.signal(signal.SIGUSR1, request_primary_or_return)
    signal.signal(signal.SIGUSR2, request_alternate)
    signal.signal(signal.SIGWINCH, request_size)
    write_state("pid", f"{os.getpid()}\n")
    record_size()
    write_state("ready")

    while True:
        signal.pause()
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
