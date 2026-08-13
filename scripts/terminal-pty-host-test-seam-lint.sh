#!/usr/bin/env bash
# Keeps lifecycle control and fault injection out of the production PTY host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${1:-$SCRIPT_DIR/..}"
HOST="$ROOT_DIR/lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift"
REMOVED_SEAMS='spawnReportDelay|spawnDeliveryDelay|lastIssuedLaunch|injectSpawnReportDelay|injectSpawnDeliveryDelay|lastLaunchedLeaderPID|lastLaunchHasPendingDelivery|transientChildWaitInjections|injectTransientChildWaits|holdsSourceCancellationAcknowledgements|heldSourceCancellationIDs|sourceCancellationHeldObserver|holdSourceCancellationAcknowledgements|releaseSourceCancellationAcknowledgements|holdsInstalledSourcesBeforeActivation|installedSourcesObserver|hasDeferredSpawnSuccess|holdInstalledSourcesBeforeActivation|releaseInstalledSourcesForActivation|descriptorReuseReplacementFD|reusedDescriptor|installDescriptorReuseProbe'

fail() {
    echo "terminal-pty-host-test-seam-lint: $1" >&2
    exit 1
}

if matches="$(rg -n "$REMOVED_SEAMS" "$HOST")"; then
    echo "terminal-pty-host-test-seam-lint: removed test-control seams:" >&2
    echo "$matches" >&2
    exit 1
else
    status=$?
    [[ "$status" == "1" ]] || fail "could not scan host source: $HOST"
fi

echo "TerminalPTY host test-seam lint passed"
