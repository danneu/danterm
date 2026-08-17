#!/usr/bin/env bash
# Keeps lifecycle control and fault injection out of the production PTY host, and keeps the
# host's own suite on the real byte plane.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${1:-$SCRIPT_DIR/..}"
HOST="$ROOT_DIR/lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift"
HOST_SUITE="$ROOT_DIR/lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift"
REMOVED_SEAMS='spawnReportDelay|spawnDeliveryDelay|lastIssuedLaunch|injectSpawnReportDelay|injectSpawnDeliveryDelay|lastLaunchedLeaderPID|lastLaunchHasPendingDelivery|transientChildWaitInjections|injectTransientChildWaits|holdsSourceCancellationAcknowledgements|heldSourceCancellationIDs|sourceCancellationHeldObserver|holdSourceCancellationAcknowledgements|releaseSourceCancellationAcknowledgements|holdsInstalledSourcesBeforeActivation|installedSourcesObserver|hasDeferredSpawnSuccess|holdInstalledSourcesBeforeActivation|releaseInstalledSourcesForActivation|descriptorReuseReplacementFD|reusedDescriptor|installDescriptorReuseProbe|injectInputWriteFailure|injectedInputWriteErrno'
# Fixture staging is legal setup in a consumer suite, which asserts its own behavior against a
# known screen. In the host's own suite it would bypass the read path the suite is there to
# prove, so the name is banned in that file only.
FIXTURE_OUTPUT='stageFixtureOutput|deliverOutputForTesting'

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

echo "TerminalPTY host test-seam lint passed"
