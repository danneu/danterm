#!/usr/bin/env bash
# Enforces I1: a package that declares `.iOS` in `platforms:` has EVERY one of its
# manifest targets build for the iOS device triple, test targets included.
#
# A pin is a claim about a package, not about the targets someone remembered to
# check, so this script does not read a list of targets or a list of exempt ones.
# It finds the pinned packages by reading the manifests, then cross-compiles each
# one whole. `--build-tests` is the load-bearing flag: SwiftPM skips test targets
# by default, and skipping them is exactly how a package acquires a host-bound
# test while its pin still says iOS.
#
# A static import or manifest check cannot replace this. `Process()` added to a
# pinned target must fail on the commit that adds it, and only a real compile
# against the iOS SDK sees that.
#
# It also states the other half of the claim: `DanTermSupport` is the Mac host's
# side-effect layer and must NOT be pinned. That is asserted here rather than left
# to inspection, so pinning it becomes a gate failure and a decision, not a slip.
#
# Three modes, because the gate pool wants one step per package rather than one step
# that loops. `--list` reports the pinned set and builds nothing; `--package <path>`
# builds exactly one; no argument does the whole sweep, which is what a human running
# this by hand wants. The pool composes the first two: it asks `--list` what to run and
# makes a step per answer, so a newly pinned package gets a step without anyone adding
# one. Discovery stays in this file either way -- a list of packages kept anywhere else
# is a list that drifts away from the manifests, which is the failure this gate exists
# to prevent.
set -euo pipefail

# Test seam: the self-test points the gate at a fixture tree of tiny packages so it
# can prove the mechanism -- that an unportable target in a pinned package fails --
# without waiting on a full engine cross-compile. Nothing else sets this.
REPO_ROOT="${IOS_PORTABILITY_GATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO_ROOT"

# Kept in sync with what the pinned manifests declare; the SDK supplies the
# minimum, and the triple only has to be at or above it.
TRIPLE="arm64-apple-ios26.5"

# Packages the tree owns. `references/` and `docs/` hold external and throwaway
# trees, so a manifest there is not ours to police.
MANIFESTS=(Package.swift lib/*/Package.swift ios/*/Package.swift)

UNPINNED_BY_DESIGN=(lib/DanTermSupport/Package.swift)

fail() { echo "ios-portability-gate: $*" >&2; exit 1; }

mode=sweep
only=""
case "${1:-}" in
    --list) mode=list ;;
    --package) mode=one; only="${2:-}"; [[ -n "$only" ]] || fail "--package needs a package path." ;;
    "") ;;
    *) fail "unknown argument: $1. Use --list, --package <path>, or no argument." ;;
esac

# A single-package run answers only for that package, so it makes none of the
# whole-tree claims below -- the pool gets those from the `--list` call it already
# makes before it builds anything.
if [[ "$mode" == one ]]; then
    manifest="$only/Package.swift"
    [[ -f "$manifest" ]] || fail "$manifest does not exist."
    grep -q '\.iOS(' "$manifest" \
        || fail "$only declares no iOS platform, so there is nothing here to check.
    Only a package that pins iOS is built for it."
fi

for manifest in "${UNPINNED_BY_DESIGN[@]}"; do
    [[ -f "$manifest" ]] || fail "$manifest is missing; this check names a package that no longer exists."
    if grep -q '\.iOS(' "$manifest"; then
        fail "$manifest declares an iOS platform. DanTermSupport carries Mac-host roles only
    (the control socket's producer end, the Mac's own filesystem and session), so
    nothing outside the Mac host links it. If that has genuinely changed, change this
    check deliberately -- do not let the pin appear by accident."
    fi
done

pinned=()
for manifest in "${MANIFESTS[@]}"; do
    [[ -f "$manifest" ]] || continue
    if grep -q '\.iOS(' "$manifest"; then
        pinned+=("$(dirname "$manifest")")
    fi
done

if [[ "$mode" != one ]]; then
    (( ${#pinned[@]} > 0 )) || fail "no package declares an iOS platform, so this gate is
    checking nothing. Either a pin was dropped or this script is looking in the wrong place."
fi

if [[ "$mode" == list ]]; then
    printf '%s\n' "${pinned[@]}"
    exit 0
fi

[[ "$mode" == one ]] && pinned=("$only")

# Resolved after the list mode returns, so asking what is pinned never needs an iOS SDK.
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
[[ -n "$SDK" ]] || fail "no iphoneos SDK; install the iOS platform for this Xcode."

status=0
for package in "${pinned[@]}"; do
    echo "ios-portability-gate: building $package for $TRIPLE (tests included)"
    # A scratch path per package, inside that package, so this step shares no build
    # directory with any other gate step -- and so a host build's artifacts are never
    # mixed with an iOS one's.
    if ! swift build \
        --package-path "$package" \
        --scratch-path "$package/.build-ios-gate" \
        --build-tests \
        --triple "$TRIPLE" \
        --sdk "$SDK"; then
        echo "ios-portability-gate: $package does not build for $TRIPLE." >&2
        echo "  Its manifest claims iOS for every target it declares. Either make the" >&2
        echo "  failing code portable, or move the host-bound target to lib/TerminalHostTools" >&2
        echo "  (the sibling package that exists for exactly this). Do not add an exemption:" >&2
        echo "  an allowlist makes the pin mean 'iOS, except where a list says otherwise'." >&2
        status=1
    fi
done

exit "$status"
