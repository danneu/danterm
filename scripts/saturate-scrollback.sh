#!/bin/sh
# Fill a live DanTerm pane's scrollback to its 10 MiB budget, so that anything whose
# cost scales with history depth -- search, select-all, resize/reflow -- can be *felt*
# at a realistic depth instead of only measured in a headless probe.
#
# What it is for, concretely. Every number in doc 19
# (docs/research/19-owner-queue-occupancy.md) comes from a probe that calls Terminal
# methods directly, with no app, no renderer, and no main thread. That is the right
# way to size a job and the wrong way to decide whether a person notices it. This
# script produces the same conditions inside the real app so the judgement can be
# yours: it prints ~25k lines of plausible shell output at varied widths, with a
# sparse needle (NEEDLE_, about 1 line in 97) so a search has matches to step through
# without every row matching. Run it in the pane you want to test, then test that
# same pane.
#
# Deliberately not a benchmark. It prints and exits -- or streams until Ctrl-C -- and
# reports nothing. There is no pass/fail here and no number to record; if something
# feels fine, that is a real result and doc 19 should say so.
#
# Usage:
#   scripts/saturate-scrollback.sh [lines]              fill history, then stop
#   scripts/saturate-scrollback.sh --stream [rate]      fill, then keep printing
#                                                       `rate` lines/sec (default 500)
#
# `--stream` is the case still worth testing, and it is the reason the two modes are
# separate. With no output arriving, a slow search only delays its own result. In a
# pane that is *also* printing, the consume task's per-delivery drain fence runs on
# the main thread (`19/F8`, `19/F11`), so the stall reaches the whole app -- other
# panes, menus, window dragging -- rather than one pane. If both modes feel alike,
# `19/F8` has the severity wrong and should be corrected.
#
# Note the history below. The held-Enter chop this script was written to reproduce is
# fixed (`19/D3`, commit 257bfee): navigation no longer rescans history per press. A
# streaming pane still pays one scan per press, which is what `--stream` now probes.
set -eu

mode=fill
lines=25000
rate=500

case "${1:-}" in
    --stream) mode=stream; rate="${2:-500}" ;;
    "")       ;;
    -*)       echo "usage: $0 [lines] | --stream [lines-per-second]" >&2; exit 2 ;;
    *)        lines="$1" ;;
esac

# awk, not a shell loop: a shell printing 25k lines is slow enough that the pane
# stays ahead of it and history never reaches the budget while you wait.
#
# The needle is sparse (~1 line in 97) so a search has matches to step through
# without every row matching, and line widths vary so the scan is not measuring one
# pathological row shape. Both choices mirror the probe behind `19/F5`.
emit() {
    awk -v n="$2" -v base="$1" '
    BEGIN {
        for (i = 0; i < n; i++) {
            index_ = base + i
            width = 40 + (index_ % 7) * 20
            body = ""
            while (length(body) < width) body = body "abcdefghij"
            if (index_ % 97 == 0)
                printf "%6d  %s NEEDLE_%d\n", index_, body, index_
            else
                printf "%6d  %s\n", index_, body
        }
    }'
}

emit 0 "$lines"

if [ "$mode" = stream ]; then
    # Paced in bursts rather than line by line: a `sleep` per line would cap the rate
    # far below a real busy log, and the pane coalesces within a frame anyway.
    burst=$((rate / 20))
    [ "$burst" -lt 1 ] && burst=1
    cat <<EOF

--- streaming at ~$rate lines/sec; Ctrl-C to stop -------------------------------
Search this pane WHILE it scrolls, and compare against the same search with the
stream stopped.

Two things to judge separately. Whether stepping through matches is noticeably
worse here than on a quiet pane -- it should be, since arriving output drops the
cached match list and each press rescans all of history (19/D3). And whether the
hitch is app-wide or pane-local: doc 19 predicts the whole app, because the
per-delivery drain fence is on the main thread (19/F8, 19/F11).

If only this pane is affected either way, 19/F8 has the severity wrong.
--------------------------------------------------------------------------------
EOF
    next="$lines"
    while :; do
        emit "$next" "$burst"
        next=$((next + burst))
        sleep 0.05
    done
fi

cat <<'EOF'

--- scrollback saturated -------------------------------------------------------
History is now at the 10 MiB budget for this pane's width. Things to try, with
what doc 19 expects (docs/research/19-owner-queue-occupancy.md):

  Cmd-F, then type  NEEDLE_        every keystroke from the 3rd character on
                                   fires a full scan, ~50 ms each at this depth
                                   (19/F7 for the missing debounce, 19/D3 for
                                   the cost). Should feel responsive; it did
                                   before the scan was halved.

  Enter / Shift-Enter, HELD DOWN   this was the choppy case (19/F9) and is the
                                   one 19/D3 fixed: the match list is now cached
                                   per needle, so a press is index arithmetic
                                   rather than a rescan. Expect it to be smooth.
                                   If it is not, 19/D3 is wrong about the
                                   mechanism and that is worth knowing.

  re-run with --stream             the case that is NOT fixed. Arriving output
                                   invalidates the cached list, so every press
                                   pays a full ~49 ms scan again, and 19/F8 says
                                   the stall reaches the whole app rather than
                                   this pane. This comparison is what decides
                                   whether 19/C5 is worth building.

  Cmd-A                            ~10 ms; then Cmd-C fences behind it. Untouched
                                   by any change so far (19/C3 would address it).

  drag the window or a split       reflow is ~54 ms per width change (19/F5), and
                                   its *rate* during a drag was never measured
                                   (19/H2).

If none of that is noticeable to you, that is a real result and the remaining
candidates should be parked rather than acted on. Say so and they will be.
--------------------------------------------------------------------------------
EOF
