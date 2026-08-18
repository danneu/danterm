#!/bin/bash
# Runs T19 end to end against a throwaway slot: capture the follow stream's
# wire bytes for the three workloads the task names -- an interactive session,
# a build log, and an idle pane -- into t19-artifacts/, then print the analysis.
#
# Each scenario opens its own subscription, the way the phone joins (follow,
# reconstructible, from now), so every capture also records its own join
# prefix; the analyzer accounts join and steady separately. The pane grid is
# pinned to 80x24 so the three captures and any rerun share one geometry.
#
# Usage: t19-run.sh <slot-socket>
#
# The PATH `danterm` is the production release and can predate the slot's
# protocol, so this script uses the CLI bundled with the build it launched;
# override with DANTERM_BIN.
set -eu

SOCKET="$1"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
ART="$HERE/t19-artifacts"
DANTERM="${DANTERM_BIN:-$ROOT/.build/DanTerm Dev.app/Contents/Helpers/danterm}"
mkdir -p "$ART"

GROUP="$("$DANTERM" --socket "$SOCKET" ls | jq -r '.groups[0].id')"
PANE="$("$DANTERM" --socket "$SOCKET" tab new --group "$GROUP" --cwd "$ROOT" --title t19 \
  | jq -r '.panes[0].id')"
"$DANTERM" --socket "$SOCKET" pane resize --pane "$PANE" 80x24 > /dev/null
sleep 3

CAPTURE_PID=""

start_capture() {
  local name="$1"
  rm -f "$ART/$name.ready"
  python3 "$HERE/t19-wire-capture.py" capture "$SOCKET" "$PANE" \
    --out "$ART/$name" --ready-file "$ART/$name.ready" &
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

key() {
  "$DANTERM" --socket "$SOCKET" pane input --pane "$PANE" -- "$@"
}

type_chars() {
  local text="$1" i
  for ((i = 0; i < ${#text}; i++)); do
    "$DANTERM" --socket "$SOCKET" pane input --pane "$PANE" --literal -- "${text:$i:1}"
    sleep 0.12
  done
}

echo "== scenario 1: interactive session =="
start_capture interactive
type_chars "git status"
key Enter; sleep 3
type_chars "head -40 README.md"
key Enter; sleep 3
type_chars "vim"
key Enter; sleep 3
key i
type_chars "T19 measures what the tape stream costs on the wire."
sleep 1
key Escape; type_chars ":q!"; key Enter; sleep 2
type_chars "git log --oneline | head -15"
key Enter; sleep 3
key Up; sleep 1
key C-c; sleep 1
stop_capture

echo "== scenario 2: build log =="
find "$ROOT/lib/TerminalCore/Sources" -name '*.swift' -exec touch {} +
start_capture build
key 'swift build --package-path lib/TerminalCore 2>&1' Enter
for _ in $(seq 1 60); do
  sleep 5
  if "$DANTERM" --socket "$SOCKET" pane read --pane "$PANE" \
    | grep -q 'Build complete\|error:'; then
    break
  fi
done
sleep 2
stop_capture

echo "== scenario 3: idle pane (120s) =="
python3 "$HERE/t19-wire-capture.py" capture "$SOCKET" "$PANE" \
  --out "$ART/idle" --ready-file "$ART/idle.ready" --duration 120

"$DANTERM" --socket "$SOCKET" tab close \
  --tab "$("$DANTERM" --socket "$SOCKET" pane info --pane "$PANE" | jq -r '.tab.id')"

python3 "$HERE/t19-wire-capture.py" analyze \
  "$ART/interactive" "$ART/build" "$ART/idle" | tee "$ART/summary.json"
