#!/bin/bash
# Runs T21 plus T20's measurement arms against a throwaway slot, into
# t21-artifacts/. Run it against a `just launch-slot-optimized` slot: flood
# drain is compute bound, and a debug build measured ~29x slower than release.
#
# T21: bounded floods that time themselves with the shell's own `time`, so
# every scenario yields a producer-side drain rate next to the capture's wire
# rate. The `yes` flood is the throughput ceiling, the repeated cat of real
# Swift sources is the agent-output shape, and an uninstrumented `yes` run
# first gives the no-subscriber ablation. A control-plane probe (`ls`) is
# timed mid-flood, because the first debug run showed a C-c queueing ~27s
# behind an unbounded flood. The frame-coalesced diff bound the task compares
# against is arithmetic at the pinned 80x24 grid, not a capture.
#
# T20: for three pane states -- fresh, quiet-with-deep-history, flooding --
# capture a from-now join (what a sync costs) and a from-beginning join (what
# the retained backlog costs instead). The flood pane's history exceeds the
# recorder's 8 MiB ring by the end, so its from-beginning capture also shows
# what D5 injects when the requested position is evicted.
#
# Every pane is pinned to 80x24 so captures and reruns share one geometry.
#
# Usage: t21-run.sh <slot-socket>
#
# The PATH `danterm` is the production release and can predate the slot's
# protocol, so this script uses the CLI bundled with the build it launched;
# override with DANTERM_BIN.
set -eu

SOCKET="$1"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
ART="$HERE/t21-artifacts"
DANTERM="${DANTERM_BIN:-$ROOT/.build/DanTerm Dev.app/Contents/Helpers/danterm}"
mkdir -p "$ART"

GROUP="$("$DANTERM" --socket "$SOCKET" ls | jq -r '.groups[0].id')"

new_pane() {
  local title="$1" pane
  pane="$("$DANTERM" --socket "$SOCKET" tab new --group "$GROUP" --cwd "$ROOT" --title "$title" \
    | jq -r '.panes[0].id')"
  "$DANTERM" --socket "$SOCKET" pane resize --pane "$pane" 80x24 > /dev/null
  echo "$pane"
}

close_pane_tab() {
  "$DANTERM" --socket "$SOCKET" tab close \
    --tab "$("$DANTERM" --socket "$SOCKET" pane info --pane "$1" | jq -r '.tab.id')"
}

key() {
  local pane="$1"; shift
  "$DANTERM" --socket "$SOCKET" pane input --pane "$pane" -- "$@"
}

# Polls the pane viewport for a marker the stimulus prints when done. Markers
# are typed as `echo X@DONE | tr -d @` so the typed command line can never
# satisfy the grep that waits for the output.
wait_for() {
  local pane="$1" marker="$2" tries="$3"
  for _ in $(seq 1 "$tries"); do
    sleep 2
    if "$DANTERM" --socket "$SOCKET" pane read --pane "$pane" | grep -q "$marker"; then
      return 0
    fi
  done
  echo "marker $marker never appeared" >&2
  return 1
}

# The shell's `time` block for the scenario that just finished, from the
# viewport, into an artifact file.
save_time() {
  local pane="$1" name="$2"
  "$DANTERM" --socket "$SOCKET" pane read --pane "$pane" \
    | grep -A 3 "Executed in" | tail -4 > "$ART/$name.time.txt"
}

# Times one `ls` round trip while a flood is running; the request is allowed
# to be slow -- that latency is the measurement.
probe_control_latency() {
  local out="$1"
  python3 - "$DANTERM" "$SOCKET" "$ART/$out" <<'EOF'
import subprocess, sys, time
danterm, sock, out = sys.argv[1:4]
t0 = time.monotonic()
subprocess.run([danterm, "--socket", sock, "ls"], stdout=subprocess.DEVNULL)
open(out, "w").write(f"{time.monotonic() - t0:.3f}\n")
EOF
}

CAPTURE_PID=""

