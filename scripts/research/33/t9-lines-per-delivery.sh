#!/usr/bin/env bash
# Research doc 33, task T9 (vetting): measure live lines-per-delivery, the one
# number 33/F13 said places production on its scroll-amplification curve --
# 66x planned rows per changed row at 1 line per delivery, decaying to 1x at a
# whole screen (91 lines at 179 columns) per delivery.
#
# Four producer regimes in one pane: a full-speed `cat` of a source corpus (the
# fastest producer a pane sees, F12's stimulus) and three paced line producers
# at 30, 240 and 960 lines/s (build logs, test output, a fast logger). The app
# samples itself through DANTERM_DELIVERY_SHAPE_LOG: one JSON line per second
# with publishes, full-damage publishes, scrolled viewport lines, and a
# lines-per-publish histogram whose buckets bracket F13's curve points.
#
# The log file is never truncated -- the app holds its write handle, so the
# script slices one growing file by byte offsets per scenario instead.
#
# A hidden pane plans and publishes nothing (33/F12), so the slot's window has
# to be on screen for the duration; the script activates it and hands the front
# back afterwards. Release configuration for the same reason F12 names: a debug
# build's per-frame cost collapses the delivery rate itself.
#
# Usage: scripts/research/33/t9-lines-per-delivery.sh [--seconds N] [--megabytes N] [--debug-build]
set -euo pipefail

SECONDS_TO_SAMPLE=12
CORPUS_MEGABYTES=256
BUILD_ARGUMENTS=(--release)
PACED_RATES=(30 240 960)

while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_TO_SAMPLE="$2"; shift 2 ;;
        --megabytes) CORPUS_MEGABYTES="$2"; shift 2 ;;
        --debug-build) BUILD_ARGUMENTS=(); shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK_DIR="$(mktemp -d /tmp/danterm-t9.XXXXXX)"
SHAPE_LOG="$WORK_DIR/delivery-shape.jsonl"
TRACE_LOG="$WORK_DIR/delivery-shape-trace.jsonl"
SLOT_HANDLE="$WORK_DIR/slot.json"
CORPUS="$WORK_DIR/corpus.txt"
PRODUCER="$WORK_DIR/paced-producer.py"
SLOT_PID=""
PREVIOUS_FRONT_APP=""
# The CLI from this build, not the one on PATH: an installed `danterm` is
# provisioned from the last production release and may predate `--socket`.
DANTERM="$REPO_ROOT/.build/DanTerm Dev.app/Contents/Helpers/danterm"

cleanup() {
    # Hand the front back before killing: killing the frontmost app makes
    # launchd relaunch it as an orphan without `--fresh` or a slot lock, which
    # then squats the slot socket and shows the recovery prompt.
    if [ -n "$PREVIOUS_FRONT_APP" ]; then
        open -b "$PREVIOUS_FRONT_APP" 2>/dev/null || true
        PREVIOUS_FRONT_APP=""
    fi
    if [ -n "$SLOT_PID" ] && kill -0 "$SLOT_PID" 2>/dev/null; then
        kill "$SLOT_PID" 2>/dev/null || true
        wait "$SLOT_PID" 2>/dev/null || true
    fi
    SLOT_PID=""
    # Sweep a relaunched orphan anyway, scoped to the slot this run claimed.
    if [ -n "${SLOT_NUMBER:-}" ]; then
        sleep 0.5
        pkill -f "danterm-dev-slots/apps/DanTerm Dev \\($SLOT_NUMBER\\)" 2>/dev/null || true
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
echo "corpus: $(wc -c < "$CORPUS" | tr -d ' ') bytes," \
    "$(wc -l < "$CORPUS" | tr -d ' ') lines" >&2

# Paced producer: one flushed line per write at a fixed rate, drift-corrected,
# so each line is its own PTY write and the read side sets the delivery shape.
cat > "$PRODUCER" <<'PYTHON'
import sys, time

rate = float(sys.argv[1])
seconds = float(sys.argv[2])
line = "paced line 0123456789 abcdefghijklmnopqrstuvwxyz 0123456789\n"
start = time.perf_counter()
total = int(rate * seconds)
for n in range(total):
    target = start + n / rate
    now = time.perf_counter()
    if now < target:
        time.sleep(target - now)
    sys.stdout.write(line)
    sys.stdout.flush()
PYTHON

: > "$SHAPE_LOG"
: > "$TRACE_LOG"
DANTERM_DELIVERY_SHAPE_LOG="$SHAPE_LOG" \
DANTERM_DELIVERY_SHAPE_TRACE="$TRACE_LOG" \
    "$REPO_ROOT/scripts/dev-slot-launcher.py" \
    ${BUILD_ARGUMENTS[@]+"${BUILD_ARGUMENTS[@]}"} \
    --pass-env DANTERM_DELIVERY_SHAPE_LOG \
    --pass-env DANTERM_DELIVERY_SHAPE_TRACE > "$SLOT_HANDLE" &
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

# Activate by process id, not bundle id: the launcher stamps each slot app into
# a fresh directory, and LaunchServices may resolve the dev bundle id to a stale
# copy (-609) when asked to `open -b` it.
APP_PID="$(jq -r '.pid' "$SLOT_HANDLE")"
SLOT_NUMBER="$(jq -r '.slot' "$SLOT_HANDLE")"
PREVIOUS_FRONT_APP="$(osascript -e \
    'tell application "System Events" to bundle identifier of first application process whose frontmost is true' \
    2>/dev/null || true)"
osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $APP_PID) to true"

