#!/usr/bin/env bash
# Keeps lifecycle control and fault injection out of the production PTY host, and keeps the
# host's own suite on the real byte plane.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${1:-$SCRIPT_DIR/..}"
HOST="$ROOT_DIR/lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift"
HOST_SUITE="$ROOT_DIR/lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift"
SOURCES="$ROOT_DIR/lib/TerminalPTY/Sources"
REMOVED_SEAMS='spawnReportDelay|spawnDeliveryDelay|lastIssuedLaunch|injectSpawnReportDelay|injectSpawnDeliveryDelay|lastLaunchedLeaderPID|lastLaunchHasPendingDelivery|transientChildWaitInjections|injectTransientChildWaits|holdsSourceCancellationAcknowledgements|heldSourceCancellationIDs|sourceCancellationHeldObserver|holdSourceCancellationAcknowledgements|releaseSourceCancellationAcknowledgements|holdsInstalledSourcesBeforeActivation|installedSourcesObserver|hasDeferredSpawnSuccess|holdInstalledSourcesBeforeActivation|releaseInstalledSourcesForActivation|descriptorReuseReplacementFD|reusedDescriptor|installDescriptorReuseProbe|injectInputWriteFailure|injectedInputWriteErrno'
# Fixture staging is legal setup in a consumer suite, which asserts its own behavior against a
# known screen. In the host's own suite it would bypass the read path the suite is there to
# prove, so the name is banned in that file only.
FIXTURE_OUTPUT='stageFixtureOutput|deliverOutputForTesting'
# The one declaration `#if DEBUG` is allowed to guard in this package.
GUARDED_DECL='stageFixtureOutput'

fail() {
    echo "terminal-pty-host-test-seam-lint: $1" >&2
    exit 1
}

# Fails the gate when `pattern` appears in `file`, and also when `file` is gone -- a lint that
# silently passes on a renamed path proves nothing.
scan() {
    local file="$1" pattern="$2" label="$3"
    local matches status
    if matches="$(rg -n "$pattern" "$file")"; then
        echo "terminal-pty-host-test-seam-lint: $label:" >&2
        echo "$matches" >&2
        exit 1
    else
        status=$?
        [[ "$status" == "1" ]] || fail "could not scan: $file"
    fi
}

scan "$HOST" "$REMOVED_SEAMS" "removed test-control seams"
scan "$HOST_SUITE" "$FIXTURE_OUTPUT" "host suite applies output directly instead of crossing a real PTY"

# Pins the whole debug surface of the package rather than a list of names, because the failure
# this guards runs both ways: dropping the guard ships the fixture stager, and adding a second
# region is test-only surface accreting onto the host again -- which is how the names banned
# above got here. Nothing in the gate builds this package in release configuration, so a
# deleted guard has no other check.
[[ -d "$SOURCES" ]] || fail "could not scan: $SOURCES"
# shellcheck disable=SC2016 # $0 in the awk program is awk's field, not a shell expansion.
counts="$(
    find "$SOURCES" -name '*.swift' -print0 \
        | xargs -0 awk '
            FNR == 1 { depth = 0; debugDepth = 0 }
            /^[[:space:]]*#if([[:space:]]|$)/ {
                depth++
                if (debugDepth == 0 && $0 ~ /#if[[:space:]]+DEBUG([[:space:]]|$)/) {
                    debugDepth = depth
                    regions++
                }
                next
            }
            /^[[:space:]]*#(else|elseif)([[:space:]]|$)/ {
                if (debugDepth == depth) debugDepth = 0
                next
            }
            /^[[:space:]]*#endif([[:space:]]|$)/ {
                if (debugDepth == depth) debugDepth = 0
                depth--
                next
            }
            debugDepth > 0 && $0 ~ decl { enclosed++ }
            END { print regions + 0, enclosed + 0 }
        ' decl="$GUARDED_DECL"
)"
read -r regions enclosed <<< "$counts"
[[ "$regions" == "1" ]] \
    || fail "expected exactly one #if DEBUG region under $SOURCES, found $regions"
[[ "$enclosed" -gt 0 ]] \
    || fail "the #if DEBUG region does not enclose $GUARDED_DECL"

echo "TerminalPTY host test-seam lint passed"
