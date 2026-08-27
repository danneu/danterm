#!/usr/bin/env bash
# Keeps lifecycle control and fault injection out of the production PTY host, and keeps the
# host's own suite on the real byte plane.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lint-rationale.sh
source "$SCRIPT_DIR/lib/lint-rationale.sh"
# shellcheck source=lib/lint-targets.sh
source "$SCRIPT_DIR/lib/lint-targets.sh"

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

# The same explanation for every way this gate can fail. All three failures are one
# rule: test-only surface belongs outside the production host, and the host's own suite
# has to cross a real PTY.
rationale() {
    lint_rationale <<'EOF'
terminal-pty-host-test-seam lint FAILED.

Three plans in a row moved test-only surface off TerminalPTYHost --
spawn delays, injected write failures, held cancellations -- because
each seam made the production host describe a state only a test could
reach. This gate keeps them off. It checks three things:

  * The named seams are gone from the host. If you need one back, the
    test needs a different injection point, not the host.
  * The host's own suite does not stage fixture output. That suite
    exists to prove the read path across a real PTY, and applying
    output directly bypasses exactly what it is testing. A consumer
    suite asserting against a known screen may stage output; this one
    may not.
  * lib/TerminalPTY/Sources holds exactly one `#if DEBUG` region, and
    it encloses stageFixtureOutput. Dropping the guard ships the
    fixture stager. Adding a second region is test-only surface
    accreting onto the host again -- and nothing in the gate builds
    this package in release configuration, so this lint is the only
    thing that sees it.

See docs/design/2026-08-17-test-seam-rule.md.
EOF
}

fail() {
    echo "terminal-pty-host-test-seam-lint: $1" >&2
    rationale
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
        rationale
        exit 1
    else
        status=$?
        [[ "$status" == "1" ]] \
            || lint_checked_nothing "terminal-pty-host-test-seam-lint" "could not scan: $file"
    fi
}

scan "$HOST" "$REMOVED_SEAMS" "removed test-control seams"
scan "$HOST_SUITE" "$FIXTURE_OUTPUT" "host suite applies output directly instead of crossing a real PTY"

# Pins the whole debug surface of the package rather than a list of names, because the failure
# this guards runs both ways: dropping the guard ships the fixture stager, and adding a second
# region is test-only surface accreting onto the host again -- which is how the names banned
# above got here. Nothing in the gate builds this package in release configuration, so a
# deleted guard has no other check.
lint_resolve_targets "terminal-pty-host-test-seam-lint" '*.swift' "$SOURCES"
# shellcheck disable=SC2016 # $0 in the awk program is awk's field, not a shell expansion.
counts="$(
    awk '
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
    ' decl="$GUARDED_DECL" "${LINT_TARGET_FILES[@]}"
)"
read -r regions enclosed <<< "$counts"
[[ "$regions" == "1" ]] \
    || fail "expected exactly one #if DEBUG region under $SOURCES, found $regions"
[[ "$enclosed" -gt 0 ]] \
    || fail "the #if DEBUG region does not enclose $GUARDED_DECL"

echo "TerminalPTY host test-seam lint passed"
