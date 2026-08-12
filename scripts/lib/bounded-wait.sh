# shellcheck shell=bash
# Shell waits that cannot park forever. Source this; it defines no state.
#
# Every helper here exists because bash's own `wait` has no timeout. A `wait` on a
# child that never exits parks the script for good, and these run from EXIT traps as
# well as from test bodies -- so the hang outlives the Ctrl-C meant to end it, and a
# test whose whole subject is "the child exits" reports nothing at all.

# Reaps a pid that was already signalled, escalating to SIGKILL after ten seconds.
#
# The escalation is what bounds it: SIGKILL cannot be blocked or handled, so the
# `wait` that follows always returns.
reap_pid() {
    local pid="$1" waited=0
    while (( waited < 100 )) && kill -0 "$pid" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# Kills the given pids after `seconds`, and prints the watchdog's own pid.
#
# For waits on children that are supposed to exit on their own. Cancel it with
# `cancel_watchdog` on the normal path; when it fires instead, the children die by
# signal and the caller's usual exit-status check turns the hang into a failure.
start_watchdog() {
    local seconds="$1"
    shift
    local pids=("$@")
    # The redirect is required, not tidiness. Callers read the pid through a command
    # substitution, which returns only once every process holding that pipe's write
    # end has closed it -- and this subshell inherits it, so without the redirect the
    # caller blocks for the full timeout, hanging on the watchdog meant to prevent
    # exactly that.
    (
        sleep "$seconds"
        kill -KILL "${pids[@]}" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    printf '%s\n' "$!"
}

cancel_watchdog() {
    local pid="$1"
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}
