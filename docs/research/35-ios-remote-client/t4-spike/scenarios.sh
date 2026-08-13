#!/bin/bash
# T4 scenario driver. Each scenario starts the thin client against a live slot, drives the source
# pane through the CLI, then captures both sides so they can be diffed. Throwaway harness: it
# assumes one slot, one pane, and a quiet machine.
set -u

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
CLI="$ROOT/.build/DanTerm Dev.app/Contents/Helpers/danterm"
CLIENT="$ROOT/docs/research/35-ios-remote-client/t4-spike/.build/debug/t4-thin-client"
OUT="$ROOT/.build/t4"
mkdir -p "$OUT"

SOCK="$1"; shift
PANE="$1"; shift
NAME="$1"; shift

client() { "$CLIENT" --socket "$SOCK" --pane "$PANE" "$@"; }
cli() { "$CLI" --socket "$SOCK" "$@"; }

case "$NAME" in
converge)
    # Backlog follow from pane birth, then a workload, then compare both viewports.
    client --idle-ms 3000 --max-seconds 90 "$@" > "$OUT/$NAME-client.json" 2> "$OUT/$NAME-client.err" &
    pid=$!
    sleep 1
    cli pane input --pane "$PANE" -- "printf 'plain \033[31mred\033[0m \033[1;44mbold\033[0m wide:你好\n'; seq 1 8" Enter
    sleep 2
    wait $pid
    cli pane read --pane "$PANE" > "$OUT/$NAME-source.txt"
    cli pane rows --pane "$PANE" > "$OUT/$NAME-source-rows.json"
    ;;
join)
    # Join mid-stream with --from-now: the client sees nothing that came before it attached.
    client --from-now --idle-ms 3000 --max-seconds 90 "$@" > "$OUT/$NAME-client.json" 2> "$OUT/$NAME-client.err" &
    pid=$!
    sleep 1
    cli pane input --pane "$PANE" -- "echo after-join" Enter
    sleep 2
    wait $pid
    cli pane read --pane "$PANE" > "$OUT/$NAME-source.txt"
    cli pane rows --pane "$PANE" > "$OUT/$NAME-source-rows.json"
    ;;
joinbytes)
    # The same mid-stream join, captured as readable spans, so the finding can name the exact
    # sequences a joiner receives without the screen they were written against.
    cli pane tape --pane "$PANE" --follow --from-now --format inspect > "$OUT/$NAME.jsonl" 2>&1 &
    pid=$!
    sleep 1
    cli pane input --pane "$PANE" -- "echo bytes-probe" Enter
    sleep 2
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    ;;
resize)
    # Follow across a real geometry change driven by the Mac window (pane zoom).
    client --idle-ms 3000 --max-seconds 90 "$@" > "$OUT/$NAME-client.json" 2> "$OUT/$NAME-client.err" &
    pid=$!
    sleep 1
    cli pane zoom --pane "$PANE" on > /dev/null
    sleep 1
    cli pane input --pane "$PANE" -- "echo zoomed" Enter
    sleep 1
    cli pane zoom --pane "$PANE" off > /dev/null
    sleep 1
    cli pane input --pane "$PANE" -- "echo unzoomed" Enter
    sleep 2
    wait $pid
    cli pane read --pane "$PANE" > "$OUT/$NAME-source.txt"
    ;;
state)
    # Two clients on the same pane at the same moment: one replaying the whole retained tape,
    # one joining from now. The converged client is the oracle, so every difference between the
    # two reports is exactly what a mid-stream join lost. The pane runs a program that switches
    # to the alternate screen and sets modes BEFORE either client attaches, then keeps ticking so
    # neither client goes idle before its deadline.
    cli pane input --pane "$PANE" -- "bash $(dirname "$0")/state-program.sh" Enter
    sleep 2
    client --idle-ms 2500 --max-seconds 4 > "$OUT/$NAME-backlog.json" 2> "$OUT/$NAME-backlog.err" &
    a=$!
    client --from-now --idle-ms 2500 --max-seconds 4 > "$OUT/$NAME-join.json" 2> "$OUT/$NAME-join.err" &
    b=$!
    wait $a
    wait $b
    ;;
