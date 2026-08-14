#!/bin/bash
# Runs the T5 measurement end to end: build and start the bridge on this Mac's
# tailnet address, then launch the latency probe on the phone against it.
#
# The launch is backgrounded and the launcher killed afterwards because
# `xcrun devicectl device process launch --console` never returns: the app does
# not exit, so it prints "Waiting for the application to terminate..." forever.
#
# The probe's third phase is a heartbeat that runs until this script kills it,
# and it is the only part that needs a human: switch the phone between wifi and
# cell FROM CONTROL CENTER while it beats. Going through the Settings app would
# background the spike, which suspends it, and would mix app backgrounding (T9's
# question) into the network switch (T5's).
#
# Usage: t5-run.sh <slot-socket> <pane-id> [samples] [heartbeat-seconds]
set -eu

SOCKET="$1"
PANE="$2"
SAMPLES="${3:-40}"
HEARTBEAT_SECONDS="${4:-180}"

DEVICE=93E093CD-0A20-5382-A4ED-1AE8E94B19AE
BUNDLE=com.danneu.danterm.ios-render-spike
PORT="${T5_PORT:-7420}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BRIDGE_DIR="$ROOT/docs/research/35-ios-remote-client/t5-bridge"
BRIDGE_LOG="$ROOT/.build/t5-bridge.log"
CONSOLE_LOG="$ROOT/.build/t5-console.log"

# The bridge refuses any address that is not a Tailscale address on this
# machine, so this is the only value it will accept -- and asking Tailscale for
# it beats hardcoding one that changes when the tailnet is rebuilt.
HOST="$(tailscale ip -4)"
echo "== tailnet address: $HOST =="

echo "== building the bridge =="
(cd "$BRIDGE_DIR" && swift build)

echo "== starting the bridge =="
"$BRIDGE_DIR/.build/debug/T5Bridge" --listen "$HOST:$PORT" --socket "$SOCKET" \
  > "$BRIDGE_LOG" 2>&1 &
BRIDGE=$!
trap 'kill "$BRIDGE" 2>/dev/null || true' EXIT
sleep 1
if ! kill -0 "$BRIDGE" 2>/dev/null; then
  echo "the bridge exited immediately; see $BRIDGE_LOG" >&2
  cat "$BRIDGE_LOG" >&2
  exit 1
fi

echo "== launching the probe on $DEVICE =="
xcrun devicectl device process launch --device "$DEVICE" --console \
  -e "{\"SPIKE_MODE\":\"t5\",\"T5_HOST\":\"$HOST\",\"T5_PORT\":\"$PORT\",\"T5_PANE\":\"$PANE\",\"T5_SAMPLES\":\"$SAMPLES\"}" \
  "$BUNDLE" > "$CONSOLE_LOG" 2>&1 &
LAUNCHER=$!

for _ in $(seq 1 90); do
  if grep -q 'T5 PHASE-C' "$CONSOLE_LOG" 2>/dev/null; then break; fi
  sleep 1
done
if ! grep -q 'T5 PHASE-C' "$CONSOLE_LOG" 2>/dev/null; then
  echo "the probe never reached the heartbeat phase; see $CONSOLE_LOG" >&2
  kill "$LAUNCHER" 2>/dev/null || true
  exit 1
fi

grep 'T5 BENCH' "$CONSOLE_LOG" || true
echo
echo "== heartbeat running for ${HEARTBEAT_SECONDS}s =="
echo "== switch the phone between wifi and cell FROM CONTROL CENTER now =="
sleep "$HEARTBEAT_SECONDS"

kill "$LAUNCHER" 2>/dev/null || true
wait "$LAUNCHER" 2>/dev/null || true

echo
echo "== beats =="
grep -E 'T5 BEAT|timed out' "$CONSOLE_LOG" | tr -d '\r' || true
echo
echo "== bridge =="
cat "$BRIDGE_LOG"