start_capture() {
  local name="$1" pane="$2"
  shift 2
  rm -f "$ART/$name.ready"
  python3 "$HERE/t19-wire-capture.py" capture "$SOCKET" "$pane" \
    --out "$ART/$name" --ready-file "$ART/$name.ready" "$@" &
  CAPTURE_PID=$!
  for _ in $(seq 1 60); do
    [ -f "$ART/$name.ready" ] && break
    sleep 0.25
  done
  [ -f "$ART/$name.ready" ] || { echo "capture $name never subscribed" >&2; exit 1; }
}

stop_capture() {
  kill -TERM "$CAPTURE_PID"
  wait "$CAPTURE_PID"
}

echo "== pane A: flood (T21, and T20's flooding arm) =="
PANE_A="$(new_pane t21-flood)"
sleep 3

echo "-- ablation-nosub: 1M-line yes, no subscriber --"
key "$PANE_A" 'time sh -c "yes | head -n 1000000" ; echo A0@DONE | tr -d @' Enter
wait_for "$PANE_A" A0DONE 30
save_time "$PANE_A" ablation-nosub

echo "-- flood-yes: 5M-line yes under capture, control probe mid-flood --"
start_capture flood-yes "$PANE_A"
key "$PANE_A" 'time sh -c "yes | head -n 5000000" ; echo A1@DONE | tr -d @' Enter
sleep 2
probe_control_latency control-latency-during-yes.txt
wait_for "$PANE_A" A1DONE 60
sleep 1
stop_capture
save_time "$PANE_A" flood-yes

echo "-- flood-cat: 4 passes of real Swift sources under capture --"
start_capture flood-cat "$PANE_A"
key "$PANE_A" "time sh -c 'for i in 1 2 3 4; do find lib/TerminalCore/Sources -name \"*.swift\" -exec cat {} + ; done' ; echo A2@DONE | tr -d @" Enter
wait_for "$PANE_A" A2DONE 60
sleep 1
stop_capture
save_time "$PANE_A" flood-cat

echo "-- sync-during-flood: T20's flooding-pane join --"
key "$PANE_A" 'time sh -c "yes | head -n 5000000" ; echo A3@DONE | tr -d @' Enter
sleep 1.5
python3 "$HERE/t19-wire-capture.py" capture "$SOCKET" "$PANE_A" \
  --out "$ART/sync-during-flood" --duration 3
wait_for "$PANE_A" A3DONE 60

echo "-- backlog-post-flood: from-beginning against an evicted ring --"
python3 "$HERE/t19-wire-capture.py" capture "$SOCKET" "$PANE_A" \
  --out "$ART/backlog-post-flood" --start beginning --duration 10

echo "== pane B: fresh (T20) =="
PANE_B="$(new_pane t20-fresh)"
sleep 3
python3 "$HERE/t19-wire-capture.py" capture "$SOCKET" "$PANE_B" \
  --out "$ART/sync-fresh" --duration 3
python3 "$HERE/t19-wire-capture.py" capture "$SOCKET" "$PANE_B" \
  --out "$ART/backlog-fresh" --start beginning --duration 3

echo "== pane C: quiet with deep history (T20) =="
PANE_C="$(new_pane t20-deep)"
sleep 3
key "$PANE_C" 'seq -f "history line %g of a quiet pane with deep scrollback" 1 30000 ; echo C1@DONE | tr -d @' Enter
wait_for "$PANE_C" C1DONE 30
sleep 2
python3 "$HERE/t19-wire-capture.py" capture "$SOCKET" "$PANE_C" \
  --out "$ART/sync-deep" --duration 4
python3 "$HERE/t19-wire-capture.py" capture "$SOCKET" "$PANE_C" \
  --out "$ART/backlog-deep" --start beginning --duration 10

close_pane_tab "$PANE_A"
close_pane_tab "$PANE_B"
close_pane_tab "$PANE_C"

python3 "$HERE/t19-wire-capture.py" analyze \
  "$ART/flood-yes" "$ART/flood-cat" "$ART/sync-during-flood" \
  "$ART/backlog-post-flood" "$ART/sync-fresh" "$ART/backlog-fresh" \
  "$ART/sync-deep" "$ART/backlog-deep" | tee "$ART/summary.json"
