#!/usr/bin/env bash
# Research doc 33, task T22: compare one isolated app's process wakeups while
# fully idle and while one `pane tape --follow --from-now` subscription watches
# the same silent pane. The before/after baseline brackets the subscribed phase
# so unrelated launch settling cannot make a one-sided comparison look causal.
# After the idle arm, one feed and one resize prove a caught-up follower wakes
# from both recorder append kinds without relying on a periodic timer.
#
# `proc_pid_rusage(RUSAGE_INFO_V0)` supplies the cumulative interrupt and package
# idle wakeup counters used by macOS process energy diagnostics without requiring
# root. The pane is silent when the follow output contains only its start record.
#
# Usage: scripts/research/33/t22-pane-tape-follow-idle-wakeups.sh [--seconds N]
set -euo pipefail

SECONDS_PER_PHASE=15
while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_PER_PHASE="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK_DIR="$(mktemp -d /tmp/danterm-t22.XXXXXX)"
SLOT_HANDLE="$WORK_DIR/slot.json"
FOLLOW_OUTPUT="$WORK_DIR/follow.jsonl"
SAMPLER="$WORK_DIR/t22-rusage"
SLOT_PID=""
FOLLOW_PID=""
DANTERM="$REPO_ROOT/.build/DanTerm Dev.app/Contents/Helpers/danterm"

cleanup() {
    if [ -n "$FOLLOW_PID" ] && kill -0 "$FOLLOW_PID" 2>/dev/null; then
        kill "$FOLLOW_PID" 2>/dev/null || true
        wait "$FOLLOW_PID" 2>/dev/null || true
    fi
    FOLLOW_PID=""
    if [ -n "$SLOT_PID" ] && kill -0 "$SLOT_PID" 2>/dev/null; then
        kill "$SLOT_PID" 2>/dev/null || true
        wait "$SLOT_PID" 2>/dev/null || true
    fi
    SLOT_PID=""
    if [ -n "${SLOT_NUMBER:-}" ]; then
        sleep 0.5
        pkill -f "danterm-dev-slots/apps/DanTerm Dev \\($SLOT_NUMBER\\)" 2>/dev/null || true
    fi
}
trap cleanup EXIT

xcrun clang -O2 -Wall -Wextra \
    "$REPO_ROOT/scripts/research/33/t22-rusage.c" -o "$SAMPLER"

"$REPO_ROOT/scripts/dev-slot-launcher.py" --release > "$SLOT_HANDLE" &
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

READY_ATTEMPTS=0
while ! "$DANTERM" --socket "$SOCKET" ls >/dev/null 2>&1; do
    READY_ATTEMPTS=$(( READY_ATTEMPTS + 1 ))
    if [ "$READY_ATTEMPTS" -gt 150 ]; then
        echo "app never answered on $SOCKET" >&2
        exit 1
    fi
    sleep 0.2
done

APP_PID="$(jq -r '.pid' "$SLOT_HANDLE")"
SLOT_NUMBER="$(jq -r '.slot' "$SLOT_HANDLE")"
PANE_ID="$("$DANTERM" --socket "$SOCKET" ls \
    | jq -r 'first(.. | objects | select(.type == "leaf") | .pane.id)')"
echo "appPid=$APP_PID paneId=$PANE_ID secondsPerPhase=$SECONDS_PER_PHASE" >&2

# Exclude shell startup and the initial AppKit layout from every measured phase.
sleep 5

BASELINE_BEFORE="$($SAMPLER "$APP_PID" "$SECONDS_PER_PHASE")"

"$DANTERM" --socket "$SOCKET" pane tape --pane "$PANE_ID" --follow --from-now \
    > "$FOLLOW_OUTPUT" &
FOLLOW_PID=$!
for _ in $(seq 1 100); do
    [ -s "$FOLLOW_OUTPUT" ] && break
    kill -0 "$FOLLOW_PID" 2>/dev/null || break
    sleep 0.1
done
if [ ! -s "$FOLLOW_OUTPUT" ]; then
    echo "follow subscription did not produce its start record" >&2
    exit 1
fi

FOLLOW="$($SAMPLER "$APP_PID" "$SECONDS_PER_PHASE")"
FOLLOW_RECORDS="$(wc -l < "$FOLLOW_OUTPUT" | tr -d ' ')"
if [ "$FOLLOW_RECORDS" -ne 1 ]; then
    echo "pane was not silent: follow emitted $FOLLOW_RECORDS records" >&2
    exit 1
fi

# The idle arm proves absence of periodic work; these two edges prove the push
# replacement still wakes a caught-up follower for both recorder event kinds.
"$DANTERM" --socket "$SOCKET" pane input --pane "$PANE_ID" -- \
    "printf t22-follow-feed" Enter
for _ in $(seq 1 100); do
    jq -e 'select(.kind == "event" and .event.type == "feed")' \
        "$FOLLOW_OUTPUT" >/dev/null 2>&1 && break
    sleep 0.1
done
jq -e 'select(.kind == "event" and .event.type == "feed")' \
    "$FOLLOW_OUTPUT" >/dev/null || {
        echo "follow did not receive a feed append edge" >&2
        exit 1
    }

"$DANTERM" --socket "$SOCKET" pane split --pane "$PANE_ID" -h \
    --cmd "sleep $(( SECONDS_PER_PHASE + 5 ))" >/dev/null
for _ in $(seq 1 100); do
    jq -e 'select(.kind == "event" and .event.type == "resize")' \
        "$FOLLOW_OUTPUT" >/dev/null 2>&1 && break
    sleep 0.1
done
jq -e 'select(.kind == "event" and .event.type == "resize")' \
    "$FOLLOW_OUTPUT" >/dev/null || {
        echo "follow did not receive a resize append edge" >&2
        exit 1
    }

kill "$FOLLOW_PID" 2>/dev/null || true
wait "$FOLLOW_PID" 2>/dev/null || true
FOLLOW_PID=""
sleep 1
BASELINE_AFTER="$($SAMPLER "$APP_PID" "$SECONDS_PER_PHASE")"

jq -n \
    --argjson baselineBefore "$BASELINE_BEFORE" \
    --argjson follow "$FOLLOW" \
    --argjson baselineAfter "$BASELINE_AFTER" \
    --argjson followRecords "$FOLLOW_RECORDS" \
    '{
        baselineBefore: $baselineBefore,
        oneSilentFollow: $follow,
        baselineAfter: $baselineAfter,
        followRecords: $followRecords,
        feedEdgeObserved: true,
        resizeEdgeObserved: true,
        meanBaselineInterruptWakeupsPerSecond:
            (($baselineBefore.interruptWakeupsPerSecond
              + $baselineAfter.interruptWakeupsPerSecond) / 2),
        followMinusMeanBaselineInterruptWakeupsPerSecond:
            ($follow.interruptWakeupsPerSecond
             - (($baselineBefore.interruptWakeupsPerSecond
                 + $baselineAfter.interruptWakeupsPerSecond) / 2))
    }'
