#!/usr/bin/env bash
# Self-test for the gate that keeps the activity write off the AppKit draw path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../terminal-benchmark-draw-path-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# The timer-only shape the fix established, including a doc block that names the
# forbidden caller: prose about the rule must not be read as a call site.
cat > "$TMP/allowed.swift" <<'SWIFT'
    private func samplePresentationCoverage() {
        publishActivity(atPath: activityPath)
    }

    func observeCompletedDraw(_ plan: RenderFramePlan) {
        // Never publishActivity(atPath:) here -- see publishActivity.
        observedDrawCount += 1
    }

    private func publishActivity(atPath path: String) {
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
SWIFT
"$LINT" "$TMP/allowed.swift" >/dev/null || fail "timer-only publish should pass"

# The regression itself: the draw path publishing in addition to the timer.
cat > "$TMP/draw-path.swift" <<'SWIFT'
    private func samplePresentationCoverage() {
        publishActivity(atPath: activityPath)
    }

    func observeCompletedDraw(_ plan: RenderFramePlan) {
        observedDrawCount += 1
        publishActivity(atPath: activityPath)
    }

    private func publishActivity(atPath path: String) {}
SWIFT
if "$LINT" "$TMP/draw-path.swift" >/dev/null 2>&1; then
    fail "publishing from observeCompletedDraw should fail"
fi

# A single call site is not enough on its own -- it has to be the timer's.
cat > "$TMP/wrong-owner.swift" <<'SWIFT'
    func observeCompletedDraw(_ plan: RenderFramePlan) {
        publishActivity(atPath: activityPath)
    }

    private func publishActivity(atPath path: String) {}
SWIFT
if "$LINT" "$TMP/wrong-owner.swift" >/dev/null 2>&1; then
    fail "sole caller other than the sampler should fail"
fi

# Dropping the publish entirely would silently stop producing snapshots, which
# reads to every consumer as "the run published nothing".
cat > "$TMP/no-publish.swift" <<'SWIFT'
    func observeCompletedDraw(_ plan: RenderFramePlan) {
        observedDrawCount += 1
    }

    private func publishActivity(atPath path: String) {}
SWIFT
if "$LINT" "$TMP/no-publish.swift" >/dev/null 2>&1; then
    fail "no publish call site at all should fail"
fi

"$LINT" >/dev/null || fail "the checked-in observer should satisfy its own gate"

echo "terminal benchmark draw path lint self-test passed"
