#!/bin/bash
# Runs the T23 smoke end to end: launch the spike on the phone in client mode,
# drive the real Mac pane while it watches, and leave the console log behind.
#
# The launch is backgrounded and the launcher killed afterwards because
# `devicectl device process launch --console` never returns: the app does not
# exit, so it prints "Waiting for the application to terminate..." forever. This
# is the same shape as .build-ios-spike/replicate-energy.sh.
#
# The listener must already be running. It is a separate process on purpose --
# it holds the listener and this script holds none of it.
#
# T5 replaced the throwaway relay this originally drove with the tailnet bridge,
# so there is no token: the bridge authenticates by being reachable only on the
# tailnet. Start it with
# `t5-bridge --listen "$(tailscale ip -4):7420" --socket <slot-socket>`.
#
# Usage: t23-run.sh <slot-socket> <pane-id> <host> <port> [seconds]
set -eu

SOCKET="$1"
PANE="$2"
HOST="$3"
PORT="$4"
SECONDS_TO_RUN="${5:-40}"

DEVICE=93E093CD-0A20-5382-A4ED-1AE8E94B19AE
BUNDLE=com.danneu.danterm.ios-render-spike
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LOG="$ROOT/.build-ios-spike/console-t23-client.log"

echo "== launching the client smoke on $DEVICE =="
xcrun devicectl device process launch --device "$DEVICE" --console \
  -e "{\"SPIKE_MODE\":\"client\",\"T23_HOST\":\"$HOST\",\"T23_PORT\":\"$PORT\",\"T23_PANE\":\"$PANE\"}" \
  "$BUNDLE" > "$LOG" 2>&1 &
LAUNCHER=$!

# The phone joins with `start: now`, so everything the pane emits before it
# subscribes arrives inside the opening sync instead of as live events -- and a
# run that drove the pane on a fixed timer measured exactly that, with
# appliedEvents=0. Wait for the phone to say it applied its sync before driving
# anything, so the live-follow half is genuinely exercised.
for _ in $(seq 1 60); do
  if grep -q 'T23 sync applied' "$LOG" 2>/dev/null; then break; fi
  sleep 1
done
if ! grep -q 'T23 sync applied' "$LOG" 2>/dev/null; then
  echo "the phone never applied a sync; see $LOG" >&2
  kill "$LAUNCHER" 2>/dev/null || true
  exit 1
fi
echo "== phone is synchronized =="

echo "== driving the pane =="
danterm --socket "$SOCKET" pane input --pane "$PANE" -- 'printf "T23 LIVE %s\n" one two three' Enter
sleep 2
danterm --socket "$SOCKET" pane input --pane "$PANE" -- 'ls -la /usr/bin | head -20' Enter
sleep 3
# A full-screen program, then its exit: F4 showed the visible screen heals by
# itself through a prompt repaint, so what this stretch is really for is the
# console report's modes and scrollback afterwards, not the screen.
danterm --socket "$SOCKET" pane input --pane "$PANE" -- 'vim /tmp/t23-scratch.txt' Enter
sleep 4
danterm --socket "$SOCKET" pane input --pane "$PANE" -- i
danterm --socket "$SOCKET" pane input --pane "$PANE" --literal -- 'T23 typed inside vim'
sleep 2
danterm --socket "$SOCKET" pane input --pane "$PANE" -- Escape ':q!' Enter
sleep 3
danterm --socket "$SOCKET" pane input --pane "$PANE" -- 'echo T23 AFTER VIM' Enter

sleep "$SECONDS_TO_RUN"

# Convergence, the F4 check moved onto the phone: the replica's viewport against
# the source pane's own `pane read`, over the same normalization on both sides
# (trailing spaces per row stripped, trailing blank rows dropped).
MAC_DIGEST="$(danterm --socket "$SOCKET" pane read --pane "$PANE" | python3 -c '
import sys
rows = sys.stdin.read().split("\n")
rows = [row.rstrip(" ") for row in rows]
while rows and rows[-1] == "":
    rows.pop()
digest = 0xcbf29ce484222325
for byte in "\n".join(rows).encode():
    digest = ((digest ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
print(f"{digest:016x} rows={len(rows)}")
')"

kill "$LAUNCHER" 2>/dev/null || true
wait "$LAUNCHER" 2>/dev/null || true

echo "== console: $LOG =="
grep '^SPIKE' "$LOG" || true

# tr: the device console's lines carry a trailing carriage return, which made an
# identical digest compare unequal.
PHONE_DIGEST="$(grep 'T23 REPORT-DIGEST' "$LOG" | tail -1 | tr -d '\r' | sed 's/^SPIKE T23 REPORT-DIGEST //')"
echo
echo "mac   viewport digest: $MAC_DIGEST"
echo "phone viewport digest: $PHONE_DIGEST"
if [ "$MAC_DIGEST" = "$PHONE_DIGEST" ]; then
  echo "CONVERGED"
else
  echo "DIVERGED"
fi