aftermath)
    # The joiner keeps running past the alternate-screen exit, so the report shows what the
    # pane looks like on a client whose primary screen absorbed a full-screen program's output.
    cli pane input --pane "$PANE" -- "bash $(dirname "$0")/state-program.sh" Enter
    sleep 2
    client --from-now --idle-ms 3000 --max-seconds 30 > "$OUT/$NAME-join.json" 2> "$OUT/$NAME-join.err" &
    b=$!
    wait $b
    cli pane read --pane "$PANE" > "$OUT/$NAME-source.txt"
    ;;
geometry)
    # A client whose grid is a phone-shaped 40x20 rather than the source pane's size. The
    # from-now half never receives a resize event, so it stays 40x20 and has to render bytes the
    # child wrote for a much wider screen.
    client --from-now --columns 40 --rows 20 --idle-ms 3000 --max-seconds 60 \
        > "$OUT/$NAME-narrow.json" 2> "$OUT/$NAME-narrow.err" &
    a=$!
    client --columns 40 --rows 20 --idle-ms 3000 --max-seconds 60 \
        > "$OUT/$NAME-backlog.json" 2> "$OUT/$NAME-backlog.err" &
    b=$!
    sleep 1
    cli pane input --pane "$PANE" -- "printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz\n'; printf '\033[5;100HFAR-RIGHT\033[10;1H\n'" Enter
    sleep 2
    wait $a
    wait $b
    cli pane read --pane "$PANE" > "$OUT/$NAME-source.txt"
    ;;
reflow)
    # Converge at the source pane's geometry, then reflow locally to a phone width without
    # telling the source. This is the "observe" half of the geometry question.
    client --idle-ms 3000 --max-seconds 60 --reflow-to-columns 40 \
        > "$OUT/$NAME-client.json" 2> "$OUT/$NAME-client.err" &
    a=$!
    sleep 1
    cli pane input --pane "$PANE" -- "printf 'a-long-line-that-will-need-to-fold-when-the-client-narrows-it-down-to-forty-columns-exactly\n'" Enter
    sleep 2
    wait $a
    cli pane read --pane "$PANE" > "$OUT/$NAME-source.txt"
    ;;
evict)
    # Push more bytes through the pane than the flight recorder retains, then attach a backlog
    # client: this is the case where replaying the retained tape is not a substitute for a
    # snapshot, and the producer says so with a gap record.
    cli pane input --pane "$PANE" -- "seq 1 1200000" Enter
    sleep 60
    client --idle-ms 4000 --max-seconds 180 > "$OUT/$NAME-client.json" 2> "$OUT/$NAME-client.err"
    cli pane read --pane "$PANE" > "$OUT/$NAME-source.txt"
    ;;
reconnect)
    # A client that drops its connection mid-stream and comes back with the only two options the
    # protocol offers today. The pane keeps producing throughout, so the sequence numbers on each
    # side of the drop measure exactly what a from-now reconnect skips without saying so.
    cli pane input --pane "$PANE" -- "seq 1 4000000" Enter
    sleep 3
    client --from-now --drop-after-events 200 --idle-ms 3000 --max-seconds 60 \
        > "$OUT/$NAME-before.json" 2> "$OUT/$NAME-before.err"
    client --from-now --idle-ms 3000 --max-seconds 60 \
        > "$OUT/$NAME-after.json" 2> "$OUT/$NAME-after.err"
    ;;
close)
    # Watch how a followed stream ends when the pane it follows goes away.
    client --from-now --idle-ms 20000 --max-seconds 40 > "$OUT/$NAME-client.json" 2> "$OUT/$NAME-client.err" &
    a=$!
    sleep 2
    cli pane close --pane "$PANE" > /dev/null
    wait $a
    ;;
alt)
    # A full-screen program: the client must reproduce the alternate screen from bytes alone.
    client --idle-ms 3000 --max-seconds 90 "$@" > "$OUT/$NAME-client.json" 2> "$OUT/$NAME-client.err" &
    pid=$!
    sleep 1
    cli pane input --pane "$PANE" -- "printf '\033[?1049h\033[H\033[2Jalternate screen line 1\r\nline 2\r\n'" Enter
    sleep 2
    wait $pid
    cli pane read --pane "$PANE" > "$OUT/$NAME-source.txt"
    ;;
*)
    echo "unknown scenario $NAME" >&2
    exit 2
    ;;
esac