# Settle first: the frames right after launch are shell startup, not streaming.
sleep 3

# Runs one scenario: marks the log offsets, starts the producer command in the
# pane, samples, interrupts it, waits for the interrupt's flushed tail window,
# and slices this scenario's samples out. The end offset is taken after the
# settle so the tail window stays in this scenario instead of leaking into the
# next one's segment.
run_scenario() {
    local name="$1" command="$2" segment="$WORK_DIR/$1.jsonl"
    local start_offset end_offset trace_start trace_end
    start_offset="$(wc -c < "$SHAPE_LOG" | tr -d ' ')"
    trace_start="$(wc -c < "$TRACE_LOG" | tr -d ' ')"
    "$DANTERM" --socket "$SOCKET" pane input --pane "$PANE_ID" -- "$command" Enter
    sleep "$SECONDS_TO_SAMPLE"
    "$DANTERM" --socket "$SOCKET" pane input --pane "$PANE_ID" -- C-c
    # Long enough for the interrupted producer's buffered PTY output to finish
    # draining -- a full-speed `cat` leaves a few hundred KB in flight, which
    # otherwise lands in the next scenario's segment.
    sleep 4
    end_offset="$(wc -c < "$SHAPE_LOG" | tr -d ' ')"
    trace_end="$(wc -c < "$TRACE_LOG" | tr -d ' ')"
    tail -c "+$(( start_offset + 1 ))" "$SHAPE_LOG" \
        | head -c "$(( end_offset - start_offset ))" > "$segment"
    tail -c "+$(( trace_start + 1 ))" "$TRACE_LOG" \
        | head -c "$(( trace_end - trace_start ))" > "$WORK_DIR/$1-trace.jsonl"

    echo
    echo "== $name: per-second samples"
    cat "$segment"
    # The first window is dropped from the summary: the sampler flushes windows
    # on publish, so a segment's first window carries the previous scenario's
    # unflushed tail (accumulated during the settle) plus producer startup.
    jq -s '
        .[1:]
        | if length == 0 then "no samples: the pane published nothing" else
            {
                windows: length,
                seconds: (map(.windowSeconds) | add),
                deliveries: (map(.deliveries) | add),
                publishes: (map(.publishes) | add),
                fullDamagePublishes: (map(.fullDamagePublishes) | add),
                scrolledLines: (map(.scrolledLines) | add),
                gridRows: (map(.gridRows) | max),
                histogram: {
                    h0: (map(.h0) | add), h1: (map(.h1) | add),
                    h2: (map(.h2) | add), h3to8: (map(.h3to8) | add),
                    h9to32: (map(.h9to32) | add), h33to65: (map(.h33to65) | add),
                    h66to90: (map(.h66to90) | add), h91plus: (map(.h91plus) | add)
                }
            }
            | . + {
                publishesPerSecond: (.publishes / .seconds),
                deliveriesPerSecond: (.deliveries / .seconds),
                scrolledLinesPerSecond: (.scrolledLines / .seconds),
                meanLinesPerPublish:
                    (if .publishes == 0 then null
                     else .scrolledLines / .publishes end),
                meanLinesPerScrollingPublish:
                    (if .publishes - .histogram.h0 == 0 then null
                     else .scrolledLines / (.publishes - .histogram.h0) end),
                fullDamageShare:
                    (if .publishes == 0 then null
                     else .fullDamagePublishes / .publishes end)
            }
        end
    ' "$segment"
    # Damaged rows are measured from the per-publish trace, not derived: before
    # research/33 T9 every scrolling publish touched the whole grid (escalated
    # `.full` below the history budget, a whole-viewport row set at it), and
    # after T9 the seam carries a shift plus O(1) rows -- the vacated strip and
    # the cursor pair -- so this number is the live half of that claim.
    jq -s '
        if length == 0 then "no trace: the pane published nothing" else
            {
                tracePublishes: length,
                traceFullPublishes: (map(select(.full)) | length),
                traceDamagedRows: (map(.rows) | add),
                traceScrolledLines: (map(.lines) | add)
            }
            | . + {
                damagedRowsPerPublish:
                    (if .tracePublishes == 0 then null
                     else .traceDamagedRows / .tracePublishes end),
                damagedRowsPerScrolledLine:
                    (if .traceScrolledLines == 0 then null
                     else .traceDamagedRows / .traceScrolledLines end)
            }
        end
    ' "$WORK_DIR/$1-trace.jsonl"
}

run_scenario "cat-full-speed" "cat $CORPUS"
for rate in "${PACED_RATES[@]}"; do
    run_scenario "paced-${rate}-per-second" \
        "python3 $PRODUCER $rate $(( SECONDS_TO_SAMPLE + 5 ))"
done

cleanup
echo
echo "scenario segments retained in $WORK_DIR" >&2
