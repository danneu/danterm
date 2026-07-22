#!/usr/bin/env python3
"""Emit one deterministic PTY workload and measure only blocking writes."""
import json
import os
import sys
import time

start_marker = os.environ["DANTERM_TERMINAL_BENCHMARK_START_MARKER"]
completion_marker = os.environ["DANTERM_TERMINAL_BENCHMARK_COMPLETION_MARKER"]
expected = os.environ["DANTERM_TERMINAL_BENCHMARK_EXPECTED_FINAL_STATE"]
start_ack = os.environ["DANTERM_TERMINAL_BENCHMARK_START_ACK"]
draw_result = os.environ["DANTERM_TERMINAL_BENCHMARK_RESULT"]
output = os.environ["DANTERM_TERMINAL_BENCHMARK_PRODUCER_RESULT"]
os.write(1, (start_marker + "\n").encode())
deadline = time.monotonic() + 20
while not os.path.exists(start_ack):
    if time.monotonic() >= deadline:
        raise SystemExit("timed out waiting for app-side start-marker observation")
    time.sleep(0.005)

started = time.monotonic_ns()
for index in range(20_000):
    os.write(1, f"DANTERM-BENCH-LINE-{index:05d} plain scrolling payload\n".encode())
os.write(1, (expected + "\n" + completion_marker + "\n").encode())
elapsed = time.monotonic_ns() - started
with open(output, "w", encoding="utf-8") as stream:
    json.dump({
        "clock": "python-monotonic-nanoseconds",
        "elapsedNanoseconds": elapsed,
        "event": "producer-final-write-returned",
    }, stream, sort_keys=True)

deadline = time.monotonic() + 20
while not os.path.exists(draw_result):
    if time.monotonic() >= deadline:
        raise SystemExit("timed out waiting for final draw acknowledgment")
    time.sleep(0.005)
