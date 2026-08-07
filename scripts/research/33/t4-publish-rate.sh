#!/usr/bin/env bash
# Research doc 33, task T4: count published frames per second and draws per
# second in a live app, not in a benchmark block.
#
# Launches an isolated development slot with DANTERM_FRAME_RATE_LOG set, runs a
# real `cat` of a large file in a real pane, and reduces the per-second samples
# the app appended. H2 predicts publishes/s far above the display rate -- 23/F5
# read roughly 8 publishes per draw. A live ratio near 1:1 closes T10.
#
# A hidden pane plans and draws nothing, so the slot's window has to be on
# screen for the duration: the script activates the slot it launched and hands
# the front back to whichever app held it. The slot still launches with
# `--background`, which is what refuses the notification prompt, so activating
# it afterwards cannot raise one.
#
# Usage: scripts/research/33/t4-publish-rate.sh [--seconds N] [--megabytes N] [--debug-build]
set -euo pipefail

SECONDS_TO_SAMPLE=12
CORPUS_MEGABYTES=64
BUILD_ARGUMENTS=(--release)

while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_TO_SAMPLE="$2"; shift 2 ;;
        --megabytes) CORPUS_MEGABYTES="$2"; shift 2 ;;
        --debug-build) BUILD_ARGUMENTS=(); shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK_DIR="$(mktemp -d /tmp/danterm-t4.XXXXXX)"
RATE_LOG="$WORK_DIR/frame-rate.jsonl"
SLOT_HANDLE="$WORK_DIR/slot.json"
CORPUS="$WORK_DIR/corpus.txt"
SLOT_PID=""
PREVIOUS_FRONT_APP=""
# The CLI from this build, not the one on PATH: an installed `danterm` is
# provisioned from the last production release and may predate `--socket`.
DANTERM="$REPO_ROOT/.build/DanTerm Dev.app/Contents/Helpers/danterm"

cleanup() {
    if [ -n "$SLOT_PID" ] && kill -0 "$SLOT_PID" 2>/dev/null; then
        kill "$SLOT_PID" 2>/dev/null || true
        wait "$SLOT_PID" 2>/dev/null || true
    fi
    SLOT_PID=""
    if [ -n "$PREVIOUS_FRONT_APP" ]; then
        open -b "$PREVIOUS_FRONT_APP" 2>/dev/null || true
        PREVIOUS_FRONT_APP=""
    fi
}
trap cleanup EXIT

# Real source text rather than a synthetic block, so line lengths, wrapping and
# the ratio of newlines to printable bytes are ordinary terminal output.
BLOCK="$WORK_DIR/block.txt"
find "$REPO_ROOT/lib" -name '*.swift' -print0 | xargs -0 cat > "$BLOCK"
BLOCK_BYTES="$(wc -c < "$BLOCK" | tr -d ' ')"
COPIES=$(( CORPUS_MEGABYTES * 1024 * 1024 / BLOCK_BYTES + 1 ))
: > "$CORPUS"
for _ in $(seq "$COPIES"); do cat "$BLOCK" >> "$CORPUS"; done
echo "corpus: $(wc -c < "$CORPUS" | tr -d ' ') bytes" >&2

: > "$RATE_LOG"
DANTERM_FRAME_RATE_LOG="$RATE_LOG" "$REPO_ROOT/scripts/dev-slot-launcher.py" \
    ${BUILD_ARGUMENTS[@]+"${BUILD_ARGUMENTS[@]}"} \
    --pass-env DANTERM_FRAME_RATE_LOG > "$SLOT_HANDLE" &
SLOT_PID=$!

SOCKET=""
while [ -z "$SOCKET" ] && kill -0 "$SLOT_PID" 2>/dev/null; do
    SOCKET="$(jq -er '.socketPath' "$SLOT_HANDLE" 2>/dev/null || true)"
    [ -z "$SOCKET" ] && sleep 0.2
done
if [ -z "$SOCKET" ]; then
    echo "slot launcher exited before printing a handle" >&2
    exit 1
fi
echo "socket: $SOCKET" >&2

READY_ATTEMPTS=0
while ! "$DANTERM" --socket "$SOCKET" ls >/dev/null 2>&1; do
    READY_ATTEMPTS=$(( READY_ATTEMPTS + 1 ))
    if [ "$READY_ATTEMPTS" -gt 150 ]; then
        echo "app never answered on $SOCKET" >&2
        exit 1
    fi
    sleep 0.2
done
PANE_ID="$("$DANTERM" --socket "$SOCKET" ls \
    | jq -r 'first(.. | objects | select(.type == "leaf") | .pane.id)')"
echo "pane: $PANE_ID" >&2

BUNDLE_ID="$(jq -r '.bundleId' "$SLOT_HANDLE")"
PREVIOUS_FRONT_APP="$(osascript -e \
    'tell application "System Events" to bundle identifier of first application process whose frontmost is true' \
    2>/dev/null || true)"
open -b "$BUNDLE_ID"

# Settle first: the frames right after launch are shell startup, not streaming,
# and the window needs a moment to report itself unoccluded.
sleep 3
: > "$RATE_LOG"

"$DANTERM" --socket "$SOCKET" pane input --pane "$PANE_ID" -- "cat $CORPUS" Enter
sleep "$SECONDS_TO_SAMPLE"
"$DANTERM" --socket "$SOCKET" pane input --pane "$PANE_ID" -- C-c
sleep 1

cleanup

echo
echo "per-second samples:"
cat "$RATE_LOG"
echo
jq -s '
    if length == 0 then "no samples: the pane published nothing" else
        {
            windows: length,
            seconds: (map(.windowSeconds) | add),
            deliveries: (map(.deliveries) | add),
            publishes: (map(.publishes) | add),
            draws: (map(.draws) | add)
        }
        | . + {
            deliveriesPerSecond: (.deliveries / .seconds),
            publishesPerSecond: (.publishes / .seconds),
            drawsPerSecond: (.draws / .seconds),
            publishesPerDraw: (if .draws == 0 then null else .publishes / .draws end)
        }
    end
' "$RATE_LOG"
